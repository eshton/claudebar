#!/bin/bash
# Tests for the Claude Code hook scripts (hooks/mark.sh, hooks/permission.sh). No GUI needed, safe for CI.
# Runs the real scripts against a throwaway HOME, with a `pgrep` shim so the result doesn't depend on whether a real
# ClaudeBar happens to be running on the machine.
#   Tests/hooks.sh
set -uo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT
mkdir -p "$T/shim" "$T/home"
# "ClaudeBar is running" iff $T/running exists
printf '#!/bin/bash\n[ -f "%s/running" ]\n' "$T" > "$T/shim/pgrep"; chmod +x "$T/shim/pgrep"
fail=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fail=1; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: '$2', want: '$3')"; fi; }

MARKERS="$T/home/.claude/clauderr"
mark() { echo "$2" | HOME="$T/home" bash hooks/mark.sh "$1"; }

# --- mark.sh -----------------------------------------------------------------------------------------------------
mark set '{"session_id":"abc-123","hook_event_name":"Notification"}'
[ -f "$MARKERS/abc-123.waiting" ] && ok "mark set creates the waiting marker" || bad "mark set creates the waiting marker"
mark clear '{"session_id":"abc-123"}'
[ ! -f "$MARKERS/abc-123.waiting" ] && ok "mark clear removes it" || bad "mark clear removes it"
mark set '{"no_session":"x"}'
expect "mark ignores payloads without a session id" "$(ls "$MARKERS" 2>/dev/null | wc -l | tr -d ' ')" "0"
mark set '{"session_id":"s p a c e"}'
expect "mark set never fails the hook (exit 0)" "$?" "0"

# --- permission.sh -----------------------------------------------------------------------------------------------
PAY='{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}'
PERM="$MARKERS/permissions"
run() { HOME="$T/home" PATH="$T/shim:$PATH" bash hooks/permission.sh <<<"$PAY"; }
decide() {   # decide <allow|deny>: wait for the request to appear, then answer it
  for _ in $(seq 1 50); do ls "$PERM"/*.json >/dev/null 2>&1 && break; sleep 0.1; done
  local id; id=$(basename "$(ls "$PERM"/*.json | head -1)" .json)
  printf '%s' "$1" > "$PERM/$id.decision"
}
leftover() { ls "$PERM" 2>/dev/null | wc -l | tr -d ' '; }

SECONDS=0
out=$(run); rc=$?
expect "no ClaudeBar running: silent fallback to the terminal prompt" "$out|$rc" "|0"
[ $SECONDS -le 2 ] && ok "no ClaudeBar running: returns immediately" || bad "no ClaudeBar running: returns immediately (${SECONDS}s)"

touch "$T/running"
for verdict in allow deny; do
  run > "$T/out" & pid=$!
  decide $verdict; wait $pid
  expect "decision '$verdict' is emitted as hook JSON" "$(cat "$T/out")" \
    "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"$verdict\"}}}"
  expect "decision '$verdict' leaves no files behind" "$(leftover)" "0"
done

run > "$T/out" & pid=$!
for _ in $(seq 1 50); do ls "$PERM"/*.json >/dev/null 2>&1 && break; sleep 0.1; done
id=$(basename "$(ls "$PERM"/*.json | head -1)" .json)
# the app treats a request as dead once this pid exits, so it must be the live hook process
expect "request file ends in the live hook's pid" "$(ps -p "${id##*-}" -o command= 2>/dev/null | grep -c 'hooks/permission.sh')" "1"
expect "request file holds the raw hook payload" "$(cat "$PERM/$id.json")" "$PAY"
rm "$T/running"; wait $pid
expect "app quitting mid-wait falls back silently" "$(cat "$T/out")" ""
expect "app quitting mid-wait leaves no files behind" "$(leftover)" "0"

touch "$T/running"
run > "$T/out" & pid=$!
for _ in $(seq 1 50); do ls "$PERM"/*.json >/dev/null 2>&1 && break; sleep 0.1; done
id=$(basename "$(ls "$PERM"/*.json | head -1)" .json)
printf 'garbage' > "$PERM/$id.decision"; wait $pid
expect "unrecognised decision falls back silently" "$(cat "$T/out")" ""

[ $fail = 0 ] && echo "hooks: all passed" || { echo "hooks: FAILED"; exit 1; }
