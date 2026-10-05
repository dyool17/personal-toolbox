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
- [x] **T2** `gentle-update` integration: mise/PATH bootstrap, `cd $HOME`, lock,
  pre-update snapshot, per-step holds, per-package npm globals, `--models`
  refresh, Moshi hooks + conditional daemon restart + `doctor --json`, pnpm
  without `--latest`, drop `.prev`, smoke check with auto-rollback. Route: delegated.
- [x] **T3** systemd service + timer and README section. Route: delegated.
- [ ] **T4** Install: symlink `gentle-rollback`, link and enable the timer, take
  one real snapshot and read it back. Route: inline (parent, state commands).
- [x] **T5** Fail closed on the unattended path: blob pruning, dependency
  preflight, retention value, empty `--only`, Moshi restore invariant, smoke
  check truthfulness, mise bootstrap, npm listing failure, pnpm test claim.
  Route: delegated (follow-up from the approved review; its findings were
  non-blocking).

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
- `bash scripts/linux/tests/gentle-update.test.sh`
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
- **T2** done. Route: delegated (same writer).
  - RED: `bash scripts/linux/tests/gentle-update.test.sh` against the
    unchanged script: exit 1, 26 FAIL / 17 ok.
  - GREEN: same command: exit 0, 43 ok, `all cases passed`.
  - `shellcheck` on both scripts and both tests: clean (also fixed the
    pre-existing SC1007 on `GOFLAGS=`).
  - Bare environment (`env -i HOME PATH=/usr/bin:/bin`) after the mise
    bootstrap resolves npm, pnpm, go, pi, gentle-shell, codex, claude, opencode.
  - Accepted changes to the brief: the smoke check restores the pre-update
    snapshot by id instead of `latest` (after a first restore `latest` is that
    restore's pre-rollback snapshot, which holds the broken state); with
    `GENTLE_UPDATE_NO_SNAPSHOT=1` a broken tool is reported, not rolled back.
  - Not exercised: a real `gentle-update` run (forbidden for the writer).
- **T3** done. Route: delegated (same writer).
  - `systemd-analyze --user verify` on both units: exit 0; the only output is
    an unrelated warning about `/usr/lib/systemd/user/spice-vdagent.service`.
  - README section is passive documentation: structural readback only.
- **T4** pending (parent): symlink `gentle-rollback`, link the service, enable
  the timer, take one real snapshot.

Commits on `feat/gentle-update-daily-rollback` after `acc7451`:

- `63c4356` T1 `feat(scripts): add gentle-rollback with snapshots and holds`
- `f54189e` T2 `feat(scripts): make gentle-update safe for unattended runs`
- T3 `feat(scripts): add daily systemd timer for gentle-update` (the commit
  that adds this line; see `git log`)

Next step: T4, then the first unattended run is worth reading in the journal,
since no real `gentle-update` run has exercised the new code yet.

Review: the native review of `acc7451..0cd84b6` was granted, approved and
acknowledged (lineage `review-cbc5586b681241d8`), assessed tier high.

- **T5** done. Route: delegated (same writer). Commit
  `fix(scripts): fail closed in gentle-update unattended paths` (the commit
  that adds this entry; see `git log 0cd84b6..`).
  - RED (new cases against the T1-T3 scripts): rollback test exit 1, 20 FAIL /
    87 ok; update test exit 1, 28 FAIL / 58 ok.
  - GREEN: rollback test exit 0, 107 ok; update test exit 0, 86 ok.
  - `shellcheck` on both scripts and both tests: clean.
  - Real machine, scratch state dir: `snapshot --reason verify` printed an id,
    `show latest` listed all 13 components as `same`.
  - `gentle-rollback restore` now exits 3 when nothing differed (was 0).
  - gentle-rollback no longer uses `rg`; gentle-update still does and checks it.
  - `npm ls -g` exiting non-zero now fails the npm step even when it printed a
    list (it exits 0 on this machine today). An extraneous global package
    would therefore fail the step until it is cleaned up.
  - Not changed (out of the stated scope): `gentle-update` itself still
    reinstalls the Pi Moshi hook in every existing Pi home when `pi` was a
    ready agent; only the restore path was restricted to homes that had it.
