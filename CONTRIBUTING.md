# Contributing

## Setup

```sh
brew install swiftlint     # the only tool beyond the Swift toolchain
make check                 # must pass before every commit
```

`make check` = strict SwiftLint, unit tests with the coverage gate, hook script tests, and the smoke test. The smoke
test briefly creates real menu bar items, so run it in a logged-in session.

## Where does my change go?

- A **decision** (what state, when to alert, what text, which tab, what to install): `Sources/ClaudeBarCore`, with unit
  tests. Keep it free of AppKit.
- **Drawing or system calls** (status items, menus, notifications): `Sources/ClaudeBar`. Keep logic out of it; if you
  need an `if` about behaviour, it probably belongs in the core.
- **Hook scripts**: `hooks/`, with a case in `Tests/hooks.sh`.

## Recipes

**Add a setting**: property + `CodingKeys` + default in `decodeIfPresent` (`Settings.swift`), a control in
`SettingsWindow.swift`, a test in `SettingsTests`, a row in the README table. Old settings files must keep decoding.

**Add an alert or change a rule**: `AlertPolicy` (what fires, how it is delivered), `SessionText.bannerText` (wording),
tests in `AlertAndIconTests` and `SessionTextTests`.

**Change what the menu bar shows**: change the core model (`IconModel`, `SessionText`), then a scenario in
`Tests/smoke.sh` that asserts it on the real binary.

## Tests

- Never touch the real `~/.claude`. Unit tests use `tempHome()`; scripts use `CLAUDEBAR_HOME` or a temp `HOME`.
- A bug fix starts with a failing test that reproduces it (for tab focus, use the real tab names, see
  `GhosttyTieBreakTests`).
- The coverage gate is 90 % of `ClaudeBarCore`. Raise it when coverage rises, never lower it to merge.

## Commits

Short imperative subject, a body that says why. One logical change per commit; keep `make check` green at each one.
