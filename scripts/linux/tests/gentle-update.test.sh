#!/usr/bin/env bash
# Sandboxed tests for gentle-update.
#
# Every external tool gentle-update can call is a stub that only logs its
# arguments to $STUB_LOG, and HOME, the state directory, and the bin directory
# live under one mktemp directory, so no real tool is ever updated. The script
# under test is copied next to a stub gentle-rollback, which is where
# gentle-update looks for it first.
#
# Usage: bash scripts/linux/tests/gentle-update.test.sh [--scripts-only|--v5-only]
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
export SANDBOX TMPDIR="$SANDBOX"
export STUB_LOG="$SANDBOX/stub.log"
export GENTLE_UPDATE_BIN_DIR="$SANDBOX/bin"
export GENTLE_UPDATE_STATE_DIR="$SANDBOX/state"
export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
export GENTLE_SHELL_HOME="$HOME/.gentle-shell/agent"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export PNPM_HOME="$SANDBOX/pnpm"
# The run must not depend on the shell the tests were started from.
unset GENTLE_UPDATE_LOCK_HELD GENTLE_UPDATE_NO_SNAPSHOT GENTLE_UPDATE_LOG_DIR GENTLE_UPDATE_NO_LOG GENTLE_UPDATE_TRACE XDG_STATE_HOME MISE_SHELL HERDR_ENV GENTLE_PI_CONFIG_HOME GENTLE_AI_HOME GENTLE_AI_PI_CONFIG_DIR ENGRAM_DATA_DIR GENTLE_UPDATE_ENGRAM_EXPORT_TIMEOUT

APP="$SANDBOX/app"
STUBS="$SANDBOX/stubs"
mkdir -p "$APP" "$STUBS" "$GENTLE_UPDATE_BIN_DIR" "$PNPM_HOME/bin" "$SANDBOX/gopath" \
  "$PI_CODING_AGENT_DIR" "$GENTLE_SHELL_HOME" "$GENTLE_UPDATE_STATE_DIR/holds"
: > "$STUB_LOG"

# Only the standard Pi home has a Moshi hook yet; the update wires both homes.
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
  if [ "$rc" = 0 ] && [ ! -e "$SANDBOX/restore-does-not-fix" ]; then
    case "$4" in
      claude) rm -f "$SANDBOX/claude-broken" ;;
      gentle-shell) rm -f "$SANDBOX/shell-broken" ;;
    esac
  fi
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
printf '%s %s|%s\n' "$name" "$*" "${npm_config_allow_scripts:-}" >> "$SANDBOX/script-env.log"
case "$name $*" in
  "npm ls -g --depth=0 --json")
    [ -e "$SANDBOX/fail-npm-ls" ] && exit 1
    cat "$SANDBOX/npm-globals.json"
    ;;
  "npm root -g") printf '%s\n' "$SANDBOX/npm-global-root" ;;
  "pnpm ls -g --depth=0 --json") cat "$SANDBOX/pnpm-globals.json" ;;
  "curl "*"https://registry.npmjs.org/gentle-pi/latest") cat "$SANDBOX/shell-latest.json" ;;
  "gentle-shell --version")
    [ ! -e "$SANDBOX/shell-broken" ] || exit 1
    id="$(basename "$(readlink "$HOME/.gentle-shell/current")")"
    printf 'gentle-shell %s\npi %s\n' "${id%-*}" "${id#*-}"
    ;;
  "gentle-shell upgrade --channel release")
    [ ! -e "$SANDBOX/fail-shell-upgrade" ] || exit 1
    if [ -e "$SANDBOX/break-shell-upgrade" ]; then touch "$SANDBOX/shell-broken"; fi
    version=5.0.0
    if [ -e "$SANDBOX/wrong-shell-version" ]; then version=6.0.0; fi
    if [ -e "$SANDBOX/native-no-change" ]; then exit 0; fi
    ln -sfn "versions/$version-1.6.0" "$HOME/.gentle-shell/current"
    ;;
  "pi update --all")
    if [ -e "$SANDBOX/native-rollback-during-pi" ]; then
      ln -sfn versions/5.0.0-1.6.0 "$HOME/.gentle-shell/current"
    fi ;;
  "gentle-shell --isolated setup")
    [ ! -e "$SANDBOX/fail-setup" ] || exit 73
    if [ -e "$SANDBOX/native-rollback-during-setup" ]; then
      ln -sfn versions/5.0.0-1.6.0 "$HOME/.gentle-shell/current"
    fi ;;
  "gentle-shell --isolated update --extensions")
    [ ! -e "$SANDBOX/fail-shell-extensions" ] || exit 74
    if [ -e "$SANDBOX/native-rollback-during-extensions" ]; then
      ln -sfn versions/5.0.0-1.6.0 "$HOME/.gentle-shell/current"
    fi ;;
  "gentle-shell --isolated update --models") [ ! -e "$SANDBOX/fail-shell-catalog" ] || exit 75 ;;
  "go install "*"/v5/cmd/gentle-ai@v5.0.0")
    [ ! -e "$SANDBOX/fail-ai-build" ] || exit 1
    install -m 755 "$SANDBOX/stub" "$GOBIN/gentle-ai"
    if [ ! -e "$SANDBOX/invalid-ai-build" ]; then echo '# v5 build' >> "$GOBIN/gentle-ai"; fi
    ;;
  "go install github.com/Gentleman-Programming/engram/v3/cmd/engram@latest")
    [ ! -e "$SANDBOX/fail-engram-install" ] || exit 19
    install -m 755 "$SANDBOX/stub" "$GOBIN/engram"
    printf '# new Engram build\n' >> "$GOBIN/engram"
    ;;
  "engram --version")
    if grep -qxF '# new Engram build' "$0"; then echo 'engram v3.7.2'; else echo 'engram v3.7.1'; fi
    ;;
  "engram export "*".json --all")
    grep -qxF '# new Engram build' "$0" && exit 71
    [ ! -e "$SANDBOX/empty-engram-export" ] || exit 0
    printf '%s\n' '{"version":1,"observations":[]}' > "$2"
    if [ -p "$SANDBOX/engram-export-fifo" ]; then exec tail -f "$SANDBOX/engram-export-fifo"; fi
    [ ! -e "$SANDBOX/fail-engram-export" ] || exit 72
    ;;
  "date -u "*)
    if [ -s "$SANDBOX/engram-backup-clock" ]; then cat "$SANDBOX/engram-backup-clock"; else exec /usr/bin/date "$@"; fi
    ;;
  "date "*) exec /usr/bin/date "$@" ;;
  "engram ps")
    grep -qxF '# new Engram build' "$0" || exit 73
    if [ -e "$SANDBOX/engram-ps-unavailable" ]; then
      echo 'unknown command "ps"' >&2
      exit 1
    fi
    if [ -e "$SANDBOX/engram-ps" ]; then
      cat "$SANDBOX/engram-ps"
    else
      echo 'Engram server is not running.'
    fi
    ;;
  "go version -m "*)
    major=4
    if grep -qxF '# v5 build' "$3"; then major=5; fi
    printf '%s: go1.26.7\n\tpath\tgithub.com/gentleman-programming/gentle-ai/v%s/cmd/gentle-ai\n\tmod\tgithub.com/gentleman-programming/gentle-ai/v%s\tv%s.0.0\th1:stub\n' "$3" "$major" "$major" "$major"
    ;;
  "gentle-ai --version")
    if grep -qxF '# v5 build' "$0"; then echo 'gentle-ai v5.0.0'; else echo 'gentle-ai v4.0.0'; fi
    ;;
  "mise env -s bash")
    if [ -e "$SANDBOX/fail-mise-env" ]; then echo "mise: config error" >&2; exit 1; fi
    if [ ! -e "$SANDBOX/empty-mise-env" ]; then echo "export GENTLE_TEST_MISE_ENV=1"; fi
    ;;
  "claude plugin list")         echo "demo@market" ;;
  "claude update")
    if [ -e "$SANDBOX/break-claude" ]; then touch "$SANDBOX/claude-broken"; fi
    if [ -e "$SANDBOX/break-shell-after-snapshot" ]; then touch "$SANDBOX/shell-broken"; fi
    case "${SHELL_KIND_SWITCH:-}" in
      bundle-to-legacy) rm -f "$SANDBOX/stubs/gentle-shell"; install -m 755 "$SANDBOX/stub" "$SANDBOX/stubs/gentle-shell" ;;
      legacy-to-bundle) ln -sfn "$HOME/.gentle-shell/bin/gentle-shell" "$SANDBOX/stubs/gentle-shell" ;;
    esac ;;
  "claude --version")           [ -e "$SANDBOX/claude-broken" ] && exit 1; echo "2.1.289 (Claude Code)" ;;
  "go env GOPATH")              echo "$SANDBOX/gopath" ;;
  "moshi-hook doctor --json")
    # A restarted daemon reports features as down until it is back up: one
    # warming-up answer per line left in doctor-warming.
    if [ -e "$SANDBOX/moshi-restarted" ] && [ -s "$SANDBOX/doctor-warming" ]; then
      sed -i 1d "$SANDBOX/doctor-warming"
      cat "$SANDBOX/doctor-warming.json"
    else
      cat "$SANDBOX/doctor.json"
    fi
    ;;
  "moshi-hook service restart") touch "$SANDBOX/moshi-restarted" ;;
  # Pi hooks go into whichever home the caller selected; record which one.
  "herdr plugin list")
    [ -e "$SANDBOX/herdr-has-plugin" ] && echo "- herdr-gentle-shell (Herdr Gentle Shell) enabled" ;;
  "herdr plugin update --yes")  [ -e "$SANDBOX/fail-herdr-update" ] && exit 1 ;;
  "codex plugin marketplace upgrade --help") [ -e "$SANDBOX/old-codex" ] && exit 2 ;;
  "herdr integration status")
    printf '%s\n' "claude: outdated (v9 < v11) (/x)" "codex: installed (v10) (/y)" "pi: not installed (/z)" ;;
  "moshi-hook install --target pi") printf '%s\n' "$PI_CODING_AGENT_DIR" >> "$SANDBOX/moshi-pi-homes.log" ;;
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
for tool in npm pnpm claude codex opencode pi gentle-shell herdr mise go git curl; do
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

write_npm_identity() {
  local dir="$SANDBOX/npm-global-root/$1"
  mkdir -p "$dir"
  printf '{"name":"%s"}\n' "$2" > "$dir/package.json"
}

write_npm_globals() {
  local pkg
  for pkg in @earendil-works/pi-coding-agent gentle-pi @openai/codex left-pad; do
    write_npm_identity "$pkg" "$pkg"
  done
  cat > "$SANDBOX/npm-globals.json" <<'JSON'
{"name": "lib", "dependencies": {
  "@earendil-works/pi-coding-agent": {"version": "1.0.3"},
  "gentle-pi": {"version": "4.0.0"},
  "@openai/codex": {"version": "0.160.0"},
  "left-pad": {"version": "1.0.0"}
}}
JSON
}

SHELL_PREFIX="$HOME/.gentle-shell"
SCRIPT_ALLOWLIST="gentle-pi,@google/genai,protobufjs"
SHELL_UPGRADE='gentle-shell upgrade --channel release'
AI_INSTALL='go install github.com/gentleman-programming/gentle-ai/v5/cmd/gentle-ai@v5.0.0'
SHELL_MANUAL='choose an exact v5 release at https://github.com/Gentleman-Programming/gentle-shell/releases and follow its installer or instructions from your package owner'
fixture_shell() {
  local version id dir
  for version in "$1" 5.0.0 5.1.0 6.0.0; do
    id="$version-1.6.0"
    dir="$SHELL_PREFIX/versions/$id"
    mkdir -p "$dir/node_modules/gentle-pi/bin" "$SHELL_PREFIX/bin"
    printf '%s\n' "$id" > "$dir/.gentle-shell-version"
    : > "$dir/node_modules/gentle-pi/bin/gentle-shell.mjs"
  done
  install -m 755 "$SANDBOX/stub" "$SHELL_PREFIX/bin/gentle-shell"
  printf '\n# gentle-shell bundled launcher (generated; do not edit)\nexec '\''/stub/node'\'' '\''%s/current/node_modules/gentle-pi/bin/gentle-shell.mjs'\'' "$@"\n' \
    "$SHELL_PREFIX" >> "$SHELL_PREFIX/bin/gentle-shell"
  ln -sfn "$SHELL_PREFIX/bin/gentle-shell" "$STUBS/gentle-shell"
  ln -sfn "versions/$1-1.6.0" "$SHELL_PREFIX/current"
}

DOCTOR_OK='{"features": [{"id": "inbox", "status": "ok", "readyAgents": ["claude", "pi"]}, {"id": "sessions", "status": "ok", "readyAgents": null}]}'
DOCTOR_REGRESSED='{"features": [{"id": "inbox", "status": "ok", "readyAgents": ["claude", "pi"]}, {"id": "sessions", "status": "error", "readyAgents": null}]}'

OUT=""
RC=0
# Reset the per-run switches, run gentle-update, and keep its output and status.
reset() {
  rm -f "$SANDBOX/fail-snapshot" "$SANDBOX/break-claude" "$SANDBOX/claude-broken" \
    "$SANDBOX/moshi-new-build" "$SANDBOX/doctor-after.json" "$GENTLE_UPDATE_STATE_DIR"/holds/* \
    "$SANDBOX/restore-rc" "$SANDBOX/restore-does-not-fix" "$SANDBOX/fail-npm-ls" \
    "$SANDBOX/fail-mise-env" "$SANDBOX/empty-mise-env" "$SANDBOX/fail-shell-upgrade" \
    "$SANDBOX/fail-setup" "$SANDBOX/fail-shell-extensions" "$GENTLE_UPDATE_STATE_DIR/gentle-shell-home.pending" \
    "$SANDBOX/break-shell-upgrade" "$SANDBOX/shell-broken" "$SANDBOX/wrong-shell-version" "$SANDBOX/native-no-change" \
    "$SANDBOX/fail-ai-build" "$SANDBOX/invalid-ai-build" "$STUBS/gentle-shell" "$GENTLE_UPDATE_BIN_DIR/gentle-ai" \
    "$SANDBOX/moshi-restarted" "$SANDBOX/doctor-warming" \
    "$SANDBOX/herdr-has-plugin" "$SANDBOX/fail-herdr-update" "$SANDBOX/old-codex"
  : > "$SANDBOX/moshi-pi-homes.log"
  mkdir -p "$HOME/.gentle-ai"
  printf '%s\n' '{"installed_agents": ["pi", "claude-code", "opencode", "codex"]}' > "$HOME/.gentle-ai/state.json"
  install -m 755 "$SANDBOX/stub" "$STUBS/opencode"
  write_npm_globals
  fixture_shell 4.1.0
  printf '%s\n' '{"name":"gentle-pi","version":"5.0.0"}' > "$SANDBOX/shell-latest.json"
  printf '%s\n' '[{"dependencies":{"left-pad":{"version":"1.0.0"}}}]' > "$SANDBOX/pnpm-globals.json"
  printf '%s\n' "$DOCTOR_OK" > "$SANDBOX/doctor.json"
  install_bin_dir
  : > "$STUB_LOG"
  : > "$SANDBOX/script-env.log"
}
run_update() {
  OUT="$("$APP/gentle-update" "$@" 2>&1 </dev/null)"
  RC=$?
}
logged() { grep -qxF -- "$1" "$STUB_LOG"; }
# Any command that changes an installed tool.
UPDATE_COMMANDS='(^| )(update|upgrade|install|setup|self-update)( |$)'
first_line_of() { grep -nE -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }

# Focused v5 cases capture both streams and mutation logs independently.
run_split() {
  local -a watchdog=()
  if [ "$1" = --watchdog ]; then watchdog=(timeout -k 1s 5s); shift; fi
  GENTLE_UPDATE_NO_LOG=1 "${watchdog[@]}" "$APP/gentle-update" "$@" >"$SANDBOX/stdout" 2>"$SANDBOX/stderr" </dev/null
  RC=$?
  OUT=$(<"$SANDBOX/stdout")
  ERR=$(<"$SANDBOX/stderr")
}
check_notice() {
  check "$1: notice on stdout" grep -qxF "  • $2" <<<"$OUT"
  check "$1: notice on stderr" grep -qxF $'\033[33m!\033[0m '"$2" <<<"$ERR"
}

# --- stable v5 and ownership --------------------------------------------------

for scenario in old absent shadowed incomplete broken-current absolute-current not-v5 unknown current held; do
  reset
  case "$scenario" in
    old) fixture_shell 4.0.0; message="unsupported launcher (4.0.0); $SHELL_MANUAL" ;;
    absent)
      rm -f "$STUBS/gentle-shell"
      message="not a verified bundled PATH launcher; $SHELL_MANUAL" ;;
    shadowed)
      install -m 755 "$SANDBOX/stub" "$GENTLE_UPDATE_BIN_DIR/gentle-shell"
      message="not a verified bundled PATH launcher; $SHELL_MANUAL" ;;
    incomplete)
      echo 'installing 4.1.0-1.6.0 1234' > "$SHELL_PREFIX/current/.gentle-shell-version"
      message="not a verified bundled PATH launcher; $SHELL_MANUAL" ;;
    broken-current)
      ln -sfn versions/9.9.9-1.6.0 "$SHELL_PREFIX/current"
      message="not a verified bundled PATH launcher; $SHELL_MANUAL" ;;
    absolute-current)
      ln -sfn "$SHELL_PREFIX/versions/4.1.0-1.6.0" "$SHELL_PREFIX/current"
      message="not a verified bundled PATH launcher; $SHELL_MANUAL" ;;
    not-v5)
      echo '{"name":"gentle-pi","version":"6.0.0"}' > "$SANDBOX/shell-latest.json"
      message="official latest stable is 6.0.0, not v5; $SHELL_MANUAL" ;;
    unknown)
      echo '{"name":"gentle-pi","version":"5.1.0-rc.1"}' > "$SANDBOX/shell-latest.json"
      message="could not verify the official latest stable release; $SHELL_MANUAL" ;;
    current) fixture_shell 5.0.0; message='already current (5.0.0)' ;;
    held)
      touch "$GENTLE_UPDATE_STATE_DIR/holds/gentle-shell"
      message='held by gentle-rollback (gentle-rollback unhold gentle-shell)' ;;
  esac
  run_split all
  check_eq "$scenario: exits 0" 0 "$RC"
  check_notice "$scenario" "Gentle Shell launcher — $message"
  check_not "$scenario: no native, legacy, or isolated Shell mutation" grep -qE \
    '^gentle-shell (upgrade|--isolated)|^npm install --global|^(npm|pnpm) update .* gentle-pi( |$)' "$STUB_LOG"
  check_not "$scenario: no Shell home policy" test -e "$GENTLE_SHELL_HOME/npm"
  check_not "$scenario: no Shell home hooks" grep -qxF "$GENTLE_SHELL_HOME" "$SANDBOX/moshi-pi-homes.log"
  check "$scenario: independently managed Pi still updates" logged 'pi update --all'
  rm -f "$GENTLE_UPDATE_BIN_DIR/gentle-shell"
done

reset
run_split agents
check_eq 'verified upgrade exits 0' 0 "$RC"
check 'stdout reports the upgraded version' grep -qxF '  gentle-shell gentle-shell 4.1.0 -> gentle-shell 5.0.0  (upgraded)' <<<"$OUT"
check 'only missing project policy is warned on stderr' test -z "$(grep -vF 'npm project not initialized yet:' <<<"$ERR")"
check 'the official release upgrade is called' logged "$SHELL_UPGRADE"
check 'extensions run after the upgrade' test "$(first_line_of '^gentle-shell upgrade')" -lt "$(first_line_of '^gentle-shell --isolated update --extensions')"
check_not 'bundled Pi self-update and npm install never run' grep -qE '^gentle-shell (update( |$)|--isolated update( --all| --self|$))|^npm install --global' "$STUB_LOG"

reset
install -m 755 "$SANDBOX/stub" "$SHELL_PREFIX/bin/pi"
ln -s "$SHELL_PREFIX/bin/pi" "$GENTLE_UPDATE_BIN_DIR/pi"
run_split all
check_eq 'bundled Pi is not treated as standalone: exits 0' 0 "$RC"
check_notice 'bundled Pi' 'PATH Pi runtime + extensions — not a separate Pi installation and home'
check_not 'bundled PATH Pi is not updated independently' grep -q '^pi update' "$STUB_LOG"
check 'Gentle AI sync still includes separately installed agents' logged 'gentle-ai sync --agents claude-code,opencode,codex'
rm -f "$GENTLE_UPDATE_BIN_DIR/pi"

for scenario in wrong-shell-version break-shell-upgrade native-no-change wrong-v5; do
  reset
  expected=5.0.0
  case "$scenario" in
    wrong-shell-version) touch "$SANDBOX/$scenario"; actual=6.0.0 ;;
    break-shell-upgrade) touch "$SANDBOX/$scenario"; actual=unverified ;;
    native-no-change|wrong-v5)
      expected=5.1.0
      actual=5.0.0
      echo '{"name":"gentle-pi","version":"5.1.0"}' > "$SANDBOX/shell-latest.json"
      if [ "$scenario" = native-no-change ]; then
        fixture_shell 5.0.0
        touch "$SANDBOX/$scenario"
      fi ;;
  esac
  rm -rf "$GENTLE_SHELL_HOME/npm"
  printf '%s\n' '{"mcpServers":{"test":{"command":"stub"}}}' > "$PI_CODING_AGENT_DIR/mcp.json"
  run_split agents
  check_eq "$scenario: exits 1" 1 "$RC"
  check "$scenario: upgrade failure is on stdout" grep -qxF '  • Gentle Shell launcher (stable v5)' <<<"$OUT"
  check "$scenario: recovery route is on stderr" grep -qxF $'\033[33m!\033[0m '"Gentle Shell launcher — expected active $expected after upgrade, found $actual; $SHELL_MANUAL" <<<"$ERR"
  check_not "$scenario: neither automatic rollback nor Shell home commands run" grep -qE '^gentle-rollback restore .* --only gentle-shell|^gentle-shell (upgrade --rollback|--isolated)' "$STUB_LOG"
  check_not "$scenario: no Shell home policy is created" test -e "$GENTLE_SHELL_HOME/npm"
  check_not "$scenario: no Shell MCP config is copied" test -e "$GENTLE_SHELL_HOME/mcp.json"
  if [ "$actual" != unverified ]; then
    check_eq "$scenario: active installation was not rolled back" "versions/$actual-1.6.0" "$(readlink "$SHELL_PREFIX/current")"
  fi
  rm -f "$GENTLE_SHELL_HOME/mcp.json"
done

# Keep the same activation and home across invocations, like a real daily run.
reset
run_split packages
check_eq 'packages before agents: exits 0' 0 "$RC"
check 'packages preserves the exact snapshot confirmation' grep -qxF $'\033[32m✓\033[0m snapshot 20260101-000000 (undo with: gentle-rollback restore 20260101-000000)' <<<"$OUT"
check_eq 'packages leaves the active Shell unchanged' 'versions/4.1.0-1.6.0' "$(readlink "$SHELL_PREFIX/current")"
check_eq 'packages before agents: stderr is empty' '' "$ERR"
check_not 'packages stdout has no launcher step' grep -qF 'Gentle Shell standalone launcher' <<<"$OUT"
check_not 'packages neither selects nor upgrades Shell' grep -qE '^curl |^gentle-shell (upgrade|--isolated)' "$STUB_LOG"
check_not 'packages does not copy Shell MCP config' test -e "$GENTLE_SHELL_HOME/mcp.json"
: > "$STUB_LOG"
run_split agents
check_eq 'agents after packages: exits 0' 0 "$RC"
check 'agents own the native upgrade' logged "$SHELL_UPGRADE"
check 'agents run isolated setup' logged 'gentle-shell --isolated setup'
check 'agents refresh isolated extensions' logged 'gentle-shell --isolated update --extensions'
check_eq 'agents finalize the Shell home' stub "$(jq -r '.mcpServers.test.command' "$GENTLE_SHELL_HOME/mcp.json")"
printf '%s\n' '{"mcpServers":{"later":{"command":"stub"}}}' > "$PI_CODING_AGENT_DIR/mcp.json"
: > "$STUB_LOG"
run_split agents
check_eq 'a later agents run exits 0' 0 "$RC"
check_notice 'stable no-op' 'Gentle Shell launcher — already current (5.0.0)'
check_not 'a stable no-op does not repeat the upgrade or home commands' grep -qE '^gentle-shell (upgrade|--isolated)' "$STUB_LOG"
check_eq 'a stable no-op does not repeat finalization' test "$(jq -r '.mcpServers | keys[]' "$GENTLE_SHELL_HOME/mcp.json")"
rm -f "$PI_CODING_AGENT_DIR/mcp.json" "$GENTLE_SHELL_HOME/mcp.json"

reset
run_split toolchain
check_eq 'toolchain exits 0' 0 "$RC"
check 'toolchain runs setup and refreshes extensions with its upgrade' test \
  "$(first_line_of '^gentle-shell --isolated setup$')" -lt "$(first_line_of '^gentle-shell --isolated update --extensions$')"

for scenario in held deferred; do
  reset
  if [ "$scenario" = held ]; then
    touch "$GENTLE_UPDATE_STATE_DIR/holds/gentle-shell"
  else
    echo '{"name":"gentle-pi","version":"6.0.0"}' > "$SANDBOX/shell-latest.json"
  fi
  echo '[{"dependencies":{"left-pad":{"version":"1.0.0"},"gentle-pi":{"version":"4.0.0"}}}]' > "$SANDBOX/pnpm-globals.json"
  run_split packages
  check_eq "$scenario Shell with pnpm globals exits 0" 0 "$RC"
  check_eq "$scenario: packages has no Shell notice on stderr" '' "$ERR"
  check "$scenario: pnpm exclusion is visible on stdout" grep -qxF '  leaving gentle-pi alone (managed by its installation owner)' <<<"$OUT"
  check "$scenario: unrelated pnpm globals still update" logged 'pnpm update -g left-pad'
  check_not "$scenario: neither manager updates the launcher" grep -qE '^pnpm update -g$|^(npm|pnpm) update .* gentle-pi( |$)' "$STUB_LOG"
done

for scenario in fail-ai-build invalid-ai-build; do
  reset
  touch "$SANDBOX/$scenario"
  run_split toolchain
  check_eq "$scenario: exits 1" 1 "$RC"
  check_notice "$scenario" 'gentle-ai (stable v5) — update failed (exit 1)'
  check_not "$scenario: old standalone v4 is not synced" grep -q '^gentle-ai sync' "$STUB_LOG"
  check "$scenario: existing binary bytes are unchanged" cmp -s "$SANDBOX/stub" "$GENTLE_UPDATE_BIN_DIR/gentle-ai"
done

reset
mkdir -p "$HOME/.pi/gentle-ai"
printf '%s\n' '{"path":"/missing-user-dev-binary"}' > "$HOME/.pi/gentle-ai/dev-binary.json"
run_split toolchain
check_eq 'standalone v5 build exits 0' 0 "$RC"
check 'successful sync is on stdout' grep -qxF $'\033[32m✓\033[0m gentle-ai sync' <<<"$OUT"
check 'only missing project policy is warned on stderr' test -z "$(grep -vF 'npm project not initialized yet:' <<<"$ERR")"
check 'standalone build uses the exact stable v5 module' logged "$AI_INSTALL"
check 'the synced standalone binary is v5' grep -qxF '# v5 build' "$GENTLE_UPDATE_BIN_DIR/gentle-ai"
check_eq 'a broken user development override is not redirected' '{"path":"/missing-user-dev-binary"}' "$(<"$HOME/.pi/gentle-ai/dev-binary.json")"

reset
mv "$GENTLE_UPDATE_BIN_DIR/gentle-ai" "$SHELL_PREFIX/bin/gentle-ai"
ln -s "$SHELL_PREFIX/bin/gentle-ai" "$GENTLE_UPDATE_BIN_DIR/gentle-ai"
run_split toolchain
check_eq 'an owner-managed Gentle AI is skipped without failure' 0 "$RC"
check_notice 'owner-managed Gentle AI' 'gentle-ai — not a standalone installation in the update bin directory; use its installation owner'
check_not 'a bundled or linked binary is not rebuilt or synced' grep -qE '^go install .*gentle-ai|^gentle-ai sync' "$STUB_LOG"
check 'the linked binary remains unchanged' cmp -s "$SANDBOX/stub" "$SHELL_PREFIX/bin/gentle-ai"

for scenario in fail-setup fail-shell-extensions; do
  reset
  touch "$SANDBOX/$scenario"
  run_split agents
  check_eq "$scenario: first run fails after activation" 1 "$RC"
  check_eq "$scenario: the v5 launcher stays active" 'versions/5.0.0-1.6.0' "$(readlink "$SHELL_PREFIX/current")"
  if [ "$scenario" = fail-setup ]; then step_name='Gentle Shell setup'; status=73
  else step_name='Gentle Shell extensions'; status=74; fi
  check "$scenario: stdout names the failed step" grep -qxF "  • $step_name" <<<"$OUT"
  check "$scenario: stderr reports the failed step and status" grep -qxF $'\033[33m!\033[0m '"$step_name — update failed (exit $status)" <<<"$ERR"
  rm -f "$SANDBOX/$scenario"
  : > "$STUB_LOG"
  run_split agents
  check_eq "$scenario: retry exits 0" 0 "$RC"
  check "$scenario: current Shell retries setup" logged 'gentle-shell --isolated setup'
  check "$scenario: current Shell retries extensions" logged 'gentle-shell --isolated update --extensions'
  check "$scenario: stdout reports successful retry" grep -qxF $'\033[32m✓\033[0m Gentle Shell extensions' <<<"$OUT"
  check_not "$scenario: retry reports no update failed message" grep -qF 'update failed' <<<"$ERR"
  check_not "$scenario: retry does not upgrade the launcher again" logged "$SHELL_UPGRADE"
  : > "$STUB_LOG"
  run_split agents
  check_eq "$scenario: completed home exits 0" 0 "$RC"
  check_not "$scenario: completed home is not retried again" grep -qE '^gentle-shell (upgrade|--isolated)' "$STUB_LOG"
done

reset
write_npm_identity gs-legacy gentle-pi
printf '%s\n' '{"dependencies":{"gs-legacy":{"version":"4.0.0","overridden":false},"left-pad":{"version":"1.0.0","overridden":false}}}' > "$SANDBOX/npm-globals.json"
run_split packages
check_eq 'npm alias: packages exits 0' 0 "$RC"
check_eq 'npm alias: no errors or warnings on stderr' '' "$ERR"
check 'npm alias: exclusion is visible on stdout' grep -qxF '  leaving gs-legacy alone (managed by its installation owner)' <<<"$OUT"
check_not 'npm alias: gentle-pi alias is not updated' grep -qE '^npm update .* gs-legacy( |$)' "$STUB_LOG"
check 'npm alias: the ordinary global still updates with scoped allowlist' logged "npm update -g --allow-scripts=$SCRIPT_ALLOWLIST left-pad"

run_split --help
check_eq 'help exits 0' 0 "$RC"
check_eq 'help emits no stderr' '' "$ERR"
check_not 'help does not promise packages installs Moshi hooks in both Pi homes' grep -qF 'and both Pi homes' <<<"$OUT"

for phase in pi setup extensions; do
  reset
  fixture_shell 5.1.0
  rm -rf "$GENTLE_SHELL_HOME/npm"
  pending="$GENTLE_UPDATE_STATE_DIR/gentle-shell-home.pending"
  printf '5.1.0\n' > "$pending"
  flag="$SANDBOX/native-rollback-during-$phase"
  touch "$flag"
  run_split agents
  rm -f "$flag"
  check_eq "rollback during $phase: exits 1" 1 "$RC"
  check_eq "rollback during $phase: 5.0.0 remains active" 'versions/5.0.0-1.6.0' "$(readlink "$SHELL_PREFIX/current")"
  check "rollback during $phase: pending version is unchanged byte-for-byte" cmp -s "$pending" <(printf '5.1.0\n')
  check_notice "rollback during $phase" "Gentle Shell home — expected active 5.1.0, found 5.0.0; $SHELL_MANUAL"
  case "$phase" in
    pi)
      check_not 'rollback before setup: no isolated commands' grep -q '^gentle-shell --isolated' "$STUB_LOG"
      check_not 'rollback before setup: no home policy changes' test -e "$GENTLE_SHELL_HOME/npm" ;;
    setup|extensions)
      expected='gentle-shell --isolated setup'
      if [ "$phase" = extensions ]; then expected+=$'\ngentle-shell --isolated update --extensions'; fi
      check_eq "rollback during $phase: no further isolated commands" "$expected" "$(grep '^gentle-shell --isolated' "$STUB_LOG")" ;;
  esac
done

reset
ln -s "$HOME" "$SANDBOX/linked-home"
HOME="$SANDBOX/linked-home" run_split agents
check_eq 'symlinked HOME exits 0' 0 "$RC"
check 'symlinked HOME stdout reports the upgrade' grep -qxF '  gentle-shell gentle-shell 4.1.0 -> gentle-shell 5.0.0  (upgraded)' <<<"$OUT"
check_not 'symlinked HOME stderr does not reject launcher ownership' grep -qF 'not a verified bundled PATH launcher' <<<"$ERR"
check 'symlinked HOME upgrades natively' logged "$SHELL_UPGRADE"
check_not 'symlinked HOME never uses legacy install or restore' grep -qE '^npm install --global|^gentle-rollback restore' "$STUB_LOG"

reset
ln -s . "$SANDBOX/install-parent"
ln -s . "$SANDBOX/run-parent"
install_home="$SANDBOX/install-parent/home"
run_home="$SANDBOX/run-parent/home"
SHELL_PREFIX="$install_home/.gentle-shell" fixture_shell 4.1.0
HOME="$run_home" run_split agents
check_eq 'equivalent HOME aliases exit 0' 0 "$RC"
check 'equivalent HOME aliases upgrade natively' logged "$SHELL_UPGRADE"
check_eq 'equivalent HOME aliases activate v5' versions/5.0.0-1.6.0 "$(readlink "$SHELL_PREFIX/current")"
check 'equivalent HOME aliases report the upgrade' grep -qxF '  gentle-shell gentle-shell 4.1.0 -> gentle-shell 5.0.0  (upgraded)' <<<"$OUT"
check_not 'equivalent HOME aliases do not reject launcher ownership' grep -qF 'not a verified bundled PATH launcher' <<<"$ERR"

for kind in legacy bundled; do
  reset
  SHELL_PREFIX="$install_home/.gentle-shell" fixture_shell 5.0.0
  if [ "$kind" = legacy ]; then
    rm -f "$STUBS/gentle-shell"
    install -m 755 "$SANDBOX/stub" "$STUBS/gentle-shell"
    kind_switch=legacy-to-bundle
  else
    kind_switch=bundle-to-legacy
  fi
  touch "$SANDBOX/break-shell-after-snapshot"
  HOME="$run_home" SHELL_KIND_SWITCH="$kind_switch" run_split agents
  rm -f "$SANDBOX/break-shell-after-snapshot"
  check_eq "$kind smoke failure exits 1" 1 "$RC"
  check "$kind smoke failure is reported on stderr" grep -qxF $'\033[33m!\033[0m gentle-shell no longer runs after the update' <<<"$ERR"
  if [ "$kind" = legacy ]; then
    check 'legacy-to-bundle switch occurred' test -L "$STUBS/gentle-shell"
    check 'legacy smoke failure uses the snapshot' logged 'gentle-rollback restore 20260101-000000 --only gentle-shell --yes'
    check 'legacy recovery is reported on stdout' grep -qxF '  • gentle-shell broke after the update; rolled back and held' <<<"$OUT"
  else
    check_not 'bundle-to-legacy switch occurred' test -L "$STUBS/gentle-shell"
    check_not 'bundled smoke failure never uses legacy restore' grep -q '^gentle-rollback restore' "$STUB_LOG"
    check 'bundled recovery points to native rollback on stdout' grep -qxF "  • gentle-shell broke after the update; use native 'gentle-shell upgrade --rollback' if available; otherwise $SHELL_MANUAL" <<<"$OUT"
  fi
done

reset
SHELL_PREFIX="$install_home/.gentle-shell" fixture_shell 4.1.0
touch "$SANDBOX/fail-shell-catalog"
HOME="$install_home" run_split agents
rm -f "$SANDBOX/fail-shell-catalog"
check_eq 'catalog failure exits 1' 1 "$RC"
check 'catalog failure appears on stdout' grep -qxF '  • Gentle Shell model catalog' <<<"$OUT"
check 'catalog failure appears on stderr' grep -qxF $'\033[33m!\033[0m Gentle Shell model catalog — update failed (exit 75)' <<<"$ERR"
check 'catalog failure preserves exact pending version' cmp -s "$pending" <(printf '5.0.0\n')
: > "$STUB_LOG"
HOME="$run_home" run_split agents
check_eq 'catalog retry exits 0' 0 "$RC"
check 'catalog retry reports success' grep -qxF $'\033[32m✓\033[0m Gentle Shell model catalog' <<<"$OUT"
check_not 'catalog retry does not reinstall the launcher' logged "$SHELL_UPGRADE"
check_not 'catalog retry success clears pending work' test -e "$pending"

# --- Engram backup and running version ---------------------------------------

ENGRAM_INSTALL='go install github.com/Gentleman-Programming/engram/v3/cmd/engram@latest'
ENGRAM_RESTART="engram — the running server still uses the old version; run \`engram restart\` when sessions are idle. If the Pi companion needs updating, run \`engram setup pi\` and restart Pi."
ENGRAM_UNKNOWN="engram — the running server version could not be confirmed with \`engram ps\`."
ENGRAM_EXPORT_FAILED="engram — memory backup failed; binary left unchanged. In a private directory, run \`umask 077; engram export ./engram-manual-backup.json --all\` (choose a new filename), then retry \`gentle-update toolchain\`."
backups="$GENTLE_UPDATE_STATE_DIR/engram-backups"
engram_db="$HOME/.engram/engram.db"
backup_files() {
  find "$backups" -maxdepth 1 -type f \( -name 'engram-*.json' -o -name 'gentle-update-engram-*.json' \) \
    ! -name 'engram-manual.json' ! -name '*-Personal.json' 2>/dev/null | LC_ALL=C sort
}
reported_backup() { sed -n 's/^.*engram memory backup: //p' <<<"$OUT"; }

for scenario in pending mismatch matching stopped unknown unavailable export-failed export-empty backup-dir-symlink export-timeout fresh no-data held; do
  reset
  rm -rf "$backups" "$HOME/.engram" "$SANDBOX/custom Engram"
  rm -f "$SANDBOX/engram-ps" "$SANDBOX/engram-ps-unavailable" "$SANDBOX/fail-engram-export" \
    "$SANDBOX/empty-engram-export" "$SANDBOX/engram-export-fifo"
  if [ "$scenario" = mismatch ]; then
    # Honor a configured data directory even when the default does not exist.
    export ENGRAM_DATA_DIR="$SANDBOX/custom Engram"
  fi
  engram_db="${ENGRAM_DATA_DIR:-$HOME/.engram}/engram.db"
  mkdir -p "${engram_db%/*}"
  printf 'sandbox SQLite fixture\n' > "$engram_db"
  case "$scenario" in
    pending|mismatch)
      printf '%s\n' 'Status: running' 'Installed version: 3.7.2' 'Server version: 3.7.1' > "$SANDBOX/engram-ps"
      if [ "$scenario" = pending ]; then
        printf '%s\n' 'Restart pending: run engram restart' >> "$SANDBOX/engram-ps"
        # Also exercise the explicit pending flag, independent of parsing versions.
        sed -i '/Server version:/d' "$SANDBOX/engram-ps"
      fi ;;
    matching|unknown)
      server=3.7.2
      if [ "$scenario" = unknown ]; then server=unknown; fi
      printf '%s\n' 'Status: running' 'Installed version: v3.7.2' "Server version: $server" > "$SANDBOX/engram-ps"
      if [ "$scenario" = matching ]; then printf '%s\n' 'Restart pending: no' >> "$SANDBOX/engram-ps"; fi ;;
    unavailable) touch "$SANDBOX/engram-ps-unavailable" ;;
    export-failed) touch "$SANDBOX/fail-engram-export" ;;
    export-empty) touch "$SANDBOX/empty-engram-export" ;;
    backup-dir-symlink)
      mkdir -m 755 "$SANDBOX/other-backups"
      ln -s "$SANDBOX/other-backups" "$backups" ;;
    export-timeout) mkfifo "$SANDBOX/engram-export-fifo" ;;
    fresh) rm -f "$GENTLE_UPDATE_BIN_DIR/engram" ;;
    no-data) rm -f "$engram_db" ;;
    held) touch "$GENTLE_UPDATE_STATE_DIR/holds/engram" ;;
  esac

  if [ "$scenario" = export-timeout ]; then
    GENTLE_UPDATE_ENGRAM_EXPORT_TIMEOUT=1 run_split --watchdog toolchain
  else
    run_split toolchain
  fi
  check_not "$scenario: never invokes Engram lifecycle or Pi setup" grep -qE '^engram (restart|stop|run|start|setup)( |$)' "$STUB_LOG"
  check_eq "$scenario: curl only checks the Shell release registry" 'curl --disable --fail --silent --max-time 15 https://registry.npmjs.org/gentle-pi/latest' "$(grep '^curl ' "$STUB_LOG")"
  if [ "$scenario" != no-data ]; then
    check "$scenario: original database fixture remains unchanged" cmp -s "$engram_db" <(printf 'sandbox SQLite fixture\n')
  fi
  case "$scenario" in
    export-*|backup-dir-symlink)
      check_eq "$scenario: exits 1" 1 "$RC"
      check_notice "$scenario" "$ENGRAM_EXPORT_FAILED"
      check_notice "$scenario" 'engram — update failed (exit 1)'
      check_eq "$scenario: no published or partial backup files" '' "$(find "$backups" -mindepth 1 -print 2>/dev/null)"
      check_eq "$scenario: no reported backup" '' "$(reported_backup)"
      if [ "$scenario" = backup-dir-symlink ]; then
        check_not "$scenario: never invokes export" grep -q '^engram export ' "$STUB_LOG"
        check_eq "$scenario: target unchanged" 755 "$(stat -c %a "$SANDBOX/other-backups")"
        check_eq "$scenario: target stays empty" '' "$(find "$SANDBOX/other-backups" -mindepth 1 -print)"
      else
        check "$scenario: attempted export" grep -qE '^engram export .+\.json --all$' "$STUB_LOG"
      fi ;;
    held)
      check_eq "$scenario: exits 0" 0 "$RC"
      check "$scenario: held skip on stdout" grep -qxF '  • engram — held by gentle-rollback (gentle-rollback unhold engram)' <<<"$OUT"
      check "$scenario: held skip on stderr" grep -qxF $'\033[33m!\033[0m engram — held by gentle-rollback (gentle-rollback unhold engram)' <<<"$ERR"
      check_not "$scenario: export skipped" grep -q '^engram export ' "$STUB_LOG"
      check_not "$scenario: no backup directory" test -e "$backups" ;;
    *)
      check_eq "$scenario: exits 0" 0 "$RC"
      check "$scenario: installs the latest v3 release" logged "$ENGRAM_INSTALL"
      check "$scenario: checks daemon status after installation" test "$(first_line_of '^go install .*cmd/engram@latest$')" -lt "$(first_line_of '^engram ps$')"
      case "$scenario" in
        fresh|no-data)
          check_not "$scenario: export skipped" grep -q '^engram export ' "$STUB_LOG"
          check_not "$scenario: no backup directory" test -e "$backups"
          check_eq "$scenario: no backup notice" '' "$(grep -F 'engram memory backup:' <<<"$OUT")" ;;
        *)
          backup="$(backup_files)"
          check "$scenario: snapshot precedes export" test "$(first_line_of '^gentle-rollback snapshot ')" -lt "$(first_line_of '^engram export ')"
          check "$scenario: export precedes install" test "$(first_line_of '^engram export ')" -lt "$(first_line_of '^go install .*cmd/engram@latest$')"
          check_eq "$scenario: backup directory mode" 700 "$(stat -c %a "$backups" 2>/dev/null)"
          check_eq "$scenario: backup file mode" 600 "$(stat -c %a "$backup" 2>/dev/null)"
          check "$scenario: exported JSON only" cmp -s "$backup" <(printf '%s\n' '{"version":1,"observations":[]}')
          check "$scenario: reports the backup path" grep -qxF $'\033[32m✓\033[0m '"engram memory backup: $backup" <<<"$OUT" ;;
      esac
      case "$scenario" in
        pending|mismatch) check_notice "$scenario" "$ENGRAM_RESTART Backup: $backup" ;;
        unknown|unavailable) check_notice "$scenario" "$ENGRAM_UNKNOWN Backup: $backup" ;;
        *)
          check_not "$scenario: no server warning on stdout" grep -qF 'engram —' <<<"$OUT"
          check_not "$scenario: no server warning on stderr" grep -qF 'engram —' <<<"$ERR" ;;
      esac ;;
  esac
  if [[ "$scenario" = export-* || "$scenario" = backup-dir-symlink || "$scenario" = held ]]; then
    check_not "$scenario: never replaces the binary" logged "$ENGRAM_INSTALL"
    check "$scenario: installed binary is unchanged" cmp -s "$GENTLE_UPDATE_BIN_DIR/engram" "$SANDBOX/stub"
    check_not "$scenario: does not check server status" logged 'engram ps'
  fi
  unset ENGRAM_DATA_DIR
done

reset
mkdir -p "$backups"
printf 'user export\n' > "$backups/engram-manual.json"
lookalike="$backups/engram-19990101T000000.000000000Z-Personal.json"
printf 'operator-owned\n' > "$lookalike"
mkdir "$backups/nested"
nested="$backups/nested/gentle-update-engram-20200101T000000Z-000000001.json"
link="$backups/gentle-update-engram-20200101T000000Z-000000002.json"
: > "$nested"
ln -s "$backups/engram-manual.json" "$link"
install -m 755 "$SANDBOX/stub" "$STUBS/date"
for n in 0 1 2 3; do
  install_bin_dir
  printf '2031010%dT000000.000000000Z\n' "$((n + 2))" > "$SANDBOX/engram-backup-clock"
  run_split toolchain
  check_eq "retention run $n: exits 0" 0 "$RC"
  new_backup[n]="$(reported_backup)"
  check_eq "$n: records a distinct timestamped backup" "gentle-update-engram-2031010$((n + 2))T000000Z-000000000.json" "${new_backup[n]##*/}"
done
check_eq 'retention: exactly three updater exports remain' 3 "$(backup_files | wc -l)"
check_eq 'retention: only the last three updater exports remain' "$(printf '%s\n' "${new_backup[@]:1}")" "$(backup_files)"
check 'retention: leaves unrelated exports unchanged' cmp -s "$backups/engram-manual.json" <(printf 'user export\n')
check 'retention: preserves the operator look-alike byte-for-byte' cmp -s "$lookalike" <(printf 'operator-owned\n')
check 'retention: leaves nested files alone' test -f "$nested"
check 'retention: leaves matching symlinks alone' test -L "$link"
check_not 'retention: never invokes Engram lifecycle or Pi setup' grep -qE '^engram (restart|stop|run|start|setup)( |$)' "$STUB_LOG"

reset
printf '20310101T000000.000000000Z\n' > "$SANDBOX/engram-backup-clock"
touch "$SANDBOX/fail-engram-install"
run_split toolchain
backup="$(reported_backup)"
check_eq 'backward clock and failed install: exits 1' 1 "$RC"
check_notice 'backward clock and failed install' 'engram — update failed (exit 19)'
check 'backward clock: installer was attempted' logged "$ENGRAM_INSTALL"
check 'backward clock: installed binary is unchanged' cmp -s "$GENTLE_UPDATE_BIN_DIR/engram" "$SANDBOX/stub"
check 'backward clock: reported backup still contains the exported data' cmp -s "$backup" <(printf '%s\n' '{"version":1,"observations":[]}')
check_eq 'backward clock: keeps the reported backup and the two newest older-run backups' \
  "$(printf '%s\n' "$backup" "${new_backup[@]:2}")" "$(backup_files)"
check_not 'backward clock: does not check server status after installation failure' logged 'engram ps'
check_not 'backward clock: never invokes Engram lifecycle or Pi setup' grep -qE '^engram (restart|stop|run|start|setup)( |$)' "$STUB_LOG"
rm -f "$STUBS/date" "$SANDBOX/engram-backup-clock" "$SANDBOX/fail-engram-install"
rm -rf "$backups" "$HOME/.engram"

run_split --help
check 'help describes Engram memory backups' grep -qF 'engram-backups' <<<"$OUT"
check 'help documents the Engram export timeout' grep -qF 'GENTLE_UPDATE_ENGRAM_EXPORT_TIMEOUT' <<<"$OUT"
check 'help says the updater never restarts Engram' grep -qF 'never restarts Engram' <<<"$OUT"

if [ "${1:-}" = --v5-only ]; then
  printf '\n%d v5 assertion(s) failed\n' "$FAILS"
  [ "$FAILS" -eq 0 ]
  exit $?
fi

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
check "npm globals are updated package by package" logged "npm update -g --allow-scripts=$SCRIPT_ALLOWLIST @earendil-works/pi-coding-agent @openai/codex left-pad"
check "pnpm globals are updated by name without --latest" logged "pnpm update -g left-pad"
check "the Pi model catalog is refreshed" logged "pi update --models"
check "the Gentle Shell model catalog is refreshed" logged "gentle-shell --isolated update --models"
check "moshi-hook is updated" logged "moshi-hook update"
check "the Herdr Gentle Shell plugin is installed when missing" logged "herdr plugin install --yes jonasotoaguilar/herdr-gentle-shell/herdr-plugin"
check "an outdated Herdr integration is refreshed" logged "herdr integration install claude"
check_not "an up-to-date or missing Herdr integration is left alone" grep -qE "herdr integration install (codex|pi)" "$STUB_LOG"
check "every Herdr plugin is updated, not only ours" logged "herdr plugin update --yes"
check "Codex plugin marketplaces are refreshed" logged "codex plugin marketplace upgrade"
check "the Herdr sidebar is configured after the plugin step" logged "herdr plugin action invoke configure --plugin herdr-gentle-shell"
check "the Herdr extension is installed in the Gentle Shell home when missing" logged "gentle-shell --isolated install npm:herdr-gentle-shell"
check_eq "Pi hooks are installed in both Pi homes" "$PI_CODING_AGENT_DIR,$GENTLE_SHELL_HOME" "$(paste -sd, "$SANDBOX/moshi-pi-homes.log")"
check "hooks are reinstalled for the other ready agent" logged "moshi-hook install --target claude"
check "Codex gets its hooks even when doctor does not list it as ready" logged "moshi-hook install --target codex"
check_not "an agent that is neither ready nor always wired is left alone" logged "moshi-hook install --target opencode"
check_not "hooks are not installed for agents that had none" grep -q 'install --target opencode' "$STUB_LOG"
check_not "the Moshi daemon is left alone when the binary did not change" logged "moshi-hook service restart"
check_not "doctor is never run with --yes" grep -qE 'doctor.*--yes' "$STUB_LOG"
check_not "no .prev backup is written" test -e "$GENTLE_UPDATE_BIN_DIR/gentle-ai.prev"
check_not "runtimes stay out of 'all'" logged "mise upgrade --yes"
check_not "script authorization never changes npm config" grep -q '^npm config' "$STUB_LOG"
check_not "script authorization never writes a user npmrc" test -e "$HOME/.npmrc"
check_eq "only the global npm update receives the explicit script allowlist" "1" \
  "$(grep -cF -- "--allow-scripts=$SCRIPT_ALLOWLIST" "$STUB_LOG")"
check_not "scripts are never blanket-authorized" grep -qE -- '--allow-scripts=(all|true|\*)($| )' "$STUB_LOG"
for nested_install in 'pi update --all' 'gentle-shell --isolated setup' 'gentle-shell --isolated update --extensions'; do
  check "$nested_install runs without an inherited npm script policy" \
    grep -qxF "$nested_install|" "$SANDBOX/script-env.log"
done
check_eq "no command inherits npm script permission through the environment" "0" \
  "$(grep -cvE '\|$' "$SANDBOX/script-env.log")"

# Pi homes keep their script approvals in their own npm project.
reset
mkdir -p "$PI_CODING_AGENT_DIR/npm"
printf '%s\n' '{"name":"pi-home","allowScripts":{"protobufjs":false}}' > "$PI_CODING_AGENT_DIR/npm/package.json"
printf '%s\n' "allow-scripts=$SCRIPT_ALLOWLIST" > "$PI_CODING_AGENT_DIR/npm/.npmrc"
OUT="$(npm_config_allow_scripts=all "$APP/gentle-update" agents 2>&1 </dev/null)"; RC=$?
check_eq "a run with Pi npm projects exits 0" "0" "$RC"
check_eq "the Pi project approves the allowlisted packages" '{"gentle-pi":true,"@google/genai":true}' \
  "$(jq -c '.allowScripts | del(.protobufjs)' "$PI_CODING_AGENT_DIR/npm/package.json")"
check_eq "an explicit denial in the Pi project is kept" "false" \
  "$(jq -c '.allowScripts.protobufjs' "$PI_CODING_AGENT_DIR/npm/package.json")"
check "the original package.json is backed up" test -f "$PI_CODING_AGENT_DIR/npm/package.json.gentle-update.bak"
check_not "the obsolete .npmrc entry is removed" grep -qF allow-scripts "$PI_CODING_AGENT_DIR/npm/.npmrc"
check_not "an inherited npm script policy never reaches nested installers" grep -qE "^(pi update --all|gentle-shell --isolated (setup|update --extensions))\|all" "$SANDBOX/script-env.log"
check "an uninitialized Pi project is listed under Warnings" \
  grep -qF "npm project not initialized yet: $GENTLE_SHELL_HOME/npm" <<<"$(sed -n '/Warnings/,$p' <<<"$OUT")"

# A focused run exercises the script policy through the public update command.
if [ "${1:-}" = --scripts-only ]; then
  printf '\n%d script-policy case(s) failed\n' "$FAILS"
  [ "$FAILS" -eq 0 ]
  exit $?
fi

# --- toolchain channels ------------------------------------------------------

reset
run_update toolchain
check_eq "a clean toolchain run exits 0" "0" "$RC"
check "gentle-ai is built from its exact v5 release" logged "$AI_INSTALL"
check_not "gentle-ai is no longer built from main" grep -q 'gentle-ai@main' "$STUB_LOG"
check "engram is built from its latest release" logged "go install github.com/Gentleman-Programming/engram/v3/cmd/engram@latest"
check_eq "the toolchain builds exactly two Go binaries" "2" "$(grep -c '^go install ' "$STUB_LOG")"
check "installed assets are synced to the new gentle-ai" logged "gentle-ai sync"
check "the sync runs after the gentle-ai build" test "$(first_line_of '^go install .*gentle-ai@v5.0.0$')" -lt "$(first_line_of '^gentle-ai sync$')"

reset
rm -f "$STUBS/opencode"
run_update toolchain
check_eq "a sync that leaves out a missing agent exits 0" "0" "$RC"
check "an installed agent whose CLI is missing is left out of the sync" logged "gentle-ai sync --agents pi,claude-code,codex"
check "the agent left out is reported" grep -q "gentle-ai sync for opencode — 'opencode' is not on PATH" <<<"$OUT"

reset
touch "$GENTLE_UPDATE_STATE_DIR/holds/gentle-ai"
run_update toolchain
check_not "a held gentle-ai is neither rebuilt nor synced" grep -qE '^go install .*gentle-ai|^gentle-ai sync' "$STUB_LOG"

# --- Gentle Shell MCP servers ---------------------------------------------------

STD_MCP="$PI_CODING_AGENT_DIR/mcp.json"
GS_MCP="$GENTLE_SHELL_HOME/mcp.json"
rm -f "$STD_MCP" "$GS_MCP"
printf '%s\n' '{"mcpServers":{"codegraph":{"command":"codegraph","args":["serve","--mcp"]},"context7":{"command":"npx"}}}' > "$STD_MCP"

reset
run_update packages
check_not "packages alone leaves the Shell home untouched" test -e "$GS_MCP"
reset
run_update agents
check_eq "the Gentle Shell home receives the standard MCP servers" \
  "codegraph,context7" "$(jq -r '.mcpServers | keys | join(",")' "$GS_MCP")"
check "the added servers are named" grep -q 'added MCP server(s) to the Gentle Shell home: codegraph, context7' <<<"$OUT"
check_eq "a new MCP config is private" "600" "$(stat -c %a "$GS_MCP")"

reset
run_update agents
check_not "a second run adds nothing" grep -q 'added MCP server' <<<"$OUT"

# A server installed later is carried over; an entry already there is not touched.
printf '%s\n' '{"mcpServers":{"codegraph":{"command":"codegraph"},"later":{"command":"later-mcp"},"context7":{"command":"npx"}}}' > "$STD_MCP"
printf '%s\n' '{"mcpServers":{"codegraph":{"command":"my-codegraph"}},"other":1}' > "$GS_MCP"
reset
run_update agents
check_eq "a server installed later is carried over" "codegraph,context7,later" \
  "$(jq -r '.mcpServers | keys | join(",")' "$GS_MCP")"
check_eq "an existing Gentle Shell entry is kept" "my-codegraph" "$(jq -r '.mcpServers.codegraph.command' "$GS_MCP")"
check_eq "other keys in the Gentle Shell config are kept" "1" "$(jq -r '.other' "$GS_MCP")"

printf '%s\n' '{not json' > "$GS_MCP"
reset
run_update agents
check_eq "an invalid Gentle Shell MCP config is left untouched" '{not json' "$(cat "$GS_MCP")"
check "an invalid config is reported" grep -q 'is not valid JSON; left untouched' <<<"$OUT"

rm -f "$STD_MCP" "$GS_MCP"
reset
run_update agents
check_not "no standard MCP config creates none" test -e "$GS_MCP"

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
check_eq "without a restart doctor is not asked again" "2" "$(grep -cxF 'moshi-hook doctor --json' "$STUB_LOG")"

# A daemon that was just restarted needs a moment before doctor sees it whole.
printf '%s\n' "$DOCTOR_REGRESSED" > "$SANDBOX/doctor-warming.json"
reset
touch "$SANDBOX/moshi-new-build"
printf 'warming\n' > "$SANDBOX/doctor-warming"
GENTLE_UPDATE_MOSHI_READY_SECS=3 run_update packages
check_eq "a daemon still starting up does not fail the run" "0" "$RC"
check_not "a feature that came back is not reported" grep -q 'no longer ok' <<<"$OUT"
check_eq "doctor is asked again after the restart" "3" "$(grep -cxF 'moshi-hook doctor --json' "$STUB_LOG")"

reset
touch "$SANDBOX/moshi-new-build"
printf '%s\n' "$DOCTOR_REGRESSED" > "$SANDBOX/doctor-after.json"
GENTLE_UPDATE_MOSHI_READY_SECS=1 run_update packages
check_eq "a feature still down after the wait fails the run" "1" "$RC"
check "the feature still down after the wait is named" grep -q 'sessions' <<<"$OUT"

# --- holds -------------------------------------------------------------------

reset
touch "$GENTLE_UPDATE_STATE_DIR/holds/claude" "$GENTLE_UPDATE_STATE_DIR/holds/codex"
run_update all
check_eq "a run with holds exits 0" "0" "$RC"
check_not "a held component is not updated" logged "claude update"
check "a held component is listed under Skipped" grep -qF 'Claude Code — held by gentle-rollback (gentle-rollback unhold claude)' <<<"$(sed -n '/Skipped/,$p' <<<"$OUT")"
check "held npm packages are left out of the npm update" logged "npm update -g --allow-scripts=$SCRIPT_ALLOWLIST @earendil-works/pi-coding-agent left-pad"
check "other components still update" logged "pnpm update -g left-pad"
check_not "OpenCode is never touched" grep -qi opencode <(grep -v "gentle-ai sync" "$STUB_LOG")

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
check "a failing npm listing is listed under Errors" grep -q 'npm globals' <<<"$(sed -n '/Errors/,$p' <<<"$OUT")"
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

# --- run log -----------------------------------------------------------------

LOGS="$GENTLE_UPDATE_STATE_DIR/logs"
latest_log() { readlink -f "$LOGS/latest.log"; }

reset
rm -rf "$LOGS"
run_update all
check_eq "a logged clean run still exits 0" "0" "$RC"
check "a run writes a log" test -s "$(latest_log)"
check "the log holds the terminal output" grep -q 'Claude Code' "$(latest_log)"
check "the log records the command behind a step" grep -q "step 'Claude Code' (claude): claude update" "$(latest_log)"
check "the log records a step's exit status" grep -qE "step 'Claude Code' finished: exit 0 in [0-9]+s" "$(latest_log)"
check "the log records where each tool was found" grep -qF "claude -> $STUBS/claude" "$(latest_log)"
check "the log records how the run ended" grep -qE 'finished: exit 0 after [0-9]+s' "$(latest_log)"
check_not "the log holds no color codes" grep -q $'\033' "$(latest_log)"
check_not "a clean run does not print the log path" grep -q 'run log:' <<<"$OUT"
check_not "no trace is written unless asked for" test -e "$(latest_log | sed 's/\.log$/.trace/')"

reset
touch "$SANDBOX/fail-shell-upgrade"
run_update agents
check "a failing native upgrade still updates other tools" logged "claude update"
check_eq "a failed step still exits 1" "1" "$RC"
check "a failed step reports its exit status" grep -q 'update failed (exit 1)' <<<"$OUT"
check "a failed run prints the log path" grep -qF "run log: $(latest_log)" <<<"$OUT"
check "the log records the failed step" grep -qE "step 'Gentle Shell launcher \(stable v5\)' finished: exit 1" "$(latest_log)"
check "the log records the failed run" grep -qE 'finished: exit 1 after [0-9]+s' "$(latest_log)"

reset
touch "$SANDBOX/fail-mise-env"
run_update all
check "the log keeps a tool's error output" grep -q 'mise: config error' "$(latest_log)"

reset
touch "$SANDBOX/break-claude"
run_update agents
check "the log records why a broken tool does not answer" grep -q 'claude --version: exit 1' "$(latest_log)"

reset
rm -rf "$LOGS"
mkdir -p "$LOGS"
for n in $(seq 10 49); do : > "$LOGS/gentle-update-20200101-0000$n-1.log"; done
run_update plugins
check_eq "only the newest 30 logs are kept" "30" "$(find "$LOGS" -name 'gentle-update-*.log' | wc -l)"
check "the newest log survives the pruning" test -s "$(latest_log)"

reset
rm -rf "$LOGS"
OUT="$(GENTLE_UPDATE_NO_LOG=1 "$APP/gentle-update" plugins 2>&1 </dev/null)"
check_eq "GENTLE_UPDATE_NO_LOG=1 still exits 0" "0" "$?"
check_not "GENTLE_UPDATE_NO_LOG=1 writes no log" test -e "$LOGS"

reset
OUT="$(GENTLE_UPDATE_TRACE=1 "$APP/gentle-update" plugins 2>&1 </dev/null)"
check "GENTLE_UPDATE_TRACE=1 writes a trace next to the log" test -s "$(latest_log | sed 's/\.log$/.trace/')"
check_not "the trace stays out of the terminal output" grep -q '^+ ' <<<"$OUT"

# --- Herdr plugin and Codex marketplace paths ---------------------------------

reset
touch "$SANDBOX/herdr-has-plugin"
run_update agents
check_eq "an installed plugin run exits 0" "0" "$RC"
check_not "an installed plugin is not installed again" grep -q '^herdr plugin install' "$STUB_LOG"
check "an installed plugin still gets every plugin updated" logged "herdr plugin update --yes"
check "an installed plugin still gets the sidebar configured" logged "herdr plugin action invoke configure --plugin herdr-gentle-shell"

reset
touch "$SANDBOX/herdr-has-plugin" "$SANDBOX/fail-herdr-update"
run_update agents
check_eq "a failing plugin update exits 1" "1" "$RC"
check "a failing plugin update is reported" grep -q 'Herdr plugins' <<<"$(sed -n '/Errors/,$p' <<<"$OUT")"
check "a failing plugin update still configures the sidebar" logged "herdr plugin action invoke configure --plugin herdr-gentle-shell"

reset
touch "$SANDBOX/old-codex"
run_update agents
check_eq "a Codex without marketplace upgrade exits 0" "0" "$RC"
check_not "a Codex without marketplace upgrade is not asked to upgrade" logged "codex plugin marketplace upgrade"

printf '\n'
if [ "$FAILS" -gt 0 ]; then
  printf '%d case(s) failed\n' "$FAILS"
  exit 1
fi
printf 'all cases passed\n'
