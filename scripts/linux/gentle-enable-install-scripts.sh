#!/usr/bin/env bash
# One-time remediation of npm 11/12 blocked GLOBAL install scripts.
# Reviewed package/version/lifecycle pairs only; no global npm config changes.
# Usage: bash gentle-enable-install-scripts.sh [--dry-run] [--allow-llama-download]
# Does NOT edit gentle-update; newly released versions must be reviewed anew.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: bash gentle-enable-install-scripts.sh [--dry-run] [--allow-llama-download]
  --dry-run                Inspect installed versions and lifecycle manifests, do not execute.
  --allow-llama-download   Permit node-llama-cpp's normal native fallback/download behavior.
                           By default NODE_LLAMA_CPP_SKIP_DOWNLOAD=true for its rebuild.
No sudo, no global npmrc changes, no --dangerously-allow-all-scripts.
EOF
}

dry_run=0
llama_download=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --allow-llama-download) llama_download=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

for bin in node npm; do
  command -v "$bin" >/dev/null 2>&1 || { printf 'Missing command: %s\n' "$bin" >&2; exit 1; }
done
if [ "$(id -u)" -eq 0 ]; then
  echo 'Refusing to run as root. Use your normal developer account (no sudo).' >&2
  exit 1
fi

npm_major="$(npm --version | cut -d. -f1)"
if ! [[ "$npm_major" =~ ^[0-9]+$ ]] || (( npm_major < 11 )); then
  echo "Requires npm 11/12 script-approval policy (detected npm $(npm --version))." >&2
  exit 1
fi

# An inherited npm_config_allow_scripts can trigger EALLOWSCRIPTS in child npm installs.
unset npm_config_allow_scripts NPM_CONFIG_ALLOW_SCRIPTS
root="$(npm root -g)"
[ -d "$root" ] || { printf 'Global npm root does not exist: %s\n' "$root" >&2; exit 1; }

# All names and versions below are pinned to the 2026-10-13 run log.
# Manifest guard: reject any unexpected install-time lifecycle command.
# The runtime code inside these packages has not been formally audited.
report="$(node - "$root" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const expected = [
  ['tree-sitter-go', '0.25.0', {install: 'node-gyp-build'}],
  ['tree-sitter-javascript', '0.23.1', {install: 'node-gyp-build'}],
  ['tree-sitter-rust', '0.24.0', {install: 'node-gyp-build'}],
  ['tree-sitter-python', '0.25.0', {install: 'node-gyp-build'}],
  ['tree-sitter-typescript', '0.23.2', {install: 'node-gyp-build'}],
  // v3.20.0's published manifest retains the upstream Husky prepare hook.
  // It is disabled during rebuild via CI=true (only within llama's command).
  ['node-llama-cpp', '3.20.0', {
    postinstall: 'node ./dist/cli/cli.js postinstall',
    prepare: 'node --experimental-require-module -e "process.env.CI !== \'true\' && console.log(require(\'husky\').default())"'
  }],
  ['pnpm', '12.11.2', {preinstall: 'node install.js', postinstall: 'node install.js'}]
];
const targets = new Map(expected.map(x => [x[0], x]));
const found = new Map();
const pending = [root];
const visited = new Set();
let error = false;
const lifecycle = ['preinstall', 'install', 'postinstall', 'prepare'];

while (pending.length) {
  const nodeModules = pending.pop();
  let real;
  try { real = fs.realpathSync(nodeModules); } catch { continue; }
  if (visited.has(real)) continue;
  visited.add(real);
  let entries;
  try { entries = fs.readdirSync(nodeModules, {withFileTypes: true}); } catch { continue; }
  for (const entry of entries) {
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
    if (entry.name.startsWith('.') && !entry.name.startsWith('@')) continue;
    const base = path.join(nodeModules, entry.name);
    let packagePaths = [base];
    if (entry.name.startsWith('@')) {
      let scoped;
      try { scoped = fs.readdirSync(base, {withFileTypes: true}); } catch { continue; }
      packagePaths = scoped.filter(x => x.isDirectory() || x.isSymbolicLink()).map(x => path.join(base, x.name));
    }
    for (const packageDir of packagePaths) {
      const manifestPath = path.join(packageDir, 'package.json');
      let manifest;
      try { manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')); } catch { continue; }
      if (targets.has(manifest.name)) {
        const copies = found.get(manifest.name) || [];
        copies.push({dir: packageDir, manifest});
        found.set(manifest.name, copies);
      }
      pending.push(path.join(packageDir, 'node_modules'));
    }
  }
}

for (const [name, version, expectedScripts] of expected) {
  const copies = found.get(name) || [];
  if (!copies.length) {
    console.log(`MISSING\t${name}\t${version}\t-`);
    continue;
  }
  let valid = true;
  for (const {dir, manifest} of copies) {
    if (manifest.version !== version) {
      console.log(`REFUSE\t${name}\t${version}\tinstalled version ${manifest.version} at ${dir}`);
      valid = false;
      continue;
    }
    const actual = Object.fromEntries(lifecycle.filter(k => Object.hasOwn(manifest.scripts || {}, k)).map(k => [k, manifest.scripts[k]]));
    if (JSON.stringify(actual) !== JSON.stringify(expectedScripts)) {
      console.log(`REFUSE\t${name}\t${version}\tunexpected lifecycle scripts at ${dir}: ${JSON.stringify(actual)}`);
      valid = false;
      continue;
    }
  }
  if (valid) console.log(`OK\t${name}\t${version}\t${copies.length} installed copy/copies`);
  else error = true;
}
if (error) process.exitCode = 3;
NODE
)" || { printf '%s\n' "$report"; echo 'Manifest/version mismatch: no scripts executed.' >&2; exit 1; }

printf 'npm: %s\nGlobal root: %s\n\n' "$(npm --version)" "$root"
printf '%s\n' "$report" | while IFS=$'\t' read -r status name version detail; do
  printf '[%s] %-26s @ %-8s %s\n' "$status" "$name" "$version" "$detail"
done

if (( dry_run )); then
  echo -e '\nDry run: no lifecycle scripts executed.'
  exit 0
fi

# Share the updater's lock; fail rather than mutate while it is updating.
if ! command -v flock >/dev/null 2>&1; then
  echo 'Requires flock to coordinate with gentle-update.' >&2
  exit 1
fi
lock_dir="${GENTLE_UPDATE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gentle-update}"
mkdir -p "$lock_dir"
exec 8>"$lock_dir/lock"
if ! flock -n 8; then
  echo 'gentle-update, gentle-rollback or another repair is already running.' >&2
  exit 1
fi

ok=0
failed=0
skipped=0
while IFS=$'\t' read -r status name version detail; do
  if [[ "$status" == MISSING ]]; then
    ((skipped+=1))
    continue
  fi
  if [[ "$status" != OK ]]; then
    printf 'Refusing %s: %s\n' "$name" "$detail" >&2
    ((failed+=1))
    continue
  fi
  echo
  printf '%s\n' "── npm rebuild -g ${name}@${version} ──"
  # The option is command-local; no persistent approval of future versions.
  # npm rebuild executes the scripts of installed packages, without adding
  # formerly transitive packages as global top-level dependencies.
  if [[ "$name" == 'node-llama-cpp' && "$llama_download" -eq 0 ]]; then
    if CI=true HUSKY=0 NODE_LLAMA_CPP_SKIP_DOWNLOAD=true npm rebuild -g "${name}@${version}" --allow-scripts="$name" --foreground-scripts; then
      ((ok+=1))
    else
      ((failed+=1))
      echo "FAILED: $name" >&2
    fi
  else
    if [[ "$name" == 'node-llama-cpp' ]]; then
      # --allow-llama-download only lifts the download restriction; Husky stays off.
      if CI=true HUSKY=0 npm rebuild -g "${name}@${version}" --allow-scripts="$name" --foreground-scripts; then
        ((ok+=1))
      else
        ((failed+=1))
        echo "FAILED: $name" >&2
      fi
      continue
    fi
    if npm rebuild -g "${name}@${version}" --allow-scripts="$name" --foreground-scripts; then
      ((ok+=1))
    else
      ((failed+=1))
      echo "FAILED: $name" >&2
    fi
  fi
done <<< "$report"

echo
printf 'Rebuild summary: succeeded=%d skipped(not installed)=%d failed=%d\n' "$ok" "$skipped" "$failed"

if command -v pnpm >/dev/null 2>&1; then
  if ! pnpm --version; then
    echo 'WARNING: pnpm command failed after rebuild; check its npm/Corepack shim.' >&2
    ((failed+=1))
  fi
else
  echo 'WARNING: pnpm not found in PATH after rebuild.' >&2
  ((failed+=1))
fi
if command -v pnpx >/dev/null 2>&1; then
  if ! pnpx --version; then
    echo 'WARNING: pnpx failed after rebuild; check its npm/Corepack shim.' >&2
    ((failed+=1))
  fi
else
  echo 'WARNING: pnpx not found in PATH after rebuild.' >&2
  ((failed+=1))
fi

if (( failed > 0 )); then
  echo 'Some rebuilds or post-checks failed. Review their output; no blanket approvals were installed.' >&2
  exit 1
fi

echo 'Finished. Approval was limited to this execution.'
echo 'For future package upgrades, review new versions before rerunning rebuilds.'
