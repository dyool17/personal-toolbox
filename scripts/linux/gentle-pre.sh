#!/usr/bin/env bash
# gentle-pre.sh — one-time repair for npm 12 / Pi / Gentle Shell state.
# Run as your normal Linux user BEFORE installing/running the revised gentle-update.
# Safe to re-run: RDD agents are backed up/removed at most once.
set -euo pipefail
umask 077

STATE="${GENTLE_UPDATE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gentle-update}"
ALLOW="gentle-pi,@google/genai,protobufjs"
DONE="$STATE/preflight-rdd-v1.done"
STAMP="$(date '+%Y%m%d-%H%M%S')-$$"
BACKUP="$STATE/preflight-backups/$STAMP"

say() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "${EUID:-$(id -u)}" -ne 0 ] || fail 'run as the normal user, never sudo/root'
for cmd in npm sha256sum mktemp sed grep cp mv; do
  command -v "$cmd" >/dev/null 2>&1 || fail "missing required command: $cmd"
done
mkdir -p "$STATE"
chmod 700 "$STATE"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
say '[1/3] Back up and remove user-wide allow-scripts policy (if present)'

# A user .npmrc allowance is not needed by this updater. npm 12 can forward
# that policy into a child project-scoped install and raise EALLOWSCRIPTS.
userconfig="$(env -u npm_config_allow_scripts -u NPM_CONFIG_ALLOW_SCRIPTS npm config get userconfig)"
if [ -f "$userconfig" ] && grep -Eq '^[[:space:]]*allow-scripts[[:space:]]*=' "$userconfig"; then
  cp -p "$userconfig" "$BACKUP/npmrc-user.before"
  env -u npm_config_allow_scripts -u NPM_CONFIG_ALLOW_SCRIPTS \
    npm config delete allow-scripts --location=user
  if [ -f "$userconfig" ] && grep -Eq '^[[:space:]]*allow-scripts[[:space:]]*=' "$userconfig"; then
    fail "npm did not remove allow-scripts from $userconfig (backup: $BACKUP/npmrc-user.before)"
  fi
  say "  removed user-level allow-scripts (backup: $BACKUP/npmrc-user.before)"
else
  say '  no persistent user-wide allow-scripts override found'
fi

# Add the documented project policy for Pi's own npm --prefix installs.
# The updated gentle-update will maintain these settings on future runs.
configure_home() {
  local home="$1" label="$2" dir="$1/npm" file="$1/npm/.npmrc" tmp current="" combined value
  local -a items=()
  local -A seen=()
  mkdir -p "$dir"
  [ ! -L "$file" ] || fail "refusing symlinked project config: $file"
  if [ -f "$file" ]; then
    current="$(sed -nE 's/^[[:space:]]*allow-scripts[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$file" | tr '\n' ',')"
  fi
  while IFS= read -r value; do
    value="$(printf '%s' "$value" | xargs)"
    [ -n "$value" ] || continue
    if [ -z "${seen[$value]+present}" ]; then
      seen[$value]=1
      items+=("$value")
    fi
  done < <(printf '%s,%s\n' "$current" "$ALLOW" | tr ',' '\n')
  combined="$(IFS=,; printf '%s' "${items[*]}")"
  if [ -f "$file" ] && [ "$(grep -Ec '^[[:space:]]*allow-scripts[[:space:]]*=' "$file" || true)" = 1 ] && \
      grep -Fqx "allow-scripts=$combined" "$file"; then
    say "  already configured: $file"
    return
  fi
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  if [ -f "$file" ]; then
    cp -p "$file" "$BACKUP/${label}-npmrc.before"
    sed -E '/^[[:space:]]*allow-scripts[[:space:]]*=/d' "$file" > "$tmp"
  fi
  printf '\nallow-scripts=%s\n' "$combined" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
  say "  configured: $file"
}

say '[2/3] Configure per-project script policies in the two Pi homes'
configure_home "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" pi
configure_home "${GENTLE_SHELL_HOME:-$HOME/.gentle-shell/agent}" gentle-shell

# Eight files from the attached log were *preserved*, not updated, because
# the Gentle AI managed-asset ownership ledger did not match them.
# Back up their exact contents before removing so gentle-ai sync can recreate.
say '[3/3] Release ownership of the eight reported RDD agents (with backup)'
if [ -f "$DONE" ]; then
  say '  already prepared; leaving any newly managed RDD agents untouched'
else
  agent_dir="$HOME/.claude/agents"
  for name in jd-fix-agent jd-judge-a jd-judge-b \
              review-readability review-refuter review-reliability \
              review-resilience review-risk; do
    source="$agent_dir/$name.md"
    [ -f "$source" ] || continue
    [ ! -L "$source" ] || fail "refusing symlinked agent file: $source"
    cp -p "$source" "$BACKUP/$name.md"
    if [ "$(sha256sum "$source" | cut -d' ' -f1)" != "$(sha256sum "$BACKUP/$name.md" | cut -d' ' -f1)" ]; then
      fail "verification failed for backup of $source — original untouched"
    fi
    rm -- "$source"
    say "  backed up and released: $name.md"
  done
  printf 'RDD agent recovery completed at %s\nBackup: %s\n' "$(date -Is)" "$BACKUP" > "$DONE"
  chmod 600 "$DONE"
fi

say ''
say 'Preflight completed.'
say "Backups: $BACKUP"
say 'NEXT: Install gentle-update-final as your gentle-update, then run: gentle-update all'
say 'A later gentle-ai sync will repopulate the managed RDD agent files.'
