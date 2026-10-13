#!/usr/bin/env bash
# Sandboxed tests for gentle-reset's temp scratch sweep.
#
# Nothing real is read or written: HOME and the swept temp root live under one
# mktemp directory, GENTLE_RESET_TMP_ROOTS points the sweep at that root only,
# and PATH holds stub tools ahead of the system directories. The pgrep stub
# reports a live Claude Code so the agent scratchpads step never reaches the
# real /tmp.
#
# Usage: bash scripts/linux/tests/gentle-reset.test.sh
# Prints one ok/FAIL line per case and exits non-zero when any case failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESET="$HERE/../gentle-reset"

SANDBOX="$(mktemp -d)" || exit 1
BUSY_PID=""
cleanup() {
  [ -n "$BUSY_PID" ] && kill "$BUSY_PID" 2>/dev/null
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

FAILS=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

# check <description> <command...> — the case passes when the command succeeds.
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
check_not() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

# --- sandbox -----------------------------------------------------------------

export HOME="$SANDBOX/home"
export STUB_LOG="$SANDBOX/stub.log"
ROOT="$SANDBOX/tmp-root"
export GENTLE_RESET_TMP_ROOTS="$ROOT"
unset HERDR_ENV

STUBS="$SANDBOX/stubs"
mkdir -p "$STUBS" "$HOME"

cat > "$SANDBOX/stub" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "$STUB_LOG"
# A live Claude Code keeps the agent scratchpads step away from the real /tmp.
[ "$name" = pgrep ] && printf '1\n'
exit 0
EOF
chmod +x "$SANDBOX/stub"
for tool in npm pnpm pgrep; do ln -s "$SANDBOX/stub" "$STUBS/$tool"; done
export PATH="$STUBS:/usr/bin:/bin"

# Rebuild the swept root: stale leftovers, plus everything that must survive.
seed() {
  [ -n "$BUSY_PID" ] && kill "$BUSY_PID" 2>/dev/null
  rm -rf "$ROOT"
  mkdir -p "$ROOT/stale-verify.abc/nested" "$ROOT/with-fifo" "$ROOT/busy" "$ROOT/.hidden"
  printf 'probe\n' > "$ROOT/stale-verify.abc/nested/probe.dll"
  : > "$ROOT/stale.log"
  mkfifo "$ROOT/with-fifo/agent.sock"
  ( cd "$ROOT/busy" && exec sleep 60 ) &
  BUSY_PID=$!
  # Wait for the child to enter its directory before the sweep looks at it.
  local tries=0
  while [ "$(readlink "/proc/$BUSY_PID/cwd" 2>/dev/null)" != "$ROOT/busy" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  : > "$STUB_LOG"
}

# --- cases -------------------------------------------------------------------

seed
bash "$RESET" caches --dry-run >/dev/null 2>&1
check     "dry run keeps a stale directory"          test -d "$ROOT/stale-verify.abc"
check     "dry run keeps a stale file"               test -f "$ROOT/stale.log"

seed
bash "$RESET" caches > "$SANDBOX/out.log" 2>&1
STATUS=$?
check     "caches exits 0"                           test "$STATUS" -eq 0
check_not "removes a stale directory"                test -e "$ROOT/stale-verify.abc"
check_not "removes a stale file"                     test -e "$ROOT/stale.log"
check     "keeps a directory holding a socket/fifo"  test -p "$ROOT/with-fifo/agent.sock"
check     "keeps a directory a live process is in"   test -d "$ROOT/busy"
check     "keeps hidden entries"                     test -d "$ROOT/.hidden"
check     "keeps the swept root itself"              test -d "$ROOT"
check     "lists a non-empty entry it reclaimed"     grep -q "stale-verify.abc" "$SANDBOX/out.log"
check     "only counts an empty entry"               grep -q "removed 2 entries (1 of them empty), kept 2 still in use" "$SANDBOX/out.log"
check     "still cleans the npm cache"               grep -qx "npm cache clean --force" "$STUB_LOG"
check     "still prunes the pnpm store"              grep -qx "pnpm store prune" "$STUB_LOG"

seed
bash "$RESET" state >/dev/null 2>&1
check     "other targets leave temp scratch alone"   test -d "$ROOT/stale-verify.abc"

# --- run log -----------------------------------------------------------------

LOGS="$HOME/.local/state/gentle-reset/logs"
latest_log() { readlink -f "$LOGS/latest.log"; }

seed
rm -rf "$LOGS"
bash "$RESET" caches > "$SANDBOX/out.log" 2>&1
check     "a run writes a log"                       test -s "$(latest_log)"
check     "the log holds the terminal output"        grep -q "stale-verify.abc" "$(latest_log)"
check     "the log records the command of a step"    grep -q "step 'pnpm store': reset_pnpm_store" "$(latest_log)"
check     "the log records a step's exit status"     grep -qE "step 'pnpm store' finished: exit 0 in [0-9]+s" "$(latest_log)"
check     "the log records how the run ended"        grep -qE 'finished: exit 0 after [0-9]+s' "$(latest_log)"
check_not "the log holds no color codes"             grep -q $'\033' "$(latest_log)"
check_not "a clean run does not print the log path"  grep -q 'run log:' "$SANDBOX/out.log"

# A failing npm makes the npm caches step fail.
seed
printf '#!/usr/bin/env bash\necho "npm ERR! cache is locked" >&2\nexit 7\n' > "$SANDBOX/npm-fail"
chmod +x "$SANDBOX/npm-fail"
ln -sf "$SANDBOX/npm-fail" "$STUBS/npm"
bash "$RESET" caches > "$SANDBOX/out.log" 2>&1
STATUS=$?
ln -sf "$SANDBOX/stub" "$STUBS/npm"
check     "a failed step still exits 1"              test "$STATUS" -eq 1
check     "a failed step reports its exit status"    grep -q "npm caches — failed (exit 1)" "$SANDBOX/out.log"
check     "a failed run prints the log path"         grep -qF "run log: $(latest_log)" "$SANDBOX/out.log"
check     "the log keeps a tool's error output"      grep -q "npm ERR! cache is locked" "$(latest_log)"
check     "the log records the failed step"          grep -qE "step 'npm caches' finished: exit 1" "$(latest_log)"

seed
rm -rf "$LOGS"
GENTLE_RESET_NO_LOG=1 bash "$RESET" state >/dev/null 2>&1
check_not "GENTLE_RESET_NO_LOG=1 writes no log"      test -e "$LOGS"

if [ "$FAILS" -gt 0 ]; then
  printf '\n%s case(s) failed\n' "$FAILS"
  exit 1
fi
printf '\nall cases passed\n'
