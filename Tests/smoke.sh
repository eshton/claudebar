#!/bin/bash
# Smoke test: launches the real ClaudeBar binary against a throwaway home (CLAUDEBAR_HOME) with fake live
# sessions, and checks what it would put in the menu bar. Never touches the real ~/.claude.
# The app briefly creates real menu bar items (~2s per scenario), so run it in a logged-in GUI session.
#   Tests/smoke.sh
set -uo pipefail
cd "$(dirname "$0")/.."
swift build >/dev/null 2>&1 || { swift build 2>&1 | tail -20; exit 1; }
BIN=.build/debug/ClaudeBar
T=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT

sleep 300 & PIDS+=($!); P1=$!
sleep 300 & PIDS+=($!); P2=$!
NOW_MS=$(( $(date +%s) * 1000 ))
fail=0

reset() {   # reset <settings-json>
  rm -rf "$T/.claude"; mkdir -p "$T/.claude/sessions" "$T/.claude/clauderr/permissions" "$T/.claude/projects"
  # no sound / haptics / banners from a test run
  echo "$1" > "$T/.claude/clauderr/settings.json"
}
session() { # session <pid> <id> <name> <status>
  echo "{\"pid\":$1,\"sessionId\":\"$2\",\"cwd\":\"/tmp/smoke\",\"name\":\"$3\",\"status\":\"$4\",\"statusUpdatedAt\":$NOW_MS}" > "$T/.claude/sessions/$1.json"
}
check() {   # check <name> <python-expression over d>
  local out
  out=$(CLAUDEBAR_HOME="$T" "$BIN" --selftest 2>&1 | tail -1)
  if python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert ($2), d" "$out" 2>/dev/null; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "     $out"; fail=1
  fi
}
BASE='"sound":false,"haptics":false,"notifications":false'

reset "{$BASE,\"singleIcon\":false}"; session $P1 s1 alpha busy; session $P2 s2 beta idle
check "per-session mode: one item per session" 'len(d["sessionItems"])==2 and not d["placeholder"] and all(i["hasImage"] for i in d["sessionItems"])'

reset "{$BASE,\"singleIcon\":true}"; session $P1 s1 alpha busy; session $P2 s2 beta idle
check "single-icon mode: one item listing both sessions" 'len(d["sessionItems"])==1 and "alpha" in d["sessionItems"][0]["tooltip"] and "beta" in d["sessionItems"][0]["tooltip"]'

reset "{$BASE,\"singleIcon\":true}"; session $P1 s1 alpha busy; session $P2 s2 beta busy
check "single-icon mode: badge counts sessions in worst state" 'd["sessionItems"][0]["title"].strip()=="2"'

reset "{$BASE}"
check "no sessions: placeholder, no session items" 'd["placeholder"] and len(d["sessionItems"])==0'

reset "{$BASE,\"singleIcon\":true}"; session $P1 s1 alpha busy
check "running session -> icon animates" 'd["animating"] is True'

reset "{$BASE,\"singleIcon\":true,\"animateRunning\":false}"; session $P1 s1 alpha busy
check "animation can be turned off" 'd["animating"] is False'

reset "{$BASE,\"singleIcon\":true}"; session $P1 s1 alpha idle
check "idle only -> no animation timer" 'd["animating"] is False'

reset "{$BASE,\"hideIdle\":true}"; session $P1 s1 alpha idle; session $P2 s2 beta idle
check "hide idle: all idle -> placeholder" 'd["placeholder"] and len(d["sessionItems"])==0'

reset "{$BASE,\"showTokenText\":false}"; session $P1 s1 alpha busy
check "bolt is icon-only by default" 'd["token"]["hasImage"] and d["token"]["title"]==""'

reset "{$BASE,\"showTokenText\":true}"; session $P1 s1 alpha busy
check "bolt shows token text when enabled" 'd["token"]["title"].strip()!=""'

reset "{$BASE,\"singleIcon\":true}"; session $P1 s1 alpha busy
echo "{\"session_id\":\"s1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf x\"}}" > "$T/.claude/clauderr/permissions/1700000000-$P1.json"
check "pending permission request is surfaced" 'd["pending"]==1 and "approval needed" in d["sessionItems"][0]["tooltip"]'

# safety: refuses to run without CLAUDEBAR_HOME
if "$BIN" --selftest >/dev/null 2>&1; then echo "FAIL selftest must refuse without CLAUDEBAR_HOME"; fail=1; else echo "ok   selftest refuses without CLAUDEBAR_HOME"; fi

[ $fail = 0 ] && echo "smoke: all passed" || { echo "smoke: FAILED"; exit 1; }
