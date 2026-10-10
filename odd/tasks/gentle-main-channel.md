# gentle-update: track main for gentle-ai and Gentle Shell

Locator: `odd/tasks/gentle-main-channel.md` · Engram topic: `odd/gentle-main-channel/tasks`
Branch: `feat/gentle-main-channel` (branch point `69f8e12`)

## Objective

`gentle-update` installs gentle-ai and the Gentle Shell launcher from the tip
of `main` instead of the latest release, and `gentle-rollback` can still put
back exactly what was installed before.

## Problem and why

Both tools are pinned to releases (`go install ...@latest`,
`npm install -g gentle-pi@latest`). The user wants the fixes that land on
`main` without waiting for a release. engram stays on its latest release.

Tracking `main` breaks one assumption `gentle-rollback` relies on: an npm
global installed from git reports only the `package.json` version, so two
different `main` commits are both `gentle-pi 4.0.0` and a restore would
reinstall the registry release.

## Evidence gathered before writing (2026-10-09)

- gentle-ai `main` declares `module github.com/gentleman-programming/gentle-ai/v4`,
  so `.../v4/cmd/gentle-ai@main` is a valid `go install` target.
- npm 12.2.0 refuses git packages by default (`EALLOWGIT`).
  `npm install --global --allow-git=all github:Gentleman-Programming/gentle-shell#main`
  succeeds in about 30s and installs a working `gentle-shell` (`--version` answers).
- After that install `npm ls -g --json --long` reports `version: 4.0.0` and no
  `resolved`, `from`, or `gitHead`: npm does not record the commit.
- The registry release and `main` are both `4.0.0` today.

## Scope

- `scripts/linux/gentle-update`: package pins, Gentle Shell install from a
  resolved `main` commit, comments and headings.
- `scripts/linux/gentle-rollback`: record and restore the Gentle Shell commit.
- `scripts/linux/tests/*.test.sh`: cases for the above.
- `README.md`: only where it states what each tool tracks.

Out of scope: engram (stays on `@latest`), Windows scripts, the Pi runtime,
the isolated home provisioning (`gentle-shell --isolated setup/update`).

## Constraints

- Unattended runs stay fail-closed: when the `main` commit cannot be resolved,
  the launcher is not reinstalled and the step is reported as failed.
- Snapshots taken before this change (no recorded commit) must still restore,
  through the registry version as they do today.
- A held `gentle-shell` or `gentle-ai` is still skipped.
- Artifacts in English; Conventional Commits; no AI attribution in commits.

## Design

- gentle-ai: `GENTLE_AI_PKG` ends in `@main`. Binaries are already
  content-addressed in the snapshot store, so rollback needs no change.
- Gentle Shell launcher: resolve the commit with
  `git ls-remote https://github.com/Gentleman-Programming/gentle-shell refs/heads/main`,
  install `github:Gentleman-Programming/gentle-shell#<sha>` with
  `--allow-git=all`, and record the sha in `$STATE/gentle-shell.commit` only
  after a successful install. Skip the install when the recorded sha already
  matches and `gentle-shell` is on PATH.
- The blanket `npm update -g` leaves `gentle-pi` out: it would move a git
  install back to the registry release.
- `gentle-rollback` copies `gentle-shell.commit` into each snapshot, treats a
  different commit as a change, and restores by commit when the snapshot has
  one (registry version otherwise), rewriting or removing the state file to
  match what is installed.

## Tasks

- [x] T1 — gentle-ai follows `main`. Route: delegated (single writer for T1–T3).
- [x] T2 — Gentle Shell launcher installs from a resolved `main` commit and is
  left out of the blanket npm update. Route: delegated.
- [x] T3 — `gentle-rollback` records and restores the Gentle Shell commit.
  Route: delegated.

Route evidence: T2 and T3 touch two non-trivial scripts plus both test files
(writer trigger).

## Acceptance criteria

- `gentle-update toolchain` runs `go install` with the gentle-ai `@main` path
  and the engram `@latest` path.
- The launcher step installs `github:…/gentle-shell#<sha>` with
  `--allow-git=all`, records the sha, and does nothing when it is unchanged.
- An unresolvable `main` fails the step without installing or recording.
- `npm update -g` is never given `gentle-pi`.
- A snapshot carries the commit; `restore --only gentle-shell` reinstalls that
  commit; a snapshot without one reinstalls `gentle-pi@<version>`.

## Checks

- `bash scripts/linux/tests/gentle-update.test.sh`
- `bash scripts/linux/tests/gentle-rollback.test.sh`
- `bash -n` on both scripts.

Baseline on the branch point: both suites print `all cases passed`.

## Delivery

Strategy: `ask-on-risk`. Forecast: about 200 authored changed lines, under the
400-line budget, one pull request slice.

## Progress

- T1 done in `cbef6c1`. RED: `gentle-ai is built from main` failed (1 case)
  before the pin changed. GREEN: `bash scripts/linux/tests/gentle-update.test.sh`
  ends with `all cases passed`; `bash -n scripts/linux/gentle-update` is clean.
  `install_release` was renamed `install_go_binary`.
- T2 done in `b4de0b9`. RED: 24 cases failed before the implementation (resolve,
  install by commit, record, skip when unchanged, the three unresolved shapes,
  and both `npm update -g` lists that still named `gentle-pi`). GREEN:
  `bash scripts/linux/tests/gentle-update.test.sh` ends with `all cases passed`;
  `bash -n scripts/linux/gentle-update` is clean. The lookup runs under
  `timeout 60` with `GIT_TERMINAL_PROMPT=0` so an unattended run cannot hang.
- T3 done in `c8d0fa5`. RED: 20 cases failed before the implementation (commit
  not captured, no difference reported, restores exiting 3). GREEN:
  `bash scripts/linux/tests/gentle-rollback.test.sh` ends with
  `all cases passed` (146 ok); `bash scripts/linux/tests/gentle-update.test.sh`
  ends with `all cases passed` (127 ok); `bash -n` is clean on both scripts.
- A snapshot without a commit differs from a launcher that has one, and the
  restore then reinstalls `gentle-pi@<version>` and removes the state file.
  A commit file that is not a 40-hex id is treated as no commit.
- `README.md` does not state which channel each tool tracks; left unchanged.

## Review

- Range `69f8e12..d74e4ea`, assessed `high` (`hot_path`, `shell_source`), 5
  paths, 550 changed lines. Consent granted by the user; four-lens native
  review `review-2830b6f0459bdd17` closed approved and was acknowledged
  (authority burned). No blocking finding, no correction.
- Reviewed boundary: `d74e4ea`.
- Advisory follow-ups, both `WARNING`, not fixed:
  - `scripts/linux/gentle-rollback` `restore_launcher`: the commit record is
    replaced only after the reinstall, so an interrupted restore leaves the
    launcher at the snapshot commit while the record names the previous one.
  - `scripts/linux/gentle-update` `install_gentle_shell`: the skip trusts that
    record, so in that state it reports `already at main commit` until main
    moves. Clearing the record before the reinstall would fail towards a
    reinstall.
- Follow-up fixed on user request (T4, inline route, one script plus its
  test): `restore_launcher` drops the commit record before the reinstall and
  writes it back only after success. RED: 2 cases failed (`a failing launcher
  reinstall drops the recorded commit`, `a failing registry reinstall drops
  the recorded commit`). GREEN: rollback suite `all cases passed`. With no
  record, `install_gentle_shell` reinstalls, so its skip needed no change.
- Delivery: the user chose a single merge of the branch into `main`.
