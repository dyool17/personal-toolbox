#!/usr/bin/env bash
# Sandboxed tests for gentle-update.
#
# Every external tool gentle-update can call is a stub that only logs its
# arguments to $STUB_LOG, and HOME, the state directory, and the bin directory
# live under one mktemp directory, so no real tool is ever updated. The script
# under test is copied next to a stub gentle-rollback, which is where
# gentle-update looks for it first.
#
# Usage: bash scripts/linux/tests/gentle-update.test.sh
# Prints one ok/FAIL line per case and exits non-zero when any case failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

FAILS=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
check_not() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}
check_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# --- sandbox -----------------------------------------------------------------

export HOME="$SANDBOX/home"
export SANDBOX
export STUB_LOG="$SANDBOX/stub.log"
export GENTLE_UPDATE_BIN_DIR="$SANDBOX/bin"
export GENTLE_UPDATE_STATE_DIR="$SANDBOX/state"
export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
export GENTLE_SHELL_HOME="$HOME/.gentle-shell/agent"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export PNPM_HOME="$SANDBOX/pnpm"
# The run must not depend on the shell the tests were started from.
unset GENTLE_UPDATE_LOCK_HELD GENTLE_UPDATE_NO_SNAPSHOT XDG_STATE_HOME MISE_SHELL HERDR_ENV GENTLE_PI_CONFIG_HOME

APP="$SANDBOX/app"
STUBS="$SANDBOX/stubs"
mkdir -p "$APP" "$STUBS" "$GENTLE_UPDATE_BIN_DIR" "$PNPM_HOME/bin" "$SANDBOX/gopath" \
  "$PI_CODING_AGENT_DIR" "$GENTLE_SHELL_HOME" "$GENTLE_UPDATE_STATE_DIR/holds"
: > "$STUB_LOG"

# Only the standard Pi home has a Moshi hook; the Gentle Shell home never had one.
mkdir -p "$PI_CODING_AGENT_DIR/extensions"
: > "$PI_CODING_AGENT_DIR/extensions/moshi-hooks.ts"

cp "$HERE/../gentle-update" "$APP/gentle-update"
chmod 755 "$APP/gentle-update"

# Stub gentle-rollback: logs, prints a fixed snapshot id, and fails on demand.
cat > "$APP/gentle-rollback" <<'EOF'
#!/usr/bin/env bash
printf 'gentle-rollback %s\n' "$*" >> "$STUB_LOG"
if [ "${1:-}" = snapshot ]; then
  [ -e "$SANDBOX/fail-snapshot" ] && exit 1
  echo "20260101-000000"
fi
if [ "${1:-}" = restore ]; then
  # restore-rc selects the outcome: 0 restored, 3 nothing differed, 1 failed.
  rc="$(cat "$SANDBOX/restore-rc" 2>/dev/null || echo 0)"
  if [ "$rc" = 0 ] && [ ! -e "$SANDBOX/restore-does-not-fix" ]; then rm -f "$SANDBOX/claude-broken"; fi
  exit "$rc"
fi
exit 0
EOF
chmod 755 "$APP/gentle-rollback"

# One stub body for every tool; it behaves according to the name it runs as.
cat > "$SANDBOX/stub" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "$STUB_LOG"
case "$name $*" in
  "npm ls -g --depth=0 --json")
    [ -e "$SANDBOX/fail-npm-ls" ] && exit 1
    cat "$SANDBOX/npm-globals.json"
    ;;
  "npm install --global "*)
    [ -e "$SANDBOX/fail-npm-install" ] && exit 1
    ;;
  "git ls-remote "*)
    # Canned answer for the Gentle Shell main branch; never reaches the network.
    [ -e "$SANDBOX/fail-git-ls-remote" ] && exit 128
    cat "$SANDBOX/ls-remote.out"
    ;;
  "mise env -s bash")
    if [ -e "$SANDBOX/fail-mise-env" ]; then echo "mise: config error" >&2; exit 1; fi
    if [ ! -e "$SANDBOX/empty-mise-env" ]; then echo "export GENTLE_TEST_MISE_ENV=1"; fi
    ;;
  "claude plugin list")         echo "demo@market" ;;
  "claude update")              if [ -e "$SANDBOX/break-claude" ]; then touch "$SANDBOX/claude-broken"; fi ;;
  "claude --version")           [ -e "$SANDBOX/claude-broken" ] && exit 1; echo "2.1.289 (Claude Code)" ;;
  "go env GOPATH")              echo "$SANDBOX/gopath" ;;
  "moshi-hook doctor --json")   cat "$SANDBOX/doctor.json" ;;
  "moshi-hook update")
    # A real update replaces the binary; do the same when the test asks for it.
    if [ -e "$SANDBOX/moshi-new-build" ]; then
      { cat "$0"; echo "# new build"; } > "$0.new" && chmod 755 "$0.new" && mv -f "$0.new" "$0"
    fi
    if [ -e "$SANDBOX/doctor-after.json" ]; then cp "$SANDBOX/doctor-after.json" "$SANDBOX/doctor.json"; fi
    ;;
  *" --version")                echo "$name 1.0.0" ;;
esac
exit 0
EOF
for tool in npm pnpm claude codex opencode pi gentle-shell herdr mise go git; do
  install -m 755 "$SANDBOX/stub" "$STUBS/$tool"
done
install_bin_dir() {
  local tool
  for tool in gentle-ai engram moshi-hook; do
    install -m 755 "$SANDBOX/stub" "$GENTLE_UPDATE_BIN_DIR/$tool"
  done
}
install_bin_dir
export PATH="$STUBS:/usr/bin:/bin"

write_npm_globals() {
  cat > "$SANDBOX/npm-globals.json" <<'JSON'
{"name": "lib", "dependencies": {
  "@earendil-works/pi-coding-agent": {"version": "1.0.3"},
  "gentle-pi": {"version": "4.0.0"},
  "@openai/codex": {"version": "0.160.0"},
  "left-pad": {"version": "1.0.0"}
}}
JSON
}

# The commit `git ls-remote` reports for the Gentle Shell main branch, the
# file gentle-update records it in, and the commands the launcher step runs.
SHELL_SHA="1111111111111111111111111111111111111111"
SHELL_SHA_OLD="2222222222222222222222222222222222222222"
SHELL_COMMIT_FILE="$GENTLE_UPDATE_STATE_DIR/gentle-shell.commit"
SHELL_LS_REMOTE="git ls-remote https://github.com/Gentleman-Programming/gentle-shell refs/heads/main"
SHELL_INSTALL="npm install --global --allow-git=all github:Gentleman-Programming/gentle-shell#"
write_ls_remote() { printf '%s\trefs/heads/main\n' "$1" > "$SANDBOX/ls-remote.out"; }

DOCTOR_OK='{"features": [{"id": "inbox", "status": "ok", "readyAgents": ["claude", "pi"]}, {"id": "sessions", "status": "ok", "readyAgents": null}]}'
DOCTOR_REGRESSED='{"features": [{"id": "inbox", "status": "ok", "readyAgents": ["claude", "pi"]}, {"id": "sessions", "status": "error", "readyAgents": null}]}'

OUT=""
RC=0
# Reset the per-run switches, run gentle-update, and keep its output and status.
reset() {
  rm -f "$SANDBOX/fail-snapshot" "$SANDBOX/break-claude" "$SANDBOX/claude-broken" \
    "$SANDBOX/moshi-new-build" "$SANDBOX/doctor-after.json" "$GENTLE_UPDATE_STATE_DIR"/holds/* \
    "$SANDBOX/restore-rc" "$SANDBOX/restore-does-not-fix" "$SANDBOX/fail-npm-ls" \
    "$SANDBOX/fail-mise-env" "$SANDBOX/empty-mise-env" "$SANDBOX/fail-npm-install" \
    "$SANDBOX/fail-git-ls-remote" "$SHELL_COMMIT_FILE"
  write_npm_globals
  write_ls_remote "$SHELL_SHA"
  printf '%s\n' "$DOCTOR_OK" > "$SANDBOX/doctor.json"
  install_bin_dir
  : > "$STUB_LOG"
}
run_update() {
  OUT="$("$APP/gentle-update" "$@" 2>&1 </dev/null)"
  RC=$?
}
logged() { grep -qxF -- "$1" "$STUB_LOG"; }
# Any command that changes an installed tool.
UPDATE_COMMANDS='(^| )(update|upgrade|install|setup|self-update)( |$)'
first_line_of() { grep -nE -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }

# --- arguments ---------------------------------------------------------------

reset
run_update --help
check_eq "--help exits 0" "0" "$RC"
check "--help prints the usage" grep -q 'gentle-update \[all|agents|toolchain|plugins|packages|runtimes\]' <<<"$OUT"
check_not "--help runs no tool" test -s "$STUB_LOG"
run_update no-such-target
check_eq "unknown target exits 2" "2" "$RC"

# --- a full run --------------------------------------------------------------

reset
run_update all
check_eq "a clean run exits 0" "0" "$RC"
check "the snapshot names the target" logged "gentle-rollback snapshot --reason pre-update (all)"
SNAP_LINE="$(first_line_of '^gentle-rollback snapshot')"
UPDATE_LINE="$(first_line_of "$UPDATE_COMMANDS")"
check "the snapshot is taken before the first update command" test -n "$SNAP_LINE" -a -n "$UPDATE_LINE" -a "${SNAP_LINE:-0}" -lt "${UPDATE_LINE:-0}"
check "npm globals are updated package by package" logged "npm update -g @earendil-works/pi-coding-agent @openai/codex left-pad"
check "pnpm globals are updated without --latest" logged "pnpm update -g"
check "the Pi model catalog is refreshed" logged "pi update --models"
check "the Gentle Shell model catalog is refreshed" logged "gentle-shell --isolated update --models"
check "moshi-hook is updated" logged "moshi-hook update"
check_eq "Pi hooks are reinstalled only in the Pi home that had one" "1" "$(grep -cxF 'moshi-hook install --target pi' "$STUB_LOG")"
check "hooks are reinstalled for the other ready agent" logged "moshi-hook install --target claude"
check_not "hooks are not installed for agents that had none" grep -q 'install --target opencode' "$STUB_LOG"
check_not "the Moshi daemon is left alone when the binary did not change" logged "moshi-hook service restart"
check_not "doctor is never run with --yes" grep -qE 'doctor.*--yes' "$STUB_LOG"
check_not "no .prev backup is written" test -e "$GENTLE_UPDATE_BIN_DIR/gentle-ai.prev"
check_not "runtimes stay out of 'all'" logged "mise upgrade --yes"

# --- toolchain channels ------------------------------------------------------

reset
run_update toolchain
check_eq "a clean toolchain run exits 0" "0" "$RC"
check "gentle-ai is built from main" logged "go install github.com/gentleman-programming/gentle-ai/v4/cmd/gentle-ai@main"
check "engram is built from its latest release" logged "go install github.com/Gentleman-Programming/engram/v3/cmd/engram@latest"
check_eq "the toolchain builds exactly two Go binaries" "2" "$(grep -c '^go install ' "$STUB_LOG")"

# --- Gentle Shell launcher ---------------------------------------------------

reset
run_update all
check_eq "a clean launcher run exits 0" "0" "$RC"
check "the main commit is resolved with git ls-remote" logged "$SHELL_LS_REMOTE"
check "the launcher is installed from the resolved commit" logged "$SHELL_INSTALL$SHELL_SHA"
check_eq "the installed commit is recorded" "$SHELL_SHA" "$(cat "$SHELL_COMMIT_FILE" 2>/dev/null)"
check_not "the registry release is no longer installed" grep -q 'gentle-pi@latest' "$STUB_LOG"
check_not "gentle-pi is never given to npm update" grep -qE '^npm update .*gentle-pi' "$STUB_LOG"
check "the step is named after its source" grep -qF 'Gentle Shell launcher (gentle-shell main)' <<<"$OUT"
RESOLVE_LINE="$(first_line_of '^git ls-remote ')"
INSTALL_LINE="$(first_line_of '^npm install --global --allow-git=all ')"
check "the commit is resolved before the install" test -n "$RESOLVE_LINE" -a -n "$INSTALL_LINE" -a "${RESOLVE_LINE:-0}" -lt "${INSTALL_LINE:-0}"

reset
echo "$SHELL_SHA" > "$SHELL_COMMIT_FILE"
run_update agents
check_eq "an unchanged commit exits 0" "0" "$RC"
check "an unchanged commit is still resolved" logged "$SHELL_LS_REMOTE"
check_not "an unchanged commit is not reinstalled" grep -q '^npm install --global' "$STUB_LOG"
check_eq "an unchanged commit stays recorded" "$SHELL_SHA" "$(cat "$SHELL_COMMIT_FILE" 2>/dev/null)"

reset
echo "$SHELL_SHA_OLD" > "$SHELL_COMMIT_FILE"
run_update agents
check "a moved main is installed" logged "$SHELL_INSTALL$SHELL_SHA"
check_eq "a moved main replaces the recorded commit" "$SHELL_SHA" "$(cat "$SHELL_COMMIT_FILE" 2>/dev/null)"

# The record alone is not enough: the command it describes must exist.
reset
echo "$SHELL_SHA" > "$SHELL_COMMIT_FILE"
mv "$STUBS/gentle-shell" "$SANDBOX/hidden-gentle-shell"
run_update agents
mv "$SANDBOX/hidden-gentle-shell" "$STUBS/gentle-shell"
check "a missing gentle-shell command is reinstalled despite the record" logged "$SHELL_INSTALL$SHELL_SHA"

for unresolved in exit-status empty-output malformed-output; do
  reset
  echo "$SHELL_SHA_OLD" > "$SHELL_COMMIT_FILE"
  case "$unresolved" in
    exit-status)      touch "$SANDBOX/fail-git-ls-remote" ;;
    empty-output)     : > "$SANDBOX/ls-remote.out" ;;
    malformed-output) write_ls_remote "not-a-commit" ;;
  esac
  run_update agents
  check_eq "unresolved main ($unresolved) fails the run" "1" "$RC"
  check "unresolved main ($unresolved) is listed under Failed" grep -q 'Gentle Shell launcher' <<<"$(sed -n '/Failed/,$p' <<<"$OUT")"
  check_not "unresolved main ($unresolved) installs nothing" grep -q '^npm install --global' "$STUB_LOG"
  check_eq "unresolved main ($unresolved) keeps the recorded commit" "$SHELL_SHA_OLD" "$(cat "$SHELL_COMMIT_FILE" 2>/dev/null)"
  check "unresolved main ($unresolved) still updates other tools" logged "claude update"
done

reset
touch "$SANDBOX/fail-git-ls-remote"
run_update agents
check_not "unresolved main records nothing on a first run" test -e "$SHELL_COMMIT_FILE"

reset
touch "$SANDBOX/fail-npm-install"
run_update agents
check_eq "a failing launcher install fails the run" "1" "$RC"
check "a failing launcher install was attempted" logged "$SHELL_INSTALL$SHELL_SHA"
check_not "a failing launcher install records no commit" test -e "$SHELL_COMMIT_FILE"

reset
touch "$GENTLE_UPDATE_STATE_DIR/holds/gentle-shell"
run_update all
check_not "a held gentle-shell does not resolve main" grep -q '^git ls-remote' "$STUB_LOG"
check_not "a held gentle-shell is not reinstalled" grep -q '^npm install --global' "$STUB_LOG"
check_not "a held gentle-shell records no commit" test -e "$SHELL_COMMIT_FILE"

# --- Moshi -------------------------------------------------------------------

reset
touch "$SANDBOX/moshi-new-build"
run_update packages
check "the Moshi daemon restarts when the binary changed" logged "moshi-hook service restart"
check_eq "a clean packages run exits 0" "0" "$RC"

reset
printf '%s\n' "$DOCTOR_REGRESSED" > "$SANDBOX/doctor-after.json"
run_update packages
check_eq "a feature that stopped being ok fails the run" "1" "$RC"
check "the regressed feature is named" grep -q 'sessions' <<<"$OUT"

# --- holds -------------------------------------------------------------------

reset
touch "$GENTLE_UPDATE_STATE_DIR/holds/claude" "$GENTLE_UPDATE_STATE_DIR/holds/codex"
run_update all
check_eq "a run with holds exits 0" "0" "$RC"
check_not "a held component is not updated" logged "claude update"
check "a held component is listed under Skipped" grep -qF 'Claude Code — held by gentle-rollback (gentle-rollback unhold claude)' <<<"$(sed -n '/Skipped/,$p' <<<"$OUT")"
check "held npm packages are left out of the npm update" logged "npm update -g @earendil-works/pi-coding-agent left-pad"
check "other components still update" logged "opencode upgrade"

reset
touch "$GENTLE_UPDATE_STATE_DIR/holds/npm-globals" "$GENTLE_UPDATE_STATE_DIR/holds/moshi-hook"
run_update packages
check_not "a hold on npm-globals skips the whole npm step" grep -q '^npm update' "$STUB_LOG"
check_not "a held moshi-hook is not updated" logged "moshi-hook update"

# --- snapshot gate -----------------------------------------------------------

reset
touch "$SANDBOX/fail-snapshot"
run_update all
check_eq "a failing snapshot aborts with exit 1" "1" "$RC"
check "the snapshot was attempted" grep -q '^gentle-rollback snapshot' "$STUB_LOG"
check_not "no update command runs after a failed snapshot" grep -qE -- "$UPDATE_COMMANDS" "$STUB_LOG"

reset
touch "$SANDBOX/fail-snapshot"
GENTLE_UPDATE_NO_SNAPSHOT=1 run_update agents
check_eq "GENTLE_UPDATE_NO_SNAPSHOT=1 lets the run proceed" "0" "$RC"
check_not "GENTLE_UPDATE_NO_SNAPSHOT=1 takes no snapshot" grep -q '^gentle-rollback snapshot' "$STUB_LOG"
check "GENTLE_UPDATE_NO_SNAPSHOT=1 still updates" logged "claude update"

# --- lock --------------------------------------------------------------------

reset
(
  exec 8>"$GENTLE_UPDATE_STATE_DIR/lock"
  flock -n 8
  "$APP/gentle-update" all >/dev/null 2>&1 </dev/null
)
check_eq "a second concurrent run exits 0" "0" "$?"
check_not "a second concurrent run updates nothing" grep -qE -- "$UPDATE_COMMANDS" "$STUB_LOG"
check_not "a second concurrent run takes no snapshot" grep -q '^gentle-rollback' "$STUB_LOG"

# --- smoke check -------------------------------------------------------------

reset
touch "$SANDBOX/break-claude"
run_update agents
check_eq "a tool that broke fails the run" "1" "$RC"
check "the broken tool is rolled back to the pre-update snapshot" logged "gentle-rollback restore 20260101-000000 --only claude --yes"
check "the rollback is reported" grep -qF 'claude broke after the update; rolled back and held' <<<"$OUT"
check_eq "only the broken tool is rolled back" "1" "$(grep -c '^gentle-rollback restore' "$STUB_LOG")"

reset
touch "$SANDBOX/break-claude"
GENTLE_UPDATE_NO_SNAPSHOT=1 run_update agents
check_eq "a broken tool without a snapshot fails the run" "1" "$RC"
check "no snapshot: the tool is reported as not rolled back" grep -qF 'claude broke after the update; not rolled back (no snapshot)' <<<"$OUT"
check_not "no snapshot: no restore is attempted" grep -q '^gentle-rollback restore' "$STUB_LOG"

reset
touch "$SANDBOX/break-claude"
echo 3 > "$SANDBOX/restore-rc"
run_update agents
check "nothing differed: no rollback is claimed" grep -qF 'claude stopped working but its recorded state is unchanged; held, needs manual attention' <<<"$OUT"
check_not "nothing differed: 'rolled back' is not reported" grep -qF 'rolled back and held' <<<"$OUT"
check "nothing differed: the component is held" grep -q '^gentle-rollback hold claude ' "$STUB_LOG"

reset
touch "$SANDBOX/break-claude"
echo 1 > "$SANDBOX/restore-rc"
run_update agents
check "restore failed: reported as rollback failed" grep -qF 'claude broke after the update; rollback failed' <<<"$OUT"
check "restore failed: the component is still held" grep -q '^gentle-rollback hold claude ' "$STUB_LOG"

reset
touch "$SANDBOX/break-claude" "$SANDBOX/restore-does-not-fix"
run_update agents
check "a restore that leaves the tool broken is not reported as a rollback" grep -qF 'claude broke after the update; rollback failed' <<<"$OUT"
check_not "a restore that leaves the tool broken does not claim success" grep -qF 'rolled back and held' <<<"$OUT"

# --- mise bootstrap ----------------------------------------------------------

reset
touch "$SANDBOX/fail-mise-env"
run_update all
check_eq "a failing mise environment aborts with exit 1" "1" "$RC"
check "the mise error output is shown" grep -q 'mise: config error' <<<"$OUT"
check_not "a failing mise environment takes no snapshot" grep -q '^gentle-rollback' "$STUB_LOG"
check_not "a failing mise environment updates nothing" grep -qE -- "$UPDATE_COMMANDS" "$STUB_LOG"

reset
touch "$SANDBOX/empty-mise-env"
run_update all
check_eq "an empty mise environment aborts with exit 1" "1" "$RC"
check_not "an empty mise environment takes no snapshot" grep -q '^gentle-rollback' "$STUB_LOG"

reset
touch "$SANDBOX/fail-mise-env"
MISE_SHELL=bash run_update agents
check_eq "a mise-activated shell does not need the bootstrap" "0" "$RC"

# --- npm listing -------------------------------------------------------------

reset
touch "$SANDBOX/fail-npm-ls"
run_update packages
check_eq "a failing npm listing fails the run" "1" "$RC"
check "a failing npm listing is listed under Failed" grep -q 'npm globals' <<<"$(sed -n '/Failed/,$p' <<<"$OUT")"
check_not "a failing npm listing updates no npm package" grep -q '^npm update' "$STUB_LOG"

reset
echo 'not json' > "$SANDBOX/npm-globals.json"
run_update packages
check_eq "an unparseable npm listing fails the run" "1" "$RC"

reset
echo '{"name": "lib"}' > "$SANDBOX/npm-globals.json"
run_update packages
check_eq "an empty but valid npm listing is a success" "0" "$RC"
check_not "an empty npm listing updates nothing" grep -q '^npm update' "$STUB_LOG"

# --- dependency preflight ----------------------------------------------------

# A PATH with every system tool except the one under test.
SYS="$SANDBOX/sys"
mkdir -p "$SYS"
ln -s /usr/bin/* "$SYS/" 2>/dev/null
for missing in jq flock sha256sum timeout rg; do
  reset
  mv "$SYS/$missing" "$SANDBOX/hidden-tool"
  OUT="$(PATH="$STUBS:$SYS" "$APP/gentle-update" all 2>&1 </dev/null)"
  check_eq "missing $missing exits 1" "1" "$?"
  check "missing $missing is named" grep -qw -- "$missing" <<<"$OUT"
  check_not "missing $missing takes no snapshot" grep -q '^gentle-rollback' "$STUB_LOG"
  check_not "missing $missing updates nothing" grep -qE -- "$UPDATE_COMMANDS" "$STUB_LOG"
  mv "$SANDBOX/hidden-tool" "$SYS/$missing"
done

printf '\n'
if [ "$FAILS" -gt 0 ]; then
  printf '%d case(s) failed\n' "$FAILS"
  exit 1
fi
printf 'all cases passed\n'
