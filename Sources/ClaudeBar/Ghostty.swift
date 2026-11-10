import AppKit

/// Thin AppleScript bridge to Ghostty 1.3+ (needs Automation permission on first use).
enum Ghostty {
    static func listTerminals() -> String {
        // NB: "tab" inside the Ghostty tell block is Ghostty's tab class, so define the separator outside.
        run("""
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
