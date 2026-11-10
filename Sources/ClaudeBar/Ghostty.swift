import AppKit
import ClaudeBarCore

/// Thin AppleScript bridge to Ghostty 1.3+ (needs Automation permission on first use).
enum Ghostty {
    /// "id<TAB>tty<TAB>pid<TAB>cwd<TAB>name" per terminal. Ghostty versions without tty/pid support fall back
    /// to "id<TAB>cwd<TAB>name" (matching then uses the title heuristics).
    static func listTerminals() -> String {
        // NB: "tab" inside the Ghostty tell block is Ghostty's tab class, so define the separator outside.
        run("""
        set sep to (ASCII character 9)
        set nl to (ASCII character 10)
        tell application "Ghostty"
            set out to ""
            repeat with term in terminals
                set out to out & (id of term) & sep & (tty of term) & sep & (pid of term) & sep \
                    & (working directory of term) & sep & (name of term) & nl
            end repeat
            return out
        end tell
        """) ?? run("""
        set sep to (ASCII character 9)
        set nl to (ASCII character 10)
        tell application "Ghostty"
            set out to ""
            repeat with term in terminals
                set out to out & (id of term) & sep & (working directory of term) & sep & (name of term) & nl
            end repeat
            return out
        end tell
        """) ?? ""
    }

    /// The tab a session lives in, and how it was found. Used by both the click and `--focus-plan`.
    static func tab(for s: Session, store: SessionStore, terms: [GhosttyTerminal]) -> (tab: GhosttyTerminal, by: TabMatch)? {
        let title = store.title(sessionId: s.sessionId, cwd: s.cwd)
        guard let hit = GhosttyMatcher.pickMatch(terms, title: title, cwd: s.cwd, busy: GhosttyMatcher.busyHint(for: s.state),
                                                 tty: ProcessTTY.of(s.pid), pid: s.pid),
              let tab = terms.first(where: { $0.id == hit.id }) else { return nil }
        return (tab, hit.by)
    }

    static func focus(_ id: String) {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        _ = run("""
        tell application "Ghostty"
            focus (first terminal whose id is "\(safe)")
            activate
        end tell
        """)
    }

    static func activate() { _ = run("tell application \"Ghostty\" to activate") }

    private static func run(_ src: String) -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { NSLog("Ghostty AppleScript error: \(err)") }
        return r?.stringValue
    }
}
