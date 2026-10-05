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
exit 0
EOF
chmod 755 "$APP/gentle-rollback"

# One stub body for every tool; it behaves according to the name it runs as.
cat > "$SANDBOX/stub" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "$STUB_LOG"
case "$name $*" in
  "npm ls -g --depth=0 --json") cat "$SANDBOX/npm-globals.json" ;;
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
for tool in npm pnpm claude codex opencode pi gentle-shell herdr mise go; do
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

cat > "$SANDBOX/npm-globals.json" <<'EOF'
{"name": "lib", "dependencies": {
  "@earendil-works/pi-coding-agent": {"version": "1.0.3"},
  "gentle-pi": {"version": "4.0.0"},
  "@openai/codex": {"version": "0.160.0"},
  "left-pad": {"version": "1.0.0"}
}}
EOF

DOCTOR_OK='{"features": [{"id": "inbox", "status": "ok", "readyAgents": ["claude", "pi"]}, {"id": "sessions", "status": "ok", "readyAgents": null}]}'
DOCTOR_REGRESSED='{"features": [{"id": "inbox", "status": "ok", "readyAgents": ["claude", "pi"]}, {"id": "sessions", "status": "error", "readyAgents": null}]}'

OUT=""
RC=0
# Reset the per-run switches, run gentle-update, and keep its output and status.
reset() {
  rm -f "$SANDBOX/fail-snapshot" "$SANDBOX/break-claude" "$SANDBOX/claude-broken" \
    "$SANDBOX/moshi-new-build" "$SANDBOX/doctor-after.json" "$GENTLE_UPDATE_STATE_DIR"/holds/*
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
check "npm globals are updated package by package" logged "npm update -g @earendil-works/pi-coding-agent @openai/codex gentle-pi left-pad"
check "pnpm globals are updated without --latest" logged "pnpm update -g"
check "the Pi model catalog is refreshed" logged "pi update --models"
check "the Gentle Shell model catalog is refreshed" logged "gentle-shell --isolated update --models"
check "moshi-hook is updated" logged "moshi-hook update"
check_eq "Pi hooks are reinstalled for both Pi homes" "2" "$(grep -cxF 'moshi-hook install --target pi' "$STUB_LOG")"
check "hooks are reinstalled for the other ready agent" logged "moshi-hook install --target claude"
check_not "hooks are not installed for agents that had none" grep -q 'install --target opencode' "$STUB_LOG"
check_not "the Moshi daemon is left alone when the binary did not change" logged "moshi-hook service restart"
check_not "doctor is never run with --yes" grep -qE 'doctor.*--yes' "$STUB_LOG"
check_not "no .prev backup is written" test -e "$GENTLE_UPDATE_BIN_DIR/gentle-ai.prev"
check_not "runtimes stay out of 'all'" logged "mise upgrade --yes"

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
check "held npm packages are left out of the npm update" logged "npm update -g @earendil-works/pi-coding-agent gentle-pi left-pad"
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

printf '\n'
if [ "$FAILS" -gt 0 ]; then
  printf '%d case(s) failed\n' "$FAILS"
  exit 1
fi
printf 'all cases passed\n'
