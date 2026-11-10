# Changelog

## 0.2.0

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
  breaks the tie, and plain shell tabs no longer win the folder fallback.
- Clicking a stuck notification also opened Settings.
- Hooks pointed at a path that no longer existed after the project folder moved; they now live in
  `~/.claude/clauderr/hooks/`.

### Changed
- The bolt shows only the icon by default (token count is a setting) to save menu bar space.
- `AppDelegate` split into core logic (`SessionText`, `SessionTracker`, ...), `IconRenderer` and menus.

## 0.1.0

Initial version: one icon per session (waiting / running / idle / stuck / finished), click to focus a Ghostty tab,
today's token usage with context percentage, MX Master haptics, start at login.
