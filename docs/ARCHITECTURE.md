# Architecture

ClaudeBar watches Claude Code from the outside. It never talks to Claude directly: it reads files Claude already
writes, plus two small hooks that Claude runs on events.

```
                ~/.claude/sessions/<pid>.json     session list, status (busy/idle), name, cwd
 Claude Code -> ~/.claude/projects/**/<id>.jsonl  transcripts: tokens, titles, tool calls
                hooks ---------------------------> ~/.claude/clauderr/<id>.waiting       (mark.sh)
                hooks <--------------------------> ~/.claude/clauderr/permissions/*      (permission.sh)

 ClaudeBarCore (pure, tested)                     ClaudeBar (AppKit)
 --------------------------------                 -------------------------------
 SessionStore    read sessions, derive state      AppDelegate    refresh loop, status items, timers
 SessionTracker  state changes -> alerts, blink   AppDelegate+Menus   menus, click handlers
 AlertPolicy     alert + delivery rules,          IconRenderer   glyphs, gauge, spinner, frame cache
                 IconModel, visibility checks     Notifier       banners with Approve / Deny
 SessionText     every user-visible string        SettingsWindow SwiftUI settings + hook status
 TokenCounter    incremental transcript scan      Ghostty        AppleScript bridge
 ToolActivity    last tool call, diagnosis        Haptics        HapticWeb plugin client
 PermissionStore request/decision mailbox
 HookInstaller   idempotent settings.json edits
 GhosttyMatcher  pick the tab for a session
 Settings        persisted preferences
```

The rule: **anything that makes a decision lives in `ClaudeBarCore`** and is unit tested. `ClaudeBar` only turns
those decisions into pixels and system calls, and is covered by the smoke test.

## Refresh loop

`AppDelegate.refresh()` runs on a 2 s timer and on any change to `~/.claude/sessions`, `~/.claude/clauderr` or the
permissions mailbox (kqueue file watchers).

1. `SessionStore.load()` reads live sessions (a session whose pid is dead is dropped).
2. `SessionTracker.update()` compares with the previous states and returns alerts; it also starts the finish blink.
3. `PermissionStore.pending()` lists open permission requests; `PermissionAnnouncements` reports new / gone ones.
4. `SessionTracker.visible()` applies "hide idle"; status items are created or removed to match.
5. Alerts are delivered (sound, haptic, banner) per `AlertPolicy.delivery`; tooltips and icons are updated.

Token usage is scanned every 10 s on a background queue. `TokenCounter` only reads transcript bytes appended since the
last scan and de-duplicates streamed messages by message id + request id.

## Session state

`SessionState`: `idle < running < waiting < stuck` (the order is the severity used by the single icon).

- Claude's own `status` (`busy`, `idle`, `shell`) gives idle vs running.
- `waiting` needs the `Notification` hook: `mark.sh set` writes `<session>.waiting`; `UserPromptSubmit`, `Stop` and
  `PostToolUse` clear it. Claude also fires `Notification` when merely idle, so a marker only counts while the
  session is not idle.
- `stuck` = running with no sign of life (status change, transcript or subagent transcript write) for longer than
  the threshold.

## Permission approvals

`hooks/permission.sh` is registered for `PermissionRequest` (timeout 330 s). It is a file mailbox, no sockets:

1. The hook exits immediately (empty output, so Claude shows its normal prompt) when ClaudeBar is not running.
2. Otherwise it writes the raw hook payload to `permissions/<epoch><rand>-<hook pid>.json`.
3. The app lists it, announces it, and on Approve / Deny writes `<id>.decision` (`allow` or `deny`, atomic rename).
4. The hook polls for the decision (300 s max, also exits if the app quits), prints the
   `hookSpecificOutput` JSON and removes both files.

The pid in the file name is how the app notices a dead request: whenever the hook process is gone (for example because
Claude cancelled it after you answered in the terminal; not verified against every Claude version), the request is
pruned and its banner withdrawn.

## Focusing the right terminal tab

Ghostty's AppleScript interface reports each terminal's `tty` and foreground `pid`; a Claude session's process has a
controlling tty (`ps -o tty= -p <pid>`). `GhosttyMatcher.pickMatch` (tests in `GhosttyMatcherTests.swift`):

1. **tty** match, else **pid** match. Exact: two sessions can share folder, title and glyph, never a tty.
2. If the session has a tty and Ghostty reports ttys but none matches, the session is in another terminal: no tab is
   chosen (no look-alike guess).
3. Fallback for Ghostty versions without tty/pid: the session title (`customTitle`, else `aiTitle`, from the transcript
   tail) against the tab title minus its status glyph, else tabs in the same folder (Claude tabs before plain shells).
   If several tabs remain, the glyph breaks the tie: `✳` is idle, any other glyph is busy.

`ClaudeBar --focus-plan` prints the choice and which rule made it (`by tty`, `by pid`, `by title`, `by folder`).

## Decisions worth knowing

- **Files, not sockets**, for hooks: nothing to keep alive, survives app restarts, trivially testable with a shell.
- **Hooks are installed to `~/.claude/clauderr/hooks/`** and registered from there, so moving the repo cannot leave
  `settings.json` pointing at a missing path. The installer is idempotent and repairs stale registrations.
- **`CLAUDEBAR_HOME`** exists because Foundation ignores `$HOME`. Every store takes its home as a parameter, which is
  also what makes the tests hermetic.
- **Newest launch wins** and **reopen opens Settings**, because on a notch Mac a hidden menu bar item looks exactly
  like a crashed app. A reopen caused by clicking a notification is ignored (`ReopenPolicy`).
- **Rendered icons are cached** (`IconRenderer`): the spinner redraws 10 times a second and would otherwise cost ~7 % CPU.

## Testing

| Level | Command | What it proves |
|---|---|---|
| Unit | `make test` | decisions in `ClaudeBarCore`; real files in temp directories |
| Coverage gate | `make coverage` | core stays at or above 90 % line coverage |
| Hook scripts | `make hooks-test` | `mark.sh` / `permission.sh` end to end, with a `pgrep` shim |
| Release, uninstall | `make scripts-test` | release bumps/dates/tags and refuses bad input; uninstall removes only ClaudeBar's parts |
| Smoke | `make smoke` | the real binary, against fake sessions, puts the right items in the menu bar |
| CI | `.github/workflows/ci.yml` | lint, build, unit + coverage, script tests, bundle, installer dry run |

The smoke test needs a logged-in GUI session (it creates real status items), so CI does not run it.

## Known limits

- Tab focus is Ghostty only (`Ghostty` bridge); a session in another terminal can only "open folder".
- The context window size is estimated: transcripts do not record it, so anything above 200k tokens implies 1M.
- Banner buttons and the AppKit layer have no automated UI tests; `--selftest` snapshots cover what can be observed.
