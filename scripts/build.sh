#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(tr -d '[:space:]' < VERSION)
# UNIVERSAL=1 builds arm64 + x86_64 (what releases ship); default is the host architecture only.
if [ "${UNIVERSAL:-0}" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/ClaudeBar
else
  swift build -c release
  BIN=.build/release/ClaudeBar
fi
APP=ClaudeBar.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ClaudeBar"
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
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>ClaudeBar focuses the Ghostty tab of a Claude session.</string>
</dict></plist>
PL
codesign --force --sign - "$APP"
echo "Built $APP $VERSION"
