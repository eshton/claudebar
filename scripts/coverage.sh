#!/bin/bash
# Run the unit tests with coverage and print per-file line coverage of ClaudeBarCore.
# Fails when the core drops below MIN_COVERAGE (default 90%). The AppKit layer is covered by Tests/smoke.sh instead.
#   scripts/coverage.sh            MIN_COVERAGE=90 scripts/coverage.sh
set -euo pipefail
cd "$(dirname "$0")/.."
MIN="${MIN_COVERAGE:-90}"
LOG=$(mktemp)
swift test --enable-code-coverage >"$LOG" 2>&1 || { cat "$LOG"; rm -f "$LOG"; exit 1; }
rm -f "$LOG"
BIN=$(find .build -type f -path '*.xctest/Contents/MacOS/ClaudeBarPackageTests' -not -path '*dSYM*' | head -1)
PROF=$(find .build -type f -name default.profdata | head -1)
REPORT=$(xcrun llvm-cov report "$BIN" -instr-profile "$PROF" -ignore-filename-regex='\.build|Tests|Sources/ClaudeBar/')
echo "$REPORT" | awk 'NR==1 {print "file                      lines"} /\.swift/ {printf "%-25s %s\n", $1, $(NF-3)} /^TOTAL/ {total=$(NF-3)} END {print "-----\nTOTAL                     " total}'
PCT=$(echo "$REPORT" | awk '/^TOTAL/ {gsub("%","",$(NF-3)); print int($(NF-3))}')
if [ "$PCT" -lt "$MIN" ]; then echo "coverage ${PCT}% is below the ${MIN}% minimum" >&2; exit 1; fi
echo "coverage ${PCT}% >= ${MIN}%"
