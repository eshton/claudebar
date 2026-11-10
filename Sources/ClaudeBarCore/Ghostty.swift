import Foundation

public struct GhosttyTerminal: Equatable {
    public let id: String
    public let cwd: String
    public let name: String
    /// Controlling terminal device ("/dev/ttys005"); empty on Ghostty versions that don't report it.
    public let tty: String
    /// Foreground process of the terminal (the Claude process itself while Claude is in the foreground).
    public let pid: Int32?

    public init(id: String, cwd: String, name: String, tty: String = "", pid: Int32? = nil) {
        self.id = id; self.cwd = cwd; self.name = name; self.tty = tty; self.pid = pid
    }
}

/// How a tab was chosen. `tty` and `pid` are exact; `title` and `folder` are heuristics.
public enum TabMatch: String {
    case tty, pid, title, folder
}

/// The controlling terminal of a process, the key that ties a Claude session to its terminal tab.
public enum ProcessTTY {
    public static func of(_ pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(String(data: data, encoding: .utf8) ?? "")
    }

    /// "ttys005" for a real terminal; nil for "??" (no controlling terminal) or empty output.
    static func parse(_ output: String) -> String? {
        GhosttyMatcher.normalizeTTY(output)
    }
}

public enum GhosttyMatcher {
    /// Ghostty tab titles look like "✳ My title"; Claude prefixes a status glyph.
    public static func stripGlyph(_ name: String) -> String {
        guard let first = name.unicodeScalars.first,
              !CharacterSet.alphanumerics.contains(first),
              let sp = name.firstIndex(of: " ") else { return name }
        return String(name[name.index(after: sp)...])
    }

    /// Claude puts a status glyph in front of the tab title: "✳" when idle, a spinner frame ("◑", ...) while busy.
    /// Plain shell tabs have none.
    static func hasGlyph(_ name: String) -> Bool { stripGlyph(name) != name }
    static func isBusyGlyph(_ name: String) -> Bool { hasGlyph(name) && name.unicodeScalars.first != "\u{2733}" }

    /// "/dev/ttys005" and "ttys005" are the same terminal; "??" and "" mean none.
    static func normalizeTTY(_ raw: String?) -> String? {
        var t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("/dev/") { t.removeFirst(5) }
        return t.isEmpty || t.hasPrefix("?") ? nil : t
    }

    /// Choose the tab of a session.
    ///
    /// 1. Exact: the tab whose tty (or foreground pid) is the session's. Two sessions can share folder, title and
    ///    glyph, but never a tty.
    /// 2. If the session has a tty and Ghostty reports ttys but none is the session's, the session lives in another
    ///    terminal: return nil rather than guess a look-alike tab.
    /// 3. Heuristics for Ghostty versions without tty: exact title, else folder (Claude tabs before plain shells);
    ///    when several tabs remain, `busy` (running vs idle, nil = unknown) picks the one whose glyph agrees.
    public static func pickMatch(_ terms: [GhosttyTerminal], title: String?, cwd: String, busy: Bool? = nil,
                                 tty: String? = nil, pid: Int32? = nil) -> (id: String, by: TabMatch)? {
        let wanted = normalizeTTY(tty)
        if let wanted, let t = terms.first(where: { normalizeTTY($0.tty) == wanted }) { return (t.id, .tty) }
        if let pid, let t = terms.first(where: { $0.pid == pid }) { return (t.id, .pid) }
        if wanted != nil, terms.contains(where: { normalizeTTY($0.tty) != nil }) { return nil }

        var candidates: [GhosttyTerminal] = []
        var by = TabMatch.title
        if let title, !title.isEmpty { candidates = terms.filter { stripGlyph($0.name) == title } }
        if candidates.isEmpty {
            by = .folder
            candidates = terms.filter { $0.cwd == cwd }
            let claudeTabs = candidates.filter { hasGlyph($0.name) }
            if !claudeTabs.isEmpty { candidates = claudeTabs }
        }
        if candidates.count > 1, let busy {
            let agreeing = candidates.filter { isBusyGlyph($0.name) == busy }
            if !agreeing.isEmpty { candidates = agreeing }
        }
        return candidates.first.map { ($0.id, by) }
    }

    public static func pick(_ terms: [GhosttyTerminal], title: String?, cwd: String, busy: Bool? = nil,
                            tty: String? = nil, pid: Int32? = nil) -> String? {
        pickMatch(terms, title: title, cwd: cwd, busy: busy, tty: tty, pid: pid)?.id
    }

    /// Tab glyph tells running from idle; a waiting session's glyph is unknown, so leave it undecided.
    public static func busyHint(for state: SessionState) -> Bool? {
        state == .waiting ? nil : state != .idle
    }

    /// Parses "id<TAB>tty<TAB>pid<TAB>cwd<TAB>name" lines, or the older "id<TAB>cwd<TAB>name".
    public static func parse(_ raw: String) -> [GhosttyTerminal] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            switch p.count {
            case 5: return GhosttyTerminal(id: p[0], cwd: p[3], name: p[4], tty: p[1], pid: Int32(p[2]))
            case 3: return GhosttyTerminal(id: p[0], cwd: p[1], name: p[2])
            default: return nil
            }
        }
    }
}
