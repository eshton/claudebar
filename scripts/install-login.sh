#!/bin/bash
# Start ClaudeBar at login via a LaunchAgent. Undo: scripts/install-login.sh remove
# LAUNCHCTL overrides the launchctl binary (tests set it to `true` so the real launchd is never touched).
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/local.clauderr.ClaudeBar.plist"
APP="$(cd "$(dirname "$0")/.." && pwd)/ClaudeBar.app"
if [ "${1:-}" = "remove" ]; then
  "${LAUNCHCTL:-launchctl}" bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"; echo "removed"; exit 0
fi
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.clauderr.ClaudeBar</string>
<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
PL
echo "installed $PLIST (starts at next login)"
