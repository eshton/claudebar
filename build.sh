#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=ClaudeBar.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeBar "$APP/Contents/MacOS/ClaudeBar"
# Hook scripts ride along so the app (and install-hooks.sh) can install them from the bundle.
mkdir -p "$APP/Contents/Resources/hooks"
cp hooks/mark.sh hooks/permission.sh "$APP/Contents/Resources/hooks/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ClaudeBar</string>
<key>CFBundleIdentifier</key><string>local.clauderr.ClaudeBar</string>
<key>CFBundleExecutable</key><string>ClaudeBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>ClaudeBar focuses the Ghostty tab of a Claude session.</string>
</dict></plist>
PL
codesign --force --sign - "$APP"
echo "Built $APP"
