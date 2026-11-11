#!/bin/bash
# Build the release artifact: a universal ClaudeBar.app zipped as dist/ClaudeBar-<VERSION>.zip, plus its sha256.
# Upload it to the GitHub release for v<VERSION> and put the sha256 in the Homebrew cask (see docs/RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(tr -d '[:space:]' < VERSION)
UNIVERSAL=1 scripts/build.sh
mkdir -p dist
ZIP="dist/ClaudeBar-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --noacl --keepParent ClaudeBar.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$SHA" > "$ZIP.sha256"
echo "$ZIP"
echo "sha256 $SHA"
