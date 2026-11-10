# ClaudeBar

Menu bar monitor for Claude Code sessions, one icon per session.

- Icons: orange bubble = waiting on you, green spinner = running, grey pause = idle,
  red triangle = stuck (busy but silent > 10 min), blinking green check = just finished (15s, adjustable in Settings).
- Default is ONE icon for all sessions (worst state wins, badge = how many are in it). Left-click: focus the session
  (one session) or list them all; each row opens that session's menu. Turn off in Settings for one icon per session
  (left-click focuses that session's Ghostty tab, right-click opens its menu).
- Rightmost item (yellow bolt): menu = tokens used today (millions, incl. cache reads) breakdown + per-session.
  The count next to the bolt is optional (Settings), to save menu bar space.
- A full menu bar on a notch Mac hides new icons silently. ClaudeBar notices ("icons are hidden" alert), and running
  `open ClaudeBar.app` again always opens Settings. Only the newest launched copy keeps running.
- Session tooltip/menu: tokens today, context % (window size estimated), last assistant message.
- Right-click menu also has: last-tool diagnosis for stuck/running sessions ("tool still running 14m: Bash `npm test`"),
  Approve/Deny for pending permission prompts, and "Mute alerts for this session" (icon fades).
- macOS notifications for waiting / stuck (optionally finished). Permission requests get Approve / Deny buttons.
- Settings… (⌘,): stuck threshold, hide idle sessions, notifications / sound / haptics, hook install status.
- Haptics (MX Master 4) via the HapticWeb Logi plugin: `completed` on finish, `angry_alert` on stuck.

## Install
    ./build.sh && open ClaudeBar.app
    ./install-login.sh          # start at login (./install-login.sh remove to undo)
    ./install-hooks.sh          # register hooks in ~/.claude/settings.json (status | remove)

Hooks (`hooks/mark.sh`, `hooks/permission.sh`) are copied to `~/.claude/clauderr/hooks/` and registered by
`./install-hooks.sh` (or Settings… > Install / repair) for Notification / UserPromptSubmit / Stop / PostToolUse /
PermissionRequest. They write `~/.claude/clauderr/<session>.waiting` so "waiting" is detected, and a request
mailbox in `~/.claude/clauderr/permissions/`. If ClaudeBar isn't running or nobody answers within 5 min, the
permission hook steps aside and Claude shows its normal terminal prompt. Restart running Claude sessions after installing.
Original settings are backed up once to ~/.claude/settings.json.bak-clauderr.
Preferences: `~/.claude/clauderr/settings.json`.

Data source: `~/.claude/sessions/<pid>.json` + transcripts under `~/.claude/projects/`.

## Debugging tab focus
    ClaudeBar.app/Contents/MacOS/ClaudeBar --focus-plan    # read-only: which Ghostty tab each live session would focus
Tabs are matched by title, then folder. When several tabs match (e.g. two PR reviews in one repo), the tab glyph
(✳ idle, spinner = running) is matched against the session's state.

## Tests
    swift test          # core logic (alert rules, icon choice, hooks installer, permission mailbox, ...)
    Tests/smoke.sh      # launches the real binary against a fake home (CLAUDEBAR_HOME) and checks the menu bar items

`CLAUDEBAR_HOME` redirects everything ClaudeBar reads/writes under `~/.claude` (Foundation ignores `$HOME`).
`ClaudeBar --selftest` refuses to run without it.
