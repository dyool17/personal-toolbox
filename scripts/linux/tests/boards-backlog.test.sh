#!/usr/bin/env bash
# Sandboxed tests for boards-backlog.
#
# Nothing real is read or written: HOME and the state directory live under one
# mktemp directory, and PATH starts with stub `curl` and `engram` commands. The
# curl stub answers the three Azure DevOps endpoints from fixture files and
# logs its arguments to $STUB_LOG; the engram stub logs each call as one JSON
# array per line in $ENGRAM_LOG.
#
# Usage: bash scripts/linux/tests/boards-backlog.test.sh
# Prints one ok/FAIL line per case and exits non-zero when any case failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../boards-backlog"

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
export FIXTURES="$SANDBOX/fixtures"
export STUB_LOG="$SANDBOX/curl.log"
export ENGRAM_LOG="$SANDBOX/engram.log"
export BOARDS_STATE_DIR="$SANDBOX/state"
export BOARDS_ORG="https://dev.azure.com/acme"
export BOARDS_PROJECTS="Hemire"
export AZURE_DEVOPS_EXT_PAT="s3cr3t-pat-value"
unset BOARDS_ASSIGNEE_PATTERNS BOARDS_CLOSED_STATES BOARDS_ENGRAM_PROJECT BOARDS_ENGRAM_TYPE
mkdir -p "$HOME" "$FIXTURES" "$SANDBOX/stubs"
export PATH="$SANDBOX/stubs:$PATH"

cat > "$SANDBOX/stubs/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_LOG"
url="" out="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -K) cat "$2" > /dev/null; shift 2 ;;
    -w|-X|-H) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [ "${STUB_HTTP:-200}" != 200 ]; then
  printf '{"message":"denied"}' > "$out"
  printf '%s' "$STUB_HTTP"
  exit 0
fi
case "$url" in
  */_apis/wit/wiql*)
    jq -c '{workItems: map({id: .})}' "$FIXTURES/open_ids.json" > "$out" ;;
  *workitemsbatch*)
    jq -c --argjson req "$data" \
      '{value: [.[] | select(.id as $i | $req.ids | index($i))]}' "$FIXTURES/items.json" > "$out" ;;
  */comments*)
    id="${url#*workItems/}"; id="${id%%/*}"
    if [ -f "$FIXTURES/comments-$id.json" ]; then cat "$FIXTURES/comments-$id.json" > "$out"
    else printf '{"comments":[]}' > "$out"; fi ;;
  *) printf '{}' > "$out" ;;
esac
printf '200'
STUB

cat > "$SANDBOX/stubs/engram" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_ENGRAM_FAIL:-}" ] && exit 1
for arg in "$@"; do printf '%s' "$arg" | jq -Rs .; done | jq -sc . >> "$ENGRAM_LOG"
STUB
chmod +x "$SANDBOX/stubs/curl" "$SANDBOX/stubs/engram"

# write_items <title of #3> <state of #4> — five work items whose expected
# backlog order is 1 2 3 4 5: severity first, then priority, then oldest first.
write_items() {
  jq -n --arg t3 "$1" --arg s4 "$2" '
    def item($id; $type; $sev; $pri; $created; $title; $state; $comments):
      {id: $id, rev: 1,
       _links: {html: {href: "https://dev.azure.com/acme/Hemire/_workitems/edit/\($id)"}},
       relations: [],
       fields: ({"System.Id": $id, "System.WorkItemType": $type, "System.Title": $title,
                 "System.State": $state, "System.CreatedDate": $created,
                 "System.AssignedTo": {displayName: "Dylan Yool", uniqueName: "dyool@example.com"},
                 "Microsoft.VSTS.Common.Priority": $pri, "System.CommentCount": $comments,
                 "System.Description": "<div>Body of <b>\($id)</b></div>"}
                + (if $sev != "" then {"Microsoft.VSTS.Common.Severity": $sev} else {} end))};
    [ item(5; "Task"; ""; 2; "2026-06-01T10:00:00.5Z"; "Newer P2 task"; "New"; 1),
      item(4; "Task"; ""; 2; "2026-01-01T10:00:00Z"; "Older P2 task"; $s4; 0),
      item(3; "Task"; ""; 1; "2026-08-01T10:00:00Z"; $t3; "New"; 0),
      item(2; "Bug"; "3 - Medium"; 1; "2026-09-01T10:00:00Z"; "Medium bug"; "New"; 0),
      item(1; "Bug"; "2 - High"; 3; "2026-10-01T10:00:00Z"; "High bug"; "New"; 0) ]
  ' > "$FIXTURES/items.json"
}
printf '{"comments":[{"text":"<p>please check</p>","createdDate":"2026-06-02T08:00:00Z","createdBy":{"displayName":"Ana"}}]}' \
  > "$FIXTURES/comments-5.json"

# run <args...> — sets OUT (stdout) and RC; stderr goes to $SANDBOX/err.
run() { OUT="$("$SCRIPT" "$@" 2> "$SANDBOX/err")"; RC=$?; }
reset() { rm -rf "$BOARDS_STATE_DIR" "$STUB_LOG" "$ENGRAM_LOG"; : > "$STUB_LOG"; : > "$ENGRAM_LOG"; }
saves() { wc -l < "$ENGRAM_LOG" | tr -d ' '; }
topics() { jq -r '. as $a | $a[($a | index("--topic")) + 1]' "$ENGRAM_LOG" | sort | paste -sd' '; }
ids_in_table() { grep -o '#[0-9]\+' <<< "$OUT" | tr -d '#' | paste -sd' '; }

# --- first run ---------------------------------------------------------------

reset
write_items "P1 task" "New"
echo '[5,4,3,2,1]' > "$FIXTURES/open_ids.json"
run
check_eq "first run exits 0" 0 "$RC"
check_eq "backlog is ordered by severity, priority, then oldest first" "1 2 3 4 5" "$(ids_in_table)"
check "query matches both assignee patterns" \
  grep -q "AssignedTo\] CONTAINS 'dylan' OR \[System.AssignedTo\] CONTAINS 'dyool'" "$STUB_LOG"
check "query excludes closed states" grep -q "NOT IN ('Closed', 'Done', 'Removed')" "$STUB_LOG"
check_not "the PAT never appears in curl arguments" grep -q "$AZURE_DEVOPS_EXT_PAT" "$STUB_LOG"
check_eq "first run saves every item plus the backlog" 6 "$(saves)"
check_eq "each observation has its own topic key" \
  "boards/hemire/backlog boards/hemire/item-1 boards/hemire/item-2 boards/hemire/item-3 boards/hemire/item-4 boards/hemire/item-5" \
  "$(topics)"
check_eq "observations go to the engram project named after the board" 6 \
  "$(jq -r '. as $a | $a[($a | index("--project")) + 1]' "$ENGRAM_LOG" | grep -c '^hemire$')"
check "item observation carries description and comments as text" \
  jq -e 'select(.[1] | startswith("Hemire #5 ")) | .[2] | (contains("Body of 5") and contains("Ana: please check") and (contains("<div>") | not))' "$ENGRAM_LOG"
check "backlog observation lists the items in order" \
  jq -e 'select(.[1] == "Boards backlog: Hemire") | .[2] | (index("#1 ") < index("#2 ")) and (index("#4 ") < index("#5 "))' "$ENGRAM_LOG"
check "raw work item is stored with its comments" \
  jq -e '.item.fields["System.Description"] == "<div>Body of <b>5</b></div>" and (.comments | length) == 1' \
  "$BOARDS_STATE_DIR/hemire/items/5.json"

# --- unchanged, changed, closed ----------------------------------------------

: > "$ENGRAM_LOG"
run
check_eq "an unchanged board saves nothing" 0 "$(saves)"

: > "$ENGRAM_LOG"
write_items "P1 task renamed" "New"
run
check_eq "a changed item is saved again together with the backlog" \
  "boards/hemire/backlog boards/hemire/item-3" "$(topics)"

: > "$ENGRAM_LOG"
write_items "P1 task renamed" "Closed"
echo '[5,3,2,1]' > "$FIXTURES/open_ids.json"
run
check_eq "a closed item leaves the backlog" "1 2 3 5" "$(ids_in_table)"
check_eq "a closed item is saved once more with the backlog" \
  "boards/hemire/backlog boards/hemire/item-4" "$(topics)"
check "the closing save records the closed state" \
  jq -e 'select(.[1] | startswith("Hemire #4 ")) | .[2] | contains("State: Closed")' "$ENGRAM_LOG"
: > "$ENGRAM_LOG"
run
check_eq "a closed item is not saved again afterwards" 0 "$(saves)"

# An item deleted on the board is no longer returned by the API at all.
: > "$ENGRAM_LOG"
jq -c 'map(select(.id != 2))' "$FIXTURES/items.json" > "$FIXTURES/items.next" \
  && mv "$FIXTURES/items.next" "$FIXTURES/items.json"
echo '[5,3,1]' > "$FIXTURES/open_ids.json"
run
check_eq "a deleted item is saved once more with the backlog" \
  "boards/hemire/backlog boards/hemire/item-2" "$(topics)"
check "the deleting save records the deleted state and keeps the title" \
  jq -e 'select(.[1] == "Hemire #2 [Bug] Medium bug") | .[2] | contains("State: Deleted")' "$ENGRAM_LOG"
: > "$ENGRAM_LOG"
run
check_eq "a deleted item is not saved again afterwards" 0 "$(saves)"

# --- flags -------------------------------------------------------------------

reset
write_items "P1 task" "New"
echo '[5,4,3,2,1]' > "$FIXTURES/open_ids.json"
run --dry-run
check_eq "--dry-run exits 0" 0 "$RC"
check_eq "--dry-run saves nothing to engram" 0 "$(saves)"
check_not "--dry-run writes no state" test -e "$BOARDS_STATE_DIR"
check_eq "--dry-run still prints the backlog" "1 2 3 4 5" "$(ids_in_table)"

run --no-engram
check_eq "--no-engram saves nothing to engram" 0 "$(saves)"
check "--no-engram still stores the raw items" test -f "$BOARDS_STATE_DIR/hemire/items/1.json"

run --json --no-engram
check_eq "--json prints the ordered items as JSON" "1 2 3 4 5" "$(jq -r 'map(.id) | join(" ")' <<< "$OUT")"

run --bogus
check_eq "an unknown flag is a usage error" 2 "$RC"

# --- failures ----------------------------------------------------------------

reset
STUB_HTTP=401 run
check_eq "an API error exits 1" 1 "$RC"
check_eq "an API error saves nothing to engram" 0 "$(saves)"

AZURE_DEVOPS_EXT_PAT="" run
check_eq "a missing PAT exits 1" 1 "$RC"
check "a missing PAT is named in the error" grep -q AZURE_DEVOPS_EXT_PAT "$SANDBOX/err"

printf 'export AZURE_DEVOPS_EXT_PAT="from-file"\n' > "$SANDBOX/pat-file"
AZURE_DEVOPS_EXT_PAT="" BOARDS_PAT_FILE="$SANDBOX/pat-file" run
check_eq "a missing PAT is read from the PAT file" 0 "$RC"

reset
STUB_ENGRAM_FAIL=1 run
check_eq "a failed engram save exits 1" 1 "$RC"
run
check_eq "items whose save failed are retried on the next run" 6 "$(saves)"

if [ "$FAILS" -gt 0 ]; then printf '\n%d case(s) failed\n' "$FAILS"; exit 1; fi
printf '\nall cases passed\n'
