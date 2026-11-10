#!/bin/bash
# Install / repair / remove ClaudeBar's Claude Code hooks in ~/.claude/settings.json.
#   scripts/install-hooks.sh            install or repair (idempotent)
#   scripts/install-hooks.sh status     show whether hooks are installed
#   scripts/install-hooks.sh remove     remove them
# Scripts are copied to ~/.claude/clauderr/hooks/ and registered from there, so moving this repo can't break them.
# The original settings.json is saved once as settings.json.bak-clauderr. Restart running Claude sessions afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=ClaudeBar.app/Contents/MacOS/ClaudeBar
[ -x "$BIN" ] || scripts/build.sh
case "${1:-install}" in
  install) "$BIN" --install-hooks ;;
  status)  "$BIN" --hooks-status ;;
  remove)  "$BIN" --uninstall-hooks ;;
  *) echo "usage: $0 [install|status|remove]" >&2; exit 2 ;;
esac
