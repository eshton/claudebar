# Releasing

ClaudeBar is built from source; a release is a version bump, a dated changelog section and a git tag.

## Checklist

1. `git status` is clean and on `main`.
2. `CHANGELOG.md` has a `## Unreleased` section listing every user-visible change since the last tag
   (`git log v<last>..HEAD --oneline` to check).
3. Pick the version ([semver](https://semver.org)): patch for fixes only, minor for features, major for breaking
   changes to hooks, settings or command-line flags.
4. `make release VERSION=X.Y.Z`. It refuses unless the tree is clean, the version is newer, the tag is new and
   Unreleased has entries. Then it runs `make check` (needs a logged-in GUI session for the smoke test), writes
   `VERSION`, turns `## Unreleased` into `## X.Y.Z - <date>`, commits `Release X.Y.Z` and creates the annotated tag
   `vX.Y.Z` with that section as its message.
5. `make app`, quit ClaudeBar, `open ClaudeBar.app`, and check the menu footer says `ClaudeBar X.Y.Z`.
6. Once a remote exists: `git push --follow-tags`.

Nothing is pushed or published by the script.

## Undoing a release that was not pushed

```sh
git tag -d vX.Y.Z
git reset --hard HEAD~1     # drops the "Release X.Y.Z" commit (VERSION + CHANGELOG)
```
