# Changelog

## Unreleased

### Added
- **MIT license.**
- **Uninstall**: `make uninstall` removes hooks (keeping your others), the login item and installed scripts;
  `--purge` also deletes settings.
- **Version at the bottom of every menu**; release process (`make release VERSION=X.Y.Z`, `docs/RELEASING.md`).
- **Click a session in the bolt menu to jump to its Ghostty tab** (same as clicking its icon, state glyph per row).
- **Soft bell when a job finishes** (system sound `Glass` at half volume; choose None / Glass / Tink / Pop / Purr in
  Settings). Errors and "needs you" keep the louder `Ping`, which also wins when both happen at once.
- **A clicked finished session stays for 2 minutes**: the blink stops and a steady green check remains (also when
  "hide idle sessions" is on). Adjustable, 0 = drop at once.

### Fixed
- Installing hooks from a binary that could not find the hook scripts registered hooks pointing at missing files
  without any error; it now refuses. (`.build/debug` is a symlink, so the repo was not found from a debug build.)
- Clicking a session could still open the wrong Ghostty tab when two idle sessions had the same folder, title and
  glyph. Tabs are now matched exactly by terminal tty (and foreground pid); title/folder/glyph matching is only a
  fallback for Ghostty versions without tty support, and a session running outside Ghostty no longer lands on a
  look-alike tab.

## 0.2.0 - 2026-11-10

### Added
- **Single combined icon** (default): worst state wins, badge counts sessions in it; click focuses or lists sessions.
- **Approve / Deny permission prompts** from banner buttons, the icon menu or the bolt menu (`PermissionRequest` hook).
- **Notifications** for waiting, stuck and (optionally) finished sessions.
- **Stuck diagnosis**: last tool call and whether it ever returned.
- **Mute per session**, **hide idle sessions**, adjustable **stuck threshold** and **finish blink** duration.
- **Spinning running icon** (respects Reduce motion), with a rendered-frame cache.
- **Settings window** (⌘,) and `~/.claude/clauderr/settings.json`.
- **Hook installer** (`scripts/install-hooks.sh`, Settings window): idempotent, repairs stale paths, keeps other hooks.
- **Hidden-icon detection**: alert when macOS hides the icons (full menu bar on a notch Mac); reopening the app opens
  Settings; the newest launched copy replaces older ones.
- `--focus-plan`, `--version`, `--selftest`, `CLAUDEBAR_HOME`.
- Makefile, CI, hook script tests, smoke test, coverage gate, SwiftLint.

### Fixed
- Clicking an icon went to the wrong Ghostty tab when two sessions shared a folder and a title: the tab glyph now
  breaks the tie, and plain shell tabs no longer win the folder fallback (superseded by tty matching, see Unreleased).
- Clicking a stuck notification also opened Settings.
- Hooks pointed at a path that no longer existed after the project folder moved; they now live in
  `~/.claude/clauderr/hooks/`.

### Changed
- The bolt shows only the icon by default (token count is a setting) to save menu bar space.
- `AppDelegate` split into core logic (`SessionText`, `SessionTracker`, ...), `IconRenderer` and menus.

## 0.1.0 - 2026-11-05

Initial version: one icon per session (waiting / running / idle / stuck / finished), click to focus a Ghostty tab,
today's token usage with context percentage, MX Master haptics, start at login.
