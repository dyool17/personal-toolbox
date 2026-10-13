# skills
skills custom que he creado para solucionar problemas específicos con los que me he topado en el viaje de del desarrollo agentico de alta calidad y eficiencia

## Linux tool maintenance (`scripts/linux`)

Three scripts keep the local agent tooling current and recoverable:

| Script | What it does |
|---|---|
| `gentle-update` | Updates agents, the Gentleman toolchain, Claude plugins, and global packages. Snapshots first, skips held components, and rolls back a tool that stops running. |
| `gentle-rollback` | Takes snapshots, restores components from one, and manages holds. |
| `gentle-reset` | Clears stale state, caches, leftover temp files, and long-lived daemons, then runs `gentle-update`. |

Each script documents its groups and flags in its header (`gentle-update --help`).

### Install

```bash
ln -s "$PWD/scripts/linux/gentle-update"   ~/.local/bin/gentle-update
ln -s "$PWD/scripts/linux/gentle-rollback" ~/.local/bin/gentle-rollback
ln -s "$PWD/scripts/linux/gentle-reset"    ~/.local/bin/gentle-reset

# Daily run at 04:00 (catches up after boot if the machine was off)
systemctl --user link "$PWD/scripts/linux/systemd/gentle-update.service"
systemctl --user enable --now "$PWD/scripts/linux/systemd/gentle-update.timer"

systemctl --user list-timers gentle-update.timer   # next run
journalctl --user -u gentle-update -e               # last run
```

### Run logs

`gentle-update` and `gentle-reset` write one log per run, and print its path
when the run fails:

```bash
less ~/.local/state/gentle-update/logs/latest.log
less ~/.local/state/gentle-reset/logs/latest.log
grep -h "finished: exit [1-9]" ~/.local/state/gentle-update/logs/*.log   # every failed step and run
```

A log holds everything the terminal showed, plus the environment the run
started in, where each tool was resolved from, and the command, exit status and
duration of every step. The newest 30 logs are kept per script.

| Variable | Effect |
|---|---|
| `GENTLE_UPDATE_NO_LOG=1`, `GENTLE_RESET_NO_LOG=1` | Do not write a log. |
| `GENTLE_UPDATE_TRACE=1`, `GENTLE_RESET_TRACE=1` | Also write a `set -x` trace (`<log>.trace`). It records every expanded value, so read it before sharing it. |
| `GENTLE_UPDATE_LOG_DIR`, `GENTLE_RESET_LOG_DIR` | Write the logs somewhere else. |

While a log is being written the tools no longer see a terminal on their
output, so some of them print plainer progress than before.

### npm install-script permissions

`gentle-update` allows lifecycle scripts for `gentle-pi`, `@google/genai`, and
`protobufjs` during its direct npm installations/updates and package installation
steps delegated to Pi and Gentle Shell. These scripts run as your user; approval
by package name also trusts future versions. Other packages remain subject to
npm's existing script policy. No user npm configuration is changed, and unrelated
steps do not receive this permission.

This applies when an installation/update runs; a launcher already recorded at the
current main commit is still skipped. It does not retroactively run scripts that
were blocked during an earlier installation.

### Roll back

```bash
gentle-rollback list                          # snapshots, newest first
gentle-rollback show latest                   # what changed since that snapshot
gentle-rollback restore <id> --dry-run        # plan and commands, changes nothing
gentle-rollback restore <id> --only claude    # restore one component
gentle-rollback snapshot --reason "before experiment"
```

A restore first snapshots the current state, so it can itself be undone. After
any restore `latest` is that safety snapshot; name the snapshot you want by id.
State lives in `~/.local/state/gentle-update` (7 snapshots are kept).

### Holds

A hold tells `gentle-update` to skip a component. Every restored component is
held automatically, so the next daily run does not reinstall the release you
just rolled back.

```bash
gentle-rollback holds                    # what is held and why
gentle-rollback hold codex "0.161 breaks MCP"
gentle-rollback unhold codex             # update it again on the next run
gentle-rollback unhold all
```

### Limits

- Rollback never uninstalls: packages and files added after a snapshot stay.
- Language runtimes managed by mise are not snapshotted or restored.
- The Claude plugin cache is not copied; the plugin list is restored only while
  every install path it names still exists.
- Credentials (`auth.json`, tokens) are never copied into a snapshot.

## Daily backlog from Azure Boards (`scripts/linux/boards-backlog`)

Lists the open work items assigned to me, ordered by severity, then priority,
then oldest first, and saves what changed to Engram.

```bash
ln -s "$PWD/scripts/linux/boards-backlog" ~/.local/bin/boards-backlog

boards-backlog --dry-run     # print the backlog and what would be saved
boards-backlog               # print it, store the raw items, feed Engram
boards-backlog --json        # ordered items with every field, as JSON
boards-backlog --no-engram   # print and store only
```

```bash
# Daily run at 06:00 Guatemala time (catches up after boot if the machine was off)
systemctl --user link "$PWD/scripts/linux/systemd/boards-backlog.service"
systemctl --user enable --now "$PWD/scripts/linux/systemd/boards-backlog.timer"

systemctl --user list-timers boards-backlog.timer   # next run
journalctl --user -u boards-backlog -e               # last run
```

It needs `AZURE_DEVOPS_EXT_PAT` with Work Items (Read); when the variable is
unset, as in the timer, it sources `~/.azure_devops_pat`. Defaults: organization
`innoguat`, project `Hemire`, assignee containing `dylan` or `dyool`; the
header of the script lists the `BOARDS_*` variables that change them
(`boards-backlog --help`).

What a run leaves behind:

| Where | What |
|---|---|
| Engram topic `boards/<project>/item-<id>` | One work item as text: fields, description, links, comments. |
| Engram topic `boards/<project>/backlog` | The ordered list. |
| `~/.local/state/boards-backlog/<project>/items/<id>.json` | The raw item exactly as the API returned it, plus comments. |
| `~/.local/state/boards-backlog/<project>/backlog.md` | The ordered list from the last run. |

A run saves an observation only when its text changed since the last save, and
each topic key updates the same observation, so running it daily adds no
duplicates. An item that leaves the backlog (closed, reassigned, or deleted on
the board) is saved once more with its final state, so Engram never keeps
describing it as open.

Limits:

- Severity exists only on bugs, so every bug sorts before items without one.
- "Open" means the state is not `Closed`, `Done`, or `Removed`.
- At most 200 comments per work item are fetched.
