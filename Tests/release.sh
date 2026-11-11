#!/bin/bash
# Tests for scripts/release.sh, run in throwaway git repos (never this one). No GUI needed, safe for CI.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export SKIP_CHECK=1
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: '$2', want: '$3')"; fi; }

# repo <version> <changelog>: fresh repo with the working-tree release script
repo() {
  rm -rf "$T/r"; mkdir -p "$T/r/scripts"; cd "$T/r"
  git init -q; cp "$ROOT/scripts/release.sh" scripts/
  echo "$1" > VERSION; printf '%s' "$2" > CHANGELOG.md
  git add -A; git commit -qm init
}
refused() {   # refused <name> <args...>: release must fail and leave VERSION and tags alone
  local name=$1; shift
  local before; before=$(cat VERSION)
  if scripts/release.sh "$@" >/dev/null 2>&1; then bad "$name: should be refused"
  elif [ "$(cat VERSION)" != "$before" ] || [ -n "$(git tag)" ]; then bad "$name: refused but changed state"
  else ok "$name"; fi
}

LOG=$'# Changelog\n\n## Unreleased\n\n### Added\n- new thing\n\n## 0.1.0 - 2026-01-01\n\n- old thing\n'

repo 0.1.0 "$LOG"
out=$(scripts/release.sh 0.2.0 2>&1); rc=$?
expect "release succeeds" "$rc" "0"
expect "VERSION bumped" "$(cat VERSION)" "0.2.0"
expect "Unreleased heading dated" "$(grep -c "^## 0.2.0 - $(date +%Y-%m-%d)$" CHANGELOG.md)" "1"
expect "no Unreleased heading left" "$(grep -c '^## Unreleased$' CHANGELOG.md)" "0"
expect "older sections untouched" "$(grep -c '^## 0.1.0 - 2026-01-01$' CHANGELOG.md)" "1"
expect "release commit" "$(git log -1 --format=%s)" "Release 0.2.0"
expect "annotated tag v0.2.0" "$(git cat-file -t v0.2.0 2>/dev/null)" "tag"
expect "tag points at the release commit" "$(git rev-parse v0.2.0^{commit})" "$(git rev-parse HEAD)"
msg=$(git tag -l --format='%(contents)' v0.2.0)
expect "tag message has this release's notes" "$(echo "$msg" | grep -c 'new thing')" "1"
expect "tag message excludes older notes" "$(echo "$msg" | grep -c 'old thing')" "0"
expect "tree clean after release" "$(git status --porcelain)" ""
expect "never pushes (no remote configured, nothing to push)" "$(git remote)" ""

repo 0.1.0 "$LOG"
RELEASE_TRAILER="Co-Authored-By: Someone <s@example.com>" scripts/release.sh 0.1.1 >/dev/null 2>&1
expect "optional commit trailer" "$(git log -1 --format='%(trailers:key=Co-Authored-By,valueonly)' | head -1)" "Someone <s@example.com>"

repo 0.9.0 "$LOG"
scripts/release.sh 0.10.0 >/dev/null 2>&1
expect "versions compare numerically (0.10.0 > 0.9.0)" "$(cat VERSION)" "0.10.0"

repo 0.2.0 "$LOG"
refused "same version refused" 0.2.0
refused "older version refused" 0.1.9
refused "malformed version refused" 1.2
refused "missing version refused"
echo dirty >> CHANGELOG.md
refused "dirty tree refused" 0.3.0
git checkout -q CHANGELOG.md
git tag v0.3.0
refused_tag() { if scripts/release.sh 0.3.0 >/dev/null 2>&1; then bad "existing tag refused"; else ok "existing tag refused"; fi; }
refused_tag
git tag -d v0.3.0 >/dev/null

repo 0.1.0 $'# Changelog\n\n## Unreleased\n\n## 0.1.0\n'
refused "empty Unreleased section refused" 0.2.0
repo 0.1.0 $'# Changelog\n\n## 0.1.0\n- x\n'
refused "missing Unreleased section refused" 0.2.0

[ $fail = 0 ] && echo "release: all passed" || { echo "release: FAILED"; exit 1; }
