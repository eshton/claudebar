#!/bin/bash
# Tests for scripts/uninstall.sh against a throwaway home. Never touches the real ~/.claude, LaunchAgents or launchd,
# and never quits a running ClaudeBar. No GUI needed, safe for CI.
set -uo pipefail
cd "$(dirname "$0")/.."
swift build >/dev/null 2>&1 || { swift build 2>&1 | tail -20; exit 1; }   # with the real HOME (build caches)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T" CLAUDEBAR_HOME="$T" CLAUDEBAR_BIN="$PWD/.build/debug/ClaudeBar" CLAUDEBAR_NO_QUIT=1 LAUNCHCTL=true
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

SETTINGS="$T/.claude/settings.json"
DATA="$T/.claude/clauderr"
PLIST="$T/Library/LaunchAgents/local.clauderr.ClaudeBar.plist"
mkdir -p "$T/.claude"
cat > "$SETTINGS" <<'J'
{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}
J

# install everything ClaudeBar installs
"$CLAUDEBAR_BIN" --install-hooks >/dev/null
scripts/install-login.sh >/dev/null
mkdir -p "$DATA"; echo '{"stuckMinutes":7}' > "$DATA/settings.json"
check "setup: hooks registered" 'grep -q "clauderr/hooks" "$SETTINGS"'
check "setup: hook scripts installed (status: installed)" '[ "$("$CLAUDEBAR_BIN" --hooks-status)" = installed ]'
check "setup: login item present" '[ -f "$PLIST" ]'

scripts/uninstall.sh >/dev/null; rc=$?
check "uninstall exits 0" '[ $rc = 0 ]'
check "ClaudeBar hooks unregistered" '! grep -q "clauderr" "$SETTINGS"'
check "other hooks kept" 'grep -q "rtk hook claude" "$SETTINGS"'
check "other settings kept" 'grep -q "\"model\"" "$SETTINGS"'
check "login item removed" '[ ! -f "$PLIST" ]'
check "installed hook scripts removed" '[ ! -d "$DATA/hooks" ]'
check "user settings kept without --purge" '[ -f "$DATA/settings.json" ]'
check "hooks status: notInstalled" '[ "$("$CLAUDEBAR_BIN" --hooks-status)" = notInstalled ]'

scripts/uninstall.sh >/dev/null 2>&1; rc=$?
check "running it twice is fine" '[ $rc = 0 ]'

scripts/uninstall.sh --purge >/dev/null; rc=$?
check "--purge exits 0" '[ $rc = 0 ]'
check "--purge removes the data folder" '[ ! -d "$DATA" ]'
check "--purge keeps Claude settings" 'grep -q "rtk hook claude" "$SETTINGS"'

scripts/uninstall.sh --bogus >/dev/null 2>&1; rc=$?
check "unknown flag is rejected" '[ $rc = 2 ]'

[ $fail = 0 ] && echo "uninstall: all passed" || { echo "uninstall: FAILED"; exit 1; }
