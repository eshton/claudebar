#!/bin/bash
# Remove ClaudeBar from this Mac: quit it, unregister its Claude Code hooks (other hooks are kept), remove the login
# item and the installed hook scripts. Settings stay unless --purge. ClaudeBar.app and this folder are not touched.
#   scripts/uninstall.sh            scripts/uninstall.sh --purge
# Test knobs: CLAUDEBAR_HOME, HOME, CLAUDEBAR_BIN, CLAUDEBAR_NO_QUIT=1, LAUNCHCTL (see Tests/uninstall.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
PURGE=0
case "${1:-}" in
  "") ;;
  --purge) PURGE=1 ;;
  *) echo "usage: scripts/uninstall.sh [--purge]" >&2; exit 2 ;;
esac
DATA="${CLAUDEBAR_HOME:-$HOME}/.claude/clauderr"

BIN="${CLAUDEBAR_BIN:-}"
if [ -z "$BIN" ]; then
  for b in ClaudeBar.app/Contents/MacOS/ClaudeBar .build/release/ClaudeBar .build/debug/ClaudeBar; do
    if [ -x "$b" ]; then BIN=$b; break; fi
  done
fi
if [ -z "$BIN" ]; then swift build >/dev/null; BIN=.build/debug/ClaudeBar; fi

[ "${CLAUDEBAR_NO_QUIT:-0}" = 1 ] || pkill -x ClaudeBar 2>/dev/null || true
"$BIN" --uninstall-hooks
scripts/install-login.sh remove >/dev/null
rm -rf "$DATA/hooks"
if [ $PURGE = 1 ]; then
  rm -rf "$DATA"
  echo "removed settings and state in $DATA"
else
  echo "kept settings in $DATA (scripts/uninstall.sh --purge removes them)"
fi
echo "ClaudeBar uninstalled. Restart running Claude sessions so they drop the hooks."
