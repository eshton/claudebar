# ClaudeBar

A macOS menu bar monitor for [Claude Code](https://claude.com/claude-code) sessions. See which sessions are
running, waiting for you, stuck or finished, jump to the right terminal tab, and approve permission prompts
without leaving what you are doing.

## Features

- **One icon for all sessions** (or one per session). The worst state wins and a badge counts sessions in it.
  | Icon | Meaning |
  |---|---|
  | orange bubble | waiting on you |
  | green spinner (rotating) | running |
  | grey pause | idle |
  | red triangle | stuck: busy but silent for longer than the threshold (10 min) |
  | blinking green check | just finished (15 s) |
  | thin bar beside the icon | context window usage: green < 60 %, orange < 85 %, red beyond |
- **Click to focus** the session's [Ghostty](https://ghostty.org) tab, matched exactly by terminal tty (two sessions in
  the same folder with the same title are fine). Older Ghostty versions fall back to title, folder and tab glyph.
- **Notifications** when a session needs you or gets stuck (optionally when it finishes). The stuck banner says why:
  *"tool still running 14m: Bash `npm test`"* or *"last tool finished 10m ago; model silent since"*.
- **Approve / Deny permission prompts** from a banner button, the icon's menu or the bolt menu. If ClaudeBar is not
  running or nobody answers within 5 minutes, Claude falls back to its normal terminal prompt.
- **Token usage today** (bolt icon): input / output / cache breakdown, per session, with context percentage.
- **Mute a session** (right-click) and **hide idle sessions** for a quieter menu bar.
- **Haptics** on an MX Master 4 through the [HapticWeb](https://github.com/Fallstop/HapticWebPlugin) Logi plugin
  (optional): a buzz on finish, a stronger one on stuck.

## Requirements

macOS 13+, Swift 5.9+ toolchain (Xcode or Command Line Tools). Tab focus needs Ghostty 1.3+ (AppleScript support) and
grants Automation permission on first use. Everything else works with any terminal.

## Install

```sh
make app                  # release build -> ClaudeBar.app
open ClaudeBar.app
make install-hooks        # register the Claude Code hooks (needed for "waiting" and approvals)
make install-login        # optional: start at login
```

Restart running Claude sessions after installing the hooks; they read hooks at startup.
`scripts/install-hooks.sh status | remove` shows or removes them. The installer keeps your other hooks and saves your
original `~/.claude/settings.json` once as `settings.json.bak-clauderr`.

Launching a newer copy replaces an older running one. Running `open ClaudeBar.app` again always opens Settings.

## Settings

Open from any menu (⌘,). Stored in `~/.claude/clauderr/settings.json`.

| Setting | Default | |
|---|---|---|
| One icon for all sessions | on | off: one icon per session |
| Show token count next to the bolt | off | saves ~36 pt of menu bar |
| Spin the icon while running | on | also off when macOS "Reduce motion" is on |
| Stuck after N minutes | 10 | |
| Blink the green check for N s | 15 | |
| Hide idle sessions | off | they return when finishing or needing approval |
| Notifications / also on finish | on / off | |
| Sound / Haptics | on / on | |
| Approve / deny from the menu bar | on | installs the `PermissionRequest` hook |

## Troubleshooting

- **No icon in the menu bar.** On Macs with a notch, a full menu bar silently hides new items. ClaudeBar detects this
  and shows an alert after about 30 s; free some space (⌘-drag other icons off) or keep single-icon mode on.
- **Sessions never show as "waiting".** Run `make install-hooks`, then restart your Claude sessions.
  `scripts/install-hooks.sh status` says `needsRepair` when a hook points at a path that no longer exists.
- **Click goes to the wrong tab.** `ClaudeBar.app/Contents/MacOS/ClaudeBar --focus-plan` prints, read-only, which tab
  each live session would focus and by which rule (tty, pid, title, folder).
- **No banners.** Allow notifications for ClaudeBar in System Settings, Notifications.

## Command line

```
ClaudeBar --install-hooks | --uninstall-hooks | --hooks-status    manage Claude Code hooks (no UI)
ClaudeBar --focus-plan                                           which Ghostty tab each session would focus
ClaudeBar --version
ClaudeBar --selftest        (needs CLAUDEBAR_HOME)               print the menu bar state as JSON; used by Tests/smoke.sh
```

`CLAUDEBAR_HOME` redirects everything ClaudeBar reads and writes under `~/.claude` (Foundation ignores `$HOME`).

## Development

```sh
make help         # all targets
make check        # lint + unit tests with coverage gate + hook tests + smoke test
make test         # unit tests only
make smoke        # launches the real binary against a fake home; briefly creates menu bar items
```

| Layer | Where | Tested by |
|---|---|---|
| Decisions: states, alerts, text, tab matching, hook installer, token counting | `Sources/ClaudeBarCore` | unit tests, 94 % line coverage (gate: 90 %) |
| AppKit: status items, menus, notifications, settings window | `Sources/ClaudeBar` | `Tests/smoke.sh` against a fake home |
| Hook scripts | `hooks/` | `Tests/hooks.sh` |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit and [CONTRIBUTING.md](CONTRIBUTING.md) before
sending a change.
