# gentle-update: unattended daily run with rollback

Locator: `odd/tasks/gentle-update-daily-rollback.md` · Engram topic: `odd/gentle-update-daily-rollback/tasks`
Branch: `feat/gentle-update-daily-rollback` (branch point `acc7451`)

## Objective

`gentle-update` runs by itself once a day, and every run can be undone with
`gentle-rollback`.

## Problem and why

The script is only safe to run by hand: it assumes an interactive shell (mise
on PATH), keeps a single `.prev` copy that every run overwrites even when
nothing changed, and has no way to stop a broken release from being
reinstalled the next day. It also never reconciles Moshi hooks or restarts the
Moshi daemon after updating its binary.

## Scope

- `scripts/linux/gentle-rollback` (new): snapshots, restore, holds.
- `scripts/linux/gentle-update`: non-interactive bootstrap, lock, pre-update
  snapshot, holds, Moshi hooks + daemon, model catalogs, post-update smoke check.
- `scripts/linux/systemd/gentle-update.{service,timer}` (new).
- `scripts/linux/tests/` (new): sandboxed bash tests.
- `README.md`: short usage section.

Out of scope: Windows scripts, `gentle-reset` behaviour, `runtimes` rollback
(mise language runtimes stay opt-in and are not restorable).

## Constraints

- Never run as root. Never copy credentials (`auth.json`, tokens) into a snapshot.
- No update without a snapshot, unless `GENTLE_UPDATE_NO_SNAPSHOT=1`.
- A rolled-back component is held, so the next daily run does not reinstall it.
- A restore first snapshots the current state, so a rollback is itself reversible.
- Rollback never uninstalls anything that was added after the snapshot.
- Failures still exit 1 so systemd marks the run failed.

## Design

State dir: `${GENTLE_UPDATE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gentle-update}`

```
snapshots/<YYYYmmdd-HHMMSS>/   reason, versions.tsv, binaries.tsv, npm-globals.json,
                               pnpm-globals.json, homes/{pi,gentle-shell}/..., claude-plugins/
store/<sha256>                 content-addressed binaries, shared across snapshots
holds/<component>              one file per held component (reason + date)
lock                           flock shared by gentle-update and gentle-rollback
```

| Component | Snapshot | Restore |
|---|---|---|
| `gentle-ai`, `engram`, `herdr` | binary in `store/` | copy binary back |
| `moshi-hook` | binary in `store/` | copy back, reinstall hooks, restart service |
| `mise` | version | `mise self-update --yes <version>` |
| `claude` | version | `claude install <version>` |
| `opencode` | version | `opencode upgrade <version>` |
| `pi` | npm global version + home files | `npm install -g` + home files + `npm ci` in home |
| `gentle-shell` | npm global `gentle-pi` + home files | same as `pi`, isolated home |
| `codex` | npm global version | `npm install -g @openai/codex@<v>` |
| `npm-globals` | remaining npm globals | `npm install -g <pkg>@<v>` for changed ones |
| `pnpm-globals` | `pnpm ls -g --json` | `pnpm add -g <pkg>@<v>` for changed ones |
| `claude-plugins` | `installed_plugins.json` | copy back only if every `installPath` still exists |

Home files (whitelist, both Pi homes): `settings.json`, `models-store.json`,
`extensions/`, `agents/`, `gentle-ai/`, `skills/`, `chains/`,
`npm/package.json`, `npm/package-lock.json`.

Retention: `GENTLE_UPDATE_KEEP_SNAPSHOTS` (default 7), then unreferenced
`store/` blobs are removed.

## Tasks

- [x] **T1** `gentle-rollback`: `snapshot`, `list`, `show`, `restore`, `holds`,
  `hold`, `unhold`, with sandboxed tests. Route: delegated (writer trigger: 2+
  non-trivial files in the feature).
- [ ] **T2** `gentle-update` integration: mise/PATH bootstrap, `cd $HOME`, lock,
  pre-update snapshot, per-step holds, per-package npm globals, `--models`
  refresh, Moshi hooks + conditional daemon restart + `doctor --json`, pnpm
  without `--latest`, drop `.prev`, smoke check with auto-rollback. Route: delegated.
- [ ] **T3** systemd service + timer and README section. Route: delegated.
- [ ] **T4** Install: symlink `gentle-rollback`, link and enable the timer, take
  one real snapshot and read it back. Route: inline (parent, state commands).

## Acceptance criteria

- `gentle-rollback snapshot` succeeds on this machine and `show` lists every component.
- In a sandbox, restoring a replaced binary brings back the exact bytes and creates a hold.
- `gentle-update` skips a held component and reports it under "Skipped".
- `gentle-update` aborts before any update when the snapshot fails.
- `shellcheck` is clean on the Linux scripts; the test script passes.
- The timer is listed by `systemctl --user list-timers`.

## Checks

- `shellcheck scripts/linux/gentle-update scripts/linux/gentle-rollback scripts/linux/tests/*.sh`
- `bash scripts/linux/tests/gentle-rollback.test.sh`
- `systemd-analyze --user verify scripts/linux/systemd/gentle-update.service scripts/linux/systemd/gentle-update.timer`

Test-first: no test runner exists in the repo. The sandboxed bash test is
written first and observed failing before the implementation.

## Delivery

Forecast: about 750 authored lines, over the 400-line budget. No pull request
was requested for this personal repository; the chain strategy question is
deferred until one is.

## Verified facts (2026-10-05)

- `moshi-hook install --target pi` honours `PI_CODING_AGENT_DIR` (probed with a scratch dir).
- `moshi-hook update`, `moshi-hook service restart`, `moshi-hook doctor --json` exist; `doctor --json` runs without a TTY.
- Moshi hooks are currently installed for `claude`, `opencode`, `pi`.
- `pi update --all` help says "pi and installed packages"; models need `--models`.
- pi, npm, gentle-shell, codex, pnpm, go live under mise installs; shells use `mise activate`.
- Pi homes keep packages in `<home>/npm` with `package.json` + `package-lock.json`.
- `moshi-hook.service` is an enabled user unit; `Linger=yes`.

## Progress

- **T1** done. Route: delegated (one bounded writer). Commit: see the list at
  the end of this section.
  - RED: `bash scripts/linux/tests/gentle-rollback.test.sh` before the script
    existed: exit 1, 58 FAIL / 20 ok (the 20 were negative assertions).
  - GREEN: same command: exit 0, 79 ok, `all cases passed`.
  - `shellcheck scripts/linux/gentle-rollback scripts/linux/tests/gentle-rollback.test.sh`: clean.
  - Real machine, state dir in a scratch directory: `snapshot --reason verify`
    printed an id in about 2.6 s; `show latest` listed all 13 components as
    `same`; `restore latest --dry-run` reported nothing to restore.
  - Accepted additions to the brief: `snapshot` also takes the lock; retention
    never prunes the snapshot being restored; `hold`/`unhold` also accept
    `runtimes` (gentle-update honours it, nothing is restorable for it).
