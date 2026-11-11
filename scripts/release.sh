#!/bin/bash
# Cut a release: bump VERSION, date the CHANGELOG's "## Unreleased" section, commit, and tag vX.Y.Z (annotated,
# with that section as the tag message). Runs `make check` first. Never pushes.
#   scripts/release.sh 0.3.0
#   SKIP_CHECK=1 scripts/release.sh 0.3.0                     skip `make check` (Tests/release.sh)
#   RELEASE_TRAILER="Co-Authored-By: ..." scripts/release.sh   add a trailer to the release commit
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "release: $*" >&2; exit 1; }

NEW="${1:-}"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh X.Y.Z"
CUR=$(tr -d '[:space:]' < VERSION)
# numeric, field by field: 0.10.0 > 0.9.0
newer=$(awk -v a="$NEW" -v b="$CUR" 'BEGIN { split(a, x, "."); split(b, y, ".");
  for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) { print 1; exit } if (x[i] + 0 < y[i] + 0) { print 0; exit } } print 0 }')
[ "$newer" = 1 ] || die "$NEW is not newer than the current version $CUR"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean; commit or stash first"
! git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null || die "tag v$NEW already exists"
grep -q '^## Unreleased$' CHANGELOG.md || die "CHANGELOG.md has no '## Unreleased' section"
NOTES=$(awk '/^## Unreleased$/ { f = 1; next } /^## / { f = 0 } f' CHANGELOG.md | sed '/./,$!d')
[ -n "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ] || die "the Unreleased section of CHANGELOG.md is empty"

[ "${SKIP_CHECK:-0}" = 1 ] || make check

echo "$NEW" > VERSION
awk -v h="## $NEW - $(date +%Y-%m-%d)" '!done && /^## Unreleased$/ { print h; done = 1; next } { print }' \
  CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
git add VERSION CHANGELOG.md
if [ -n "${RELEASE_TRAILER:-}" ]; then
  git commit -q -m "Release $NEW" --trailer "$RELEASE_TRAILER"
else
  git commit -q -m "Release $NEW"
fi
printf 'ClaudeBar %s\n\n%s\n' "$NEW" "$NOTES" | git tag -a "v$NEW" -F -
echo "Released $NEW (tag v$NEW). Next: make app; git push --follow-tags once a remote exists."
