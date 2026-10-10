#!/usr/bin/env bash
# Sandboxed tests for gentle-rollback.
#
# Nothing real is read or written: HOME, the state directory, the bin
# directory, and both Pi homes live under one mktemp directory, and PATH holds
# only stub tools plus the system directories. The stubs log their arguments to
# $STUB_LOG and print canned version / JSON output, so a test can assert on the
# exact command a restore would have run.
#
# Usage: bash scripts/linux/tests/gentle-rollback.test.sh
# Prints one ok/FAIL line per case and exits non-zero when any case failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLBACK="$HERE/../gentle-rollback"

SANDBOX="$(mktemp -d)" || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

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
# check_eq <description> <expected> <actual>
check_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# --- sandbox -----------------------------------------------------------------

export HOME="$SANDBOX/home"
export SANDBOX
export STUB_LOG="$SANDBOX/stub.log"
export GENTLE_UPDATE_BIN_DIR="$SANDBOX/bin"
export GENTLE_UPDATE_STATE_DIR="$SANDBOX/state"
export GENTLE_UPDATE_KEEP_SNAPSHOTS=7
export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
export GENTLE_SHELL_HOME="$HOME/.gentle-shell/agent"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export PNPM_HOME="$SANDBOX/pnpm"
unset GENTLE_UPDATE_LOCK_HELD XDG_STATE_HOME

STUBS="$SANDBOX/stubs"
mkdir -p "$STUBS" "$GENTLE_UPDATE_BIN_DIR" "$SANDBOX/versions" "$PNPM_HOME/bin" \
  "$PI_CODING_AGENT_DIR/extensions/demo" "$PI_CODING_AGENT_DIR/npm" \
  "$GENTLE_SHELL_HOME/npm" "$CLAUDE_CONFIG_DIR/plugins" "$SANDBOX/plugin-cache/demo"
: > "$STUB_LOG"

# One stub body for every PATH tool; it behaves according to the name it was
# installed under.
cat > "$SANDBOX/stub" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "$STUB_LOG"
if [ "$name" = pnpm ]; then
  # Record what pnpm needs for global commands: PNPM_HOME and its bin
  # directory on PATH.
  case ":$PATH:" in
    *":${PNPM_HOME:-unset}/bin:"*) on_path=yes ;;
    *)                             on_path=no ;;
  esac
  printf 'pnpm-env home=%s bin-on-path=%s\n' "${PNPM_HOME:-unset}" "$on_path" >> "$STUB_LOG"
fi
case "$name $*" in
  "npm ls -g --depth=0 --json")  cat "$SANDBOX/npm-globals.json" ;;
  "npm install --global "*)      if [ -e "$SANDBOX/fail-npm-install" ]; then exit 1; fi ;;
  "pnpm ls -g --depth=0 --json") cat "$SANDBOX/pnpm-globals.json" ;;
  *" --version")                 cat "$SANDBOX/versions/$name" ;;
esac
EOF
for tool in npm pnpm claude opencode mise pi gentle-shell codex; do
  install -m 755 "$SANDBOX/stub" "$STUBS/$tool"
done
export PATH="$STUBS:/usr/bin:/bin"

echo "2026.10.2 linux-x64 (2026-10-04)" > "$SANDBOX/versions/mise"
echo "2.1.289 (Claude Code)"            > "$SANDBOX/versions/claude"
echo "1.18.34"                          > "$SANDBOX/versions/opencode"
echo "1.0.3"                            > "$SANDBOX/versions/pi"
echo "gentle-shell 4.0.0"               > "$SANDBOX/versions/gentle-shell"
echo "codex-cli 0.160.0"                > "$SANDBOX/versions/codex"

# write_npm_globals <left-pad version> <codex version> [gentle-pi version]
write_npm_globals() {
  cat > "$SANDBOX/npm-globals.json" <<EOF
{"name": "lib", "dependencies": {
  "@earendil-works/pi-coding-agent": {"version": "1.0.3"},
  "gentle-pi": {"version": "${3:-4.0.0}"},
  "@openai/codex": {"version": "$2"},
  "left-pad": {"version": "$1"}
}}
EOF
}
# write_pnpm_globals <@scope/tool version>
write_pnpm_globals() {
  cat > "$SANDBOX/pnpm-globals.json" <<EOF
[{"path": "$PNPM_HOME/global", "dependencies": {
  "@scope/tool": {"from": "@scope/tool", "version": "$1"}
}}]
EOF
}
write_npm_globals 1.0.0 0.160.0
write_pnpm_globals 0.15.1

# Fake "binaries": small scripts whose bytes change with the build number.
# write_binary <name> <build>
write_binary() {
  cat > "$GENTLE_UPDATE_BIN_DIR/$1" <<EOF
#!/usr/bin/env bash
# fake $1 build $2
if [ "\${1:-}" = --version ]; then echo "$1 $2.0.0"; exit 0; fi
printf '%s %s\n' "$1" "\$*" >> "\$STUB_LOG"
if [ "\${1:-}" = install ]; then printf 'install-home %s\n' "\${PI_CODING_AGENT_DIR:-}" >> "\$STUB_LOG"; fi
EOF
  chmod 755 "$GENTLE_UPDATE_BIN_DIR/$1"
}
for tool in gentle-ai engram herdr moshi-hook; do write_binary "$tool" 1; done

for home in "$PI_CODING_AGENT_DIR" "$GENTLE_SHELL_HOME"; do
  echo '{"packages": ["npm:demo@1.0.0"]}' > "$home/settings.json"
  echo '{"secret": "never snapshot me"}' > "$home/auth.json"
  echo '{"name": "pi-extensions"}'        > "$home/npm/package.json"
  echo '{"lockfileVersion": 3}'           > "$home/npm/package-lock.json"
done
echo 'export default 1' > "$PI_CODING_AGENT_DIR/extensions/demo/index.ts"
echo '{"secret": "nested"}' > "$PI_CODING_AGENT_DIR/extensions/demo/auth.json"

PLUGINS="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
cat > "$PLUGINS" <<EOF
{"version": 2, "plugins": {"demo@demo": [{"installPath": "$SANDBOX/plugin-cache/demo", "version": "0.1.0"}]}}
EOF

rb() { "$ROLLBACK" "$@"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
snapshot_count() { find "$GENTLE_UPDATE_STATE_DIR/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; }
blob_count() { find "$GENTLE_UPDATE_STATE_DIR/store" -type f 2>/dev/null | wc -l; }
# Start the next group of cases from an empty state directory.
fresh_state() {
  GENTLE_UPDATE_STATE_DIR="$SANDBOX/state-$1"
  : > "$STUB_LOG"
}

# --- version-number helper ---------------------------------------------------

check_eq "version-number: claude"     "2.1.289"      "$(rb version-number '2.1.289 (Claude Code)' 2>/dev/null)"
check_eq "version-number: mise"       "2026.10.2"    "$(rb version-number '2026.10.2 linux-x64 (2026-10-04)' 2>/dev/null)"
check_eq "version-number: opencode"   "1.18.34"      "$(rb version-number '1.18.34' 2>/dev/null)"
check_eq "version-number: prefixed"   "0.160.0"      "$(rb version-number 'codex-cli 0.160.0' 2>/dev/null)"
check_eq "version-number: prerelease" "1.2.3-beta.1" "$(rb version-number 'v1.2.3-beta.1' 2>/dev/null)"
check_not "version-number: no version exits non-zero" rb version-number 'unknown'

# --- snapshot ----------------------------------------------------------------

ID1="$(rb snapshot --reason first 2>/dev/null)"
SNAP1="$GENTLE_UPDATE_STATE_DIR/snapshots/$ID1"
check "snapshot prints an id naming a directory" test -n "$ID1" -a -d "$SNAP1"
check_eq "snapshot directory is private (700)" "700" "$(stat -c %a "$SNAP1" 2>/dev/null)"
check_eq "snapshot records its reason" "first" "$(cat "$SNAP1/reason" 2>/dev/null)"
check "versions.tsv records the claude version" grep -qP '^claude\t2\.1\.289 \(Claude Code\)$' "$SNAP1/versions.tsv"
check "versions.tsv records a BIN_DIR tool" grep -qP '^herdr\therdr 1\.0\.0$' "$SNAP1/versions.tsv"
check_eq "binaries.tsv lists the four binaries" "4" "$(wc -l < "$SNAP1/binaries.tsv" 2>/dev/null)"
check "store holds the herdr blob" cmp -s "$GENTLE_UPDATE_BIN_DIR/herdr" "$GENTLE_UPDATE_STATE_DIR/store/$(sha "$GENTLE_UPDATE_BIN_DIR/herdr")"
check "npm-globals.json is saved" jq -e '.dependencies["left-pad"].version == "1.0.0"' "$SNAP1/npm-globals.json"
check "pnpm-globals.json is saved" jq -e '.[0].dependencies["@scope/tool"].version == "0.15.1"' "$SNAP1/pnpm-globals.json"
check "pnpm globals are listed" grep -qx 'pnpm ls -g --depth=0 --json' "$STUB_LOG"
check "pnpm ran with PNPM_HOME set and its global bin dir on PATH" grep -qxF "pnpm-env home=$PNPM_HOME bin-on-path=yes" "$STUB_LOG"
check "pi home settings.json is saved" cmp -s "$PI_CODING_AGENT_DIR/settings.json" "$SNAP1/homes/pi/settings.json"
check "pi home extensions are saved" test -f "$SNAP1/homes/pi/extensions/demo/index.ts"
check "gentle-shell home lockfile is saved" test -f "$SNAP1/homes/gentle-shell/npm/package-lock.json"
check "claude plugins file is saved" cmp -s "$PLUGINS" "$SNAP1/claude-plugins/installed_plugins.json"
check_eq "no auth.json is ever copied" "" "$(find "$GENTLE_UPDATE_STATE_DIR" -name auth.json 2>/dev/null)"

ID2="$(rb snapshot 2>/dev/null)"
check "a second snapshot in the same second gets its own id" test -n "$ID2" -a "$ID2" != "$ID1"
check_eq "default reason is manual" "manual" "$(cat "$GENTLE_UPDATE_STATE_DIR/snapshots/$ID2/reason" 2>/dev/null)"
check_eq "identical binaries share one blob" "4" "$(blob_count)"

SHOW="$(rb show latest 2>&1)"
check_eq "show lists every component" "13" "$(printf '%s\n' "$SHOW" | grep -cE '^  (gentle-ai|engram|herdr|moshi-hook|mise|claude|opencode|pi|gentle-shell|codex|npm-globals|pnpm-globals|claude-plugins) ')"
check_not "show reports no difference right after a snapshot" grep -q 'differs' <<<"$SHOW"
check "list shows the snapshot with nothing differing" grep -qE "^$ID1 +first +0 differ" <<<"$(rb list 2>&1)"

rb show no-such-snapshot >/dev/null 2>&1
check_eq "unknown snapshot id exits 2" "2" "$?"
rb hold no-such-component >/dev/null 2>&1
check_eq "unknown component exits 2" "2" "$?"

# --- restore a binary --------------------------------------------------------

fresh_state binary
ORIGINAL="$(sha "$GENTLE_UPDATE_BIN_DIR/herdr")"
IDB="$(rb snapshot --reason before 2>/dev/null)"
write_binary herdr 2
write_binary engram 2
BROKEN="$(sha "$GENTLE_UPDATE_BIN_DIR/herdr")"

check "show marks the replaced binary" grep -qE '^  herdr .*differs' <<<"$(rb show "$IDB" 2>&1)"
check "list counts the differing components" grep -qE "^$IDB +before +2 differ" <<<"$(rb list 2>&1)"

rb restore latest --only herdr --dry-run >/dev/null 2>&1
check_eq "--dry-run exits 0" "0" "$?"
check_eq "--dry-run leaves the binary alone" "$BROKEN" "$(sha "$GENTLE_UPDATE_BIN_DIR/herdr")"
check_eq "--dry-run takes no snapshot" "1" "$(snapshot_count)"
check_not "--dry-run creates no hold" test -e "$GENTLE_UPDATE_STATE_DIR/holds/herdr"

rb restore latest --only herdr </dev/null >/dev/null 2>&1
check_eq "restore without --yes and without a TTY exits 1" "1" "$?"
check_eq "refused restore leaves the binary alone" "$BROKEN" "$(sha "$GENTLE_UPDATE_BIN_DIR/herdr")"

rb restore latest --only herdr --yes >/dev/null 2>&1
check_eq "restore exits 0" "0" "$?"
check_eq "restore brings back the exact bytes" "$ORIGINAL" "$(sha "$GENTLE_UPDATE_BIN_DIR/herdr")"
check_eq "restored binary is executable (755)" "755" "$(stat -c %a "$GENTLE_UPDATE_BIN_DIR/herdr")"
check "restore creates the hold" grep -q "rolled back to $IDB" "$GENTLE_UPDATE_STATE_DIR/holds/herdr"
check_eq "--only leaves other components alone" "engram 2.0.0" "$("$GENTLE_UPDATE_BIN_DIR/engram" --version)"
check_not "--only holds nothing else" test -e "$GENTLE_UPDATE_STATE_DIR/holds/engram"
check_eq "restore takes a pre-rollback snapshot" "2" "$(snapshot_count)"
check "pre-rollback snapshot names the restored id" grep -rqx "pre-rollback of $IDB" "$GENTLE_UPDATE_STATE_DIR/snapshots" --include=reason
check "pre-rollback snapshot kept the replaced binary" test -f "$GENTLE_UPDATE_STATE_DIR/store/$BROKEN"

check "holds lists the held component" grep -q '^herdr' <<<"$(rb holds 2>&1)"
rb unhold herdr >/dev/null 2>&1
check_not "unhold removes the hold" test -e "$GENTLE_UPDATE_STATE_DIR/holds/herdr"
rb hold claude "bad release" >/dev/null 2>&1
rb hold codex >/dev/null 2>&1
check "hold records the reason" grep -q 'bad release' "$GENTLE_UPDATE_STATE_DIR/holds/claude"
rb unhold all >/dev/null 2>&1
check_eq "unhold all removes every hold" "0" "$(find "$GENTLE_UPDATE_STATE_DIR/holds" -type f 2>/dev/null | wc -l)"

rb restore "$IDB" --only engram --yes >/dev/null 2>&1
check_eq "nothing left to restore exits 3, distinct from restored" "3" "$(rb restore "$IDB" --yes >/dev/null 2>&1; echo $?)"

# An empty --only (for example from an unset variable) must not mean "all".
write_binary herdr 2
rb restore "$IDB" --only "" --yes >/dev/null 2>&1
check_eq "an empty --only exits 2" "2" "$?"
check_eq "an empty --only restores nothing" "herdr 2.0.0" "$("$GENTLE_UPDATE_BIN_DIR/herdr" --version)"
write_binary herdr 1

# moshi-hook: binary, then hooks for every Pi home, then the daemon.
# Only the standard Pi home has Moshi hooks; the Gentle Shell home exists but
# never had them, and a restore must not wire Moshi into it.
fresh_state moshi
echo 'moshi hooks' > "$PI_CODING_AGENT_DIR/extensions/moshi-hooks.ts"
rb snapshot >/dev/null 2>&1
write_binary moshi-hook 2
rb restore latest --only moshi-hook --yes >/dev/null 2>&1
check_eq "moshi-hook restore reinstalls Pi hooks once" "1" "$(grep -cx 'moshi-hook install --target pi' "$STUB_LOG")"
check "the Pi hook goes into the home whose snapshot had it" grep -qxF "install-home $PI_CODING_AGENT_DIR" "$STUB_LOG"
check_not "the Pi hook is not installed into a home that never had it" grep -qxF "install-home $GENTLE_SHELL_HOME" "$STUB_LOG"
check "moshi-hook restore restarts the daemon" grep -qx 'moshi-hook service restart' "$STUB_LOG"
write_binary moshi-hook 1

# A busy lock means an update or another rollback is running.
(
  exec 8>"$GENTLE_UPDATE_STATE_DIR/lock"
  flock -n 8
  rb restore latest --yes >/dev/null 2>&1
)
check_eq "restore refuses while the lock is held" "1" "$?"

# --- version-pinned tools and package managers -------------------------------

fresh_state packages
IDP="$(rb snapshot 2>/dev/null)"
echo "2.2.0 (Claude Code)" > "$SANDBOX/versions/claude"
echo "2026.11.0 linux-x64 (2026-11-01)" > "$SANDBOX/versions/mise"
echo "1.19.0" > "$SANDBOX/versions/opencode"
write_npm_globals 2.0.0 0.161.0
write_pnpm_globals 0.16.0
: > "$STUB_LOG"

rb restore latest --only npm-globals --yes >/dev/null 2>&1
check "changed npm global is reinstalled at the snapshot version" grep -qx 'npm install --global left-pad@1.0.0' "$STUB_LOG"
check_not "--only npm-globals leaves codex alone" grep -q '@openai/codex' "$STUB_LOG"

# `latest` is now the pre-rollback snapshot of the restore above, which holds
# the changed versions; name the original snapshot instead.
rb restore "$IDP" --only codex,pnpm-globals,claude,mise,opencode --yes >/dev/null 2>&1
check "codex is reinstalled at the snapshot version" grep -qx 'npm install --global @openai/codex@0.160.0' "$STUB_LOG"
check "changed pnpm global is re-added at the snapshot version" grep -qx 'pnpm add --global @scope/tool@0.15.1' "$STUB_LOG"
check "claude is reinstalled at the snapshot version" grep -qx 'claude install 2.1.289' "$STUB_LOG"
check "mise is pinned back to the snapshot version" grep -qx 'mise self-update --yes 2026.10.2' "$STUB_LOG"
check "opencode is moved back to the snapshot version" grep -qx 'opencode upgrade 1.18.34' "$STUB_LOG"

echo "2.1.289 (Claude Code)" > "$SANDBOX/versions/claude"
echo "2026.10.2 linux-x64 (2026-10-04)" > "$SANDBOX/versions/mise"
echo "1.18.34" > "$SANDBOX/versions/opencode"
write_npm_globals 1.0.0 0.160.0
write_pnpm_globals 0.15.1

# --- Pi home files -----------------------------------------------------------

fresh_state homes
rb snapshot >/dev/null 2>&1
echo '{"packages": ["npm:demo@2.0.0"]}' > "$PI_CODING_AGENT_DIR/settings.json"
echo '{"lockfileVersion": 3, "changed": true}' > "$PI_CODING_AGENT_DIR/npm/package-lock.json"
echo 'added after the snapshot' > "$PI_CODING_AGENT_DIR/extensions/demo/new.ts"
echo '{"secret": "rotated"}' > "$PI_CODING_AGENT_DIR/auth.json"

check "show marks the pi home as differing" grep -qE '^  pi .*differs' <<<"$(rb show latest 2>&1)"
check_not "an untouched home does not differ" grep -qE '^  gentle-shell .*differs' <<<"$(rb show latest 2>&1)"

rb restore latest --only pi --yes >/dev/null 2>&1
check_eq "home restore brings back settings.json" '{"packages": ["npm:demo@1.0.0"]}' "$(cat "$PI_CODING_AGENT_DIR/settings.json")"
check "home restore keeps files added after the snapshot" test -f "$PI_CODING_AGENT_DIR/extensions/demo/new.ts"
check_eq "home restore never touches auth.json" '{"secret": "rotated"}' "$(cat "$PI_CODING_AGENT_DIR/auth.json")"
check "restored lockfile triggers npm ci in the home" grep -qx "npm ci --prefix $PI_CODING_AGENT_DIR/npm" "$STUB_LOG"
check_eq "no auth.json in any snapshot" "" "$(find "$SANDBOX"/state* -name auth.json 2>/dev/null)"
check_not "restored home no longer differs" grep -qE '^  pi .*differs' <<<"$(rb show "$(rb list 2>/dev/null | tail -1 | cut -d' ' -f1)" 2>&1)"

# --- Gentle Shell launcher commit --------------------------------------------

# gentle-update installs the launcher from a main commit and records it in the
# state directory; npm reports the same version for every commit.
SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"
INSTALL_BY_COMMIT="npm install --global --allow-git=all github:Gentleman-Programming/gentle-shell#"
commit_file() { printf '%s\n' "$GENTLE_UPDATE_STATE_DIR/gentle-shell.commit"; }

fresh_state shell-commit
mkdir -p "$GENTLE_UPDATE_STATE_DIR"
echo "$SHA_A" > "$(commit_file)"
IDC="$(rb snapshot --reason commit-a 2>/dev/null)"
SNAPC="$GENTLE_UPDATE_STATE_DIR/snapshots/$IDC"
check_eq "the snapshot records the launcher commit" "$SHA_A" "$(cat "$SNAPC/gentle-shell.commit" 2>/dev/null)"
SHOW="$(rb show "$IDC" 2>&1)"
check "show prints the short commit of an unchanged launcher" grep -qE "^  gentle-shell +same .*${SHA_A:0:12}" <<<"$SHOW"
check_not "show never prints the full commit" grep -qF "$SHA_A" <<<"$SHOW"

echo "$SHA_B" > "$(commit_file)"
SHOW="$(rb show "$IDC" 2>&1)"
check "a different commit differs even at the same npm version" grep -qE '^  gentle-shell .*differs' <<<"$SHOW"
check "the difference names both short commits" grep -qE "gentle-pi 4\.0\.0 \(commit ${SHA_B:0:12}\) -> 4\.0\.0 \(commit ${SHA_A:0:12}\)" <<<"$SHOW"
check "list counts the launcher commit as a difference" grep -qE "^$IDC +commit-a +1 differ" <<<"$(rb list 2>&1)"

: > "$STUB_LOG"
OUT="$(rb restore "$IDC" --only gentle-shell --dry-run 2>&1)"
check_eq "--dry-run of a commit restore exits 0" "0" "$?"
check "--dry-run prints the install by commit" grep -qF "$INSTALL_BY_COMMIT$SHA_A" <<<"$OUT"
check "--dry-run prints that the commit would be recorded" grep -qE "would record:.* commit $SHA_A in $(commit_file)" <<<"$OUT"
check_not "--dry-run runs no npm install" grep -q '^npm install' "$STUB_LOG"
check_eq "--dry-run leaves the recorded commit alone" "$SHA_B" "$(cat "$(commit_file)")"
check_eq "--dry-run of a commit restore takes no snapshot" "1" "$(snapshot_count)"
check_not "--dry-run of a commit restore creates no hold" test -e "$GENTLE_UPDATE_STATE_DIR/holds/gentle-shell"

touch "$SANDBOX/fail-npm-install"
rb restore "$IDC" --only gentle-shell --yes >/dev/null 2>&1
check_eq "a failing launcher reinstall fails the restore" "1" "$?"
check_eq "a failing launcher reinstall keeps the recorded commit" "$SHA_B" "$(cat "$(commit_file)")"
check_not "a failing launcher reinstall is not held" test -e "$GENTLE_UPDATE_STATE_DIR/holds/gentle-shell"
rm -f "$SANDBOX/fail-npm-install"

: > "$STUB_LOG"
rb restore "$IDC" --only gentle-shell --yes >/dev/null 2>&1
check_eq "a commit restore exits 0" "0" "$?"
check "the launcher is reinstalled at the snapshot commit" grep -qxF "$INSTALL_BY_COMMIT$SHA_A" "$STUB_LOG"
check_not "a commit restore does not install the registry release" grep -q 'gentle-pi@' "$STUB_LOG"
check_not "an unchanged home needs no npm ci" grep -q '^npm ci' "$STUB_LOG"
check_eq "the restored commit is recorded" "$SHA_A" "$(cat "$(commit_file)")"
check "a commit restore holds gentle-shell" test -e "$GENTLE_UPDATE_STATE_DIR/holds/gentle-shell"
check "the pre-rollback snapshot kept the replaced commit" grep -rqxF "$SHA_B" "$GENTLE_UPDATE_STATE_DIR/snapshots" --include=gentle-shell.commit
rb restore "$IDC" --only gentle-shell --yes >/dev/null 2>&1
check_eq "a restored commit no longer differs (exit 3)" "3" "$?"

# A snapshot without a commit (taken before the launcher followed main, or
# before its first install from git) restores through the registry version.
fresh_state shell-registry
IDO="$(rb snapshot --reason registry 2>/dev/null)"
check_not "a snapshot without a recorded commit stores none" test -e "$GENTLE_UPDATE_STATE_DIR/snapshots/$IDO/gentle-shell.commit"
check_not "a snapshot without a commit prints none" grep -qE '^  gentle-shell .*commit' <<<"$(rb show "$IDO" 2>&1)"
echo "$SHA_B" > "$(commit_file)"
check "a commit installed after a registry snapshot differs" grep -qE "^  gentle-shell .*differs.* gentle-pi 4\.0\.0 \(commit ${SHA_B:0:12}\) -> 4\.0\.0\$" <<<"$(rb show "$IDO" 2>&1)"

: > "$STUB_LOG"
OUT="$(rb restore "$IDO" --only gentle-shell --dry-run 2>&1)"
check "--dry-run prints the registry install" grep -qF 'npm install --global gentle-pi@4.0.0' <<<"$OUT"
check_not "--dry-run of a registry restore runs no npm install" grep -q '^npm install' "$STUB_LOG"
check_eq "--dry-run of a registry restore keeps the recorded commit" "$SHA_B" "$(cat "$(commit_file)")"

rb restore "$IDO" --only gentle-shell --yes >/dev/null 2>&1
check_eq "a registry restore exits 0" "0" "$?"
check "the launcher is reinstalled at the snapshot registry version" grep -qx 'npm install --global gentle-pi@4.0.0' "$STUB_LOG"
check_not "a registry restore does not install from git" grep -q -- '--allow-git' "$STUB_LOG"
check_not "a registry restore removes the recorded commit" test -e "$(commit_file)"

# No commit on either side: only the npm version can differ, as before.
fresh_state shell-version
IDV="$(rb snapshot 2>/dev/null)"
write_npm_globals 1.0.0 0.160.0 4.1.0
: > "$STUB_LOG"
check "a moved registry version differs" grep -qE '^  gentle-shell .*differs.* gentle-pi 4\.1\.0 -> 4\.0\.0$' <<<"$(rb show "$IDV" 2>&1)"
rb restore "$IDV" --only gentle-shell --yes >/dev/null 2>&1
check "a moved registry version is reinstalled at the snapshot version" grep -qx 'npm install --global gentle-pi@4.0.0' "$STUB_LOG"
check_not "a version restore records no commit" test -e "$(commit_file)"
write_npm_globals 1.0.0 0.160.0

# Only a full commit id is worth recording.
fresh_state shell-garbage
mkdir -p "$GENTLE_UPDATE_STATE_DIR"
echo "not-a-commit" > "$(commit_file)"
IDG="$(rb snapshot 2>/dev/null)"
check_not "a malformed commit file is not copied into the snapshot" test -e "$GENTLE_UPDATE_STATE_DIR/snapshots/$IDG/gentle-shell.commit"
check_not "a malformed commit file does not count as a difference" grep -qE '^  gentle-shell .*differs' <<<"$(rb show "$IDG" 2>&1)"

# --- Claude plugins ----------------------------------------------------------

fresh_state plugins
rb snapshot >/dev/null 2>&1
SAVED_PLUGINS="$(cat "$PLUGINS")"
echo '{"version": 2, "plugins": {}}' > "$PLUGINS"
rb restore latest --only claude-plugins --yes >/dev/null 2>&1
check_eq "plugins file is restored while its install paths exist" "$SAVED_PLUGINS" "$(cat "$PLUGINS")"

rb unhold claude-plugins >/dev/null 2>&1
echo '{"version": 2, "plugins": {}}' > "$PLUGINS"
mv "$SANDBOX/plugin-cache/demo" "$SANDBOX/plugin-cache/gone"
OUT="$(rb restore "$(rb list 2>/dev/null | tail -1 | cut -d' ' -f1)" --only claude-plugins --yes 2>&1)"
check_eq "plugins restore fails when an install path is gone" "1" "$?"
check "the missing install path is named" grep -q "plugin-cache/demo" <<<"$OUT"
check_eq "plugins file is left alone on failure" '{"version": 2, "plugins": {}}' "$(cat "$PLUGINS")"
check_not "a failed component is not held" test -e "$GENTLE_UPDATE_STATE_DIR/holds/claude-plugins"
mv "$SANDBOX/plugin-cache/gone" "$SANDBOX/plugin-cache/demo"
printf '%s\n' "$SAVED_PLUGINS" > "$PLUGINS"

# --- retention ---------------------------------------------------------------

fresh_state retention
export GENTLE_UPDATE_KEEP_SNAPSHOTS=2
rb snapshot >/dev/null 2>&1
FIRST_ONLY="$(sha "$GENTLE_UPDATE_BIN_DIR/gentle-ai")"
write_binary gentle-ai 2
rb snapshot >/dev/null 2>&1
check "blob of the first snapshot exists while it is retained" test -f "$GENTLE_UPDATE_STATE_DIR/store/$FIRST_ONLY"
rb snapshot >/dev/null 2>&1
check_eq "retention keeps only the newest snapshots" "2" "$(snapshot_count)"
check_not "retention removes unreferenced blobs" test -e "$GENTLE_UPDATE_STATE_DIR/store/$FIRST_ONLY"
check_eq "retention keeps referenced blobs" "4" "$(blob_count)"

# The pre-rollback snapshot pushes the count over the limit; the snapshot being
# restored is the oldest one and must survive long enough to be used.
OLDEST="$(rb list 2>/dev/null | tail -1 | cut -d' ' -f1)"
WANTED="$(sha "$GENTLE_UPDATE_BIN_DIR/gentle-ai")"
write_binary gentle-ai 3
rb restore "$OLDEST" --only gentle-ai --yes >/dev/null 2>&1
check_eq "retention never prunes the snapshot being restored" "$WANTED" "$(sha "$GENTLE_UPDATE_BIN_DIR/gentle-ai")"

# --- retention value ---------------------------------------------------------

for bad in 0 abc ""; do
  fresh_state "keep-${bad:-empty}"
  export GENTLE_UPDATE_KEEP_SNAPSHOTS="$bad"
  ERR="$(rb snapshot 2>&1 >"$SANDBOX/keep-id")"
  IDK="$(cat "$SANDBOX/keep-id")"
  check "KEEP='$bad' keeps the snapshot it just created" test -n "$IDK" -a -d "$GENTLE_UPDATE_STATE_DIR/snapshots/$IDK"
  check "KEEP='$bad' warns and falls back to 7" grep -q 'GENTLE_UPDATE_KEEP_SNAPSHOTS' <<<"$ERR"
done
export GENTLE_UPDATE_KEEP_SNAPSHOTS=7

# --- pruning fails closed ----------------------------------------------------

# A broken ripgrep must not turn "cannot tell" into "unreferenced".
fresh_state no-rg
printf '#!/usr/bin/env bash\nexit 127\n' > "$STUBS/rg"
chmod 755 "$STUBS/rg"
IDR="$(rb snapshot 2>/dev/null)"
check_eq "a broken rg does not wipe the store" "4" "$(blob_count)"
check "the snapshot still succeeds without rg" test -n "$IDR"
rm -f "$STUBS/rg"

# A snapshot whose binaries.tsv is gone makes the reference set unknowable.
fresh_state corrupt
rb snapshot >/dev/null 2>&1
mkdir -p "$GENTLE_UPDATE_STATE_DIR/snapshots/20000101-000000"
OUT="$(rb snapshot 2>/dev/null)"
check_eq "snapshot fails when the referenced blobs cannot be determined" "1" "$?"
check_eq "a failed snapshot prints no id" "" "$OUT"
check_eq "no blob is deleted when pruning fails" "4" "$(blob_count)"

# --- dependency preflight ----------------------------------------------------

# A PATH with every system tool except the one under test.
SYS="$SANDBOX/sys"
mkdir -p "$SYS"
ln -s /usr/bin/* "$SYS/" 2>/dev/null
for missing in jq flock sha256sum timeout; do
  fresh_state "missing-$missing"
  mv "$SYS/$missing" "$SANDBOX/hidden-tool"
  ERR="$(PATH="$STUBS:$SYS" "$ROLLBACK" snapshot 2>&1 >/dev/null)"
  check_eq "missing $missing exits 1" "1" "$?"
  check "missing $missing is named" grep -qw -- "$missing" <<<"$ERR"
  check_eq "missing $missing creates no snapshot" "0" "$(snapshot_count)"
  mv "$SANDBOX/hidden-tool" "$SYS/$missing"
done

printf '\n'
if [ "$FAILS" -gt 0 ]; then
  printf '%d case(s) failed\n' "$FAILS"
  exit 1
fi
printf 'all cases passed\n'
