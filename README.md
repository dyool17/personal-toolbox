# skills
skills custom que he creado para solucionar problemas específicos con los que me he topado en el viaje de del desarrollo agentico de alta calidad y eficiencia

## Linux tool maintenance (`scripts/linux`)

Three scripts keep the local agent tooling current and recoverable:

| Script | What it does |
|---|---|
| `gentle-update` | Updates agents, the Gentleman toolchain, Claude plugins, and global packages. Snapshots first, skips held components, and rolls back a tool that stops running. |
| `gentle-rollback` | Takes snapshots, restores components from one, and manages holds. |
| `gentle-reset` | Clears stale state, caches, and long-lived daemons, then runs `gentle-update`. |

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
