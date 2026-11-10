import Foundation

public struct GhosttyTerminal: Equatable {
    public let id: String
    public let cwd: String
    public let name: String
    public init(id: String, cwd: String, name: String) { self.id = id; self.cwd = cwd; self.name = name }
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

    /// Exact title match wins, else the tabs in the session's working directory (Claude tabs before plain shells).
    /// Sessions can share both folder and title (two PR reviews of one repo), so when several tabs match,
    /// `busy` (running vs idle; nil = unknown) picks the tab whose glyph agrees with the session's state.
    public static func pick(_ terms: [GhosttyTerminal], title: String?, cwd: String, busy: Bool? = nil) -> String? {
        var candidates: [GhosttyTerminal] = []
        if let title, !title.isEmpty { candidates = terms.filter { stripGlyph($0.name) == title } }
        if candidates.isEmpty {
            candidates = terms.filter { $0.cwd == cwd }
            let claudeTabs = candidates.filter { hasGlyph($0.name) }
            if !claudeTabs.isEmpty { candidates = claudeTabs }
        }
        if candidates.count > 1, let busy {
            let agreeing = candidates.filter { isBusyGlyph($0.name) == busy }
            if !agreeing.isEmpty { candidates = agreeing }
        }
        return candidates.first?.id
    }

    /// Tab glyph tells running from idle; a waiting session's glyph is unknown, so leave it undecided.
    public static func busyHint(for state: SessionState) -> Bool? {
        state == .waiting ? nil : state != .idle
    }

    /// Parses lines of "id<TAB>cwd<TAB>name".
    public static func parse(_ raw: String) -> [GhosttyTerminal] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard p.count == 3 else { return nil }
            return GhosttyTerminal(id: String(p[0]), cwd: String(p[1]), name: String(p[2]))
        }
    }
}
