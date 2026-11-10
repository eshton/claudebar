import Foundation

/// Every user-visible string about a session (tooltips, menu lines, banners) in one pure, testable place.
public enum SessionText {
    public static func label(_ state: SessionState) -> String {
        switch state {
        case .stuck: return "stuck"
        case .waiting: return "waiting"
        case .running: return "running"
        case .idle: return "idle"
        }
    }

    /// First `n` characters on one line, with an ellipsis when cut.
    public static func snippet(_ text: String, _ n: Int) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    /// Stuck and running sessions show how long they have been silent.
    public static func quiet(_ s: Session) -> String {
        (s.state == .stuck || s.state == .running) ? " (no activity \(Int(s.silentFor / 60))m)" : ""
    }

    /// "Today 12.3M · context 340k/1.0M (34%)"
    public static func usageSummary(_ u: SessionUsage) -> String {
        "Today \(Fmt.millions(u.today.total)) · context \(Fmt.compact(u.contextTokens))/\(Fmt.compact(u.contextWindow))"
            + " (\(Int(u.contextFraction * 100))%)"
    }

    /// "Context: 340k / 1.0M (34%)"
    public static func contextLine(_ u: SessionUsage) -> String {
        "Context: \(Fmt.compact(u.contextTokens)) / \(Fmt.compact(u.contextWindow)) (\(Int(u.contextFraction * 100))%)"
    }

    /// Hover text of a per-session icon.
    public static func tooltip(for s: Session, usage: SessionUsage?, pending: [PermissionRequest],
                               muted: Bool, diagnosis: String?) -> String {
        var t = "\(s.name) — \(label(s.state))\(quiet(s))\(muted ? " · muted" : "")\n\(s.cwd)"
        if let u = usage {
            t += "\n" + usageSummary(u)
            if let last = u.lastText { t += "\nLast: " + snippet(last, 200) }
        }
        for r in pending where r.sessionId == s.sessionId {
            t += "\nApproval needed: \(r.toolName) \(snippet(r.summary, 80))"
        }
        if s.state == .stuck, let d = diagnosis { t += "\nDiagnosis: " + d }
        return t + "\n(click: focus in Ghostty · right-click: menu)"
    }

    /// Worst state first, then by name.
    public static func listOrder(_ sessions: [Session]) -> [Session] {
        sessions.sorted { ($0.state, $1.name) > ($1.state, $0.name) }
    }

    /// "name — running · approval needed"
    public static func rowTitle(_ s: Session, hasApproval: Bool) -> String {
        "\(s.name) — \(label(s.state))\(hasApproval ? " · approval needed" : "")"
    }

    /// Hover text of the single combined icon: one bullet per session.
    public static func singleTooltip(_ sessions: [Session], pending: [PermissionRequest], mutedIds: Set<String>) -> String {
        let rows = listOrder(sessions).map { s -> String in
            let ask = pending.contains { $0.sessionId == s.sessionId }
            return "• " + rowTitle(s, hasApproval: ask) + (mutedIds.contains(s.sessionId) ? " · muted" : "")
        }
        return rows.joined(separator: "\n") + "\n(click: focus / list · right-click: list)"
    }

    /// Lines at the top of a session's menu.
    public static func menuLines(for s: Session, usage: SessionUsage?, diagnosis: String?) -> [String] {
        var lines = [s.name, "State: \(label(s.state))", s.cwd]
        if let u = usage {
            lines.append("Today: \(Fmt.millions(u.today.total)) tokens")
            lines.append(contextLine(u))
            if let last = u.lastText { lines.append("Last: " + snippet(last, 70)) }
        }
        if s.state == .running || s.state == .stuck, let d = diagnosis, let first = d.first {
            lines.append(snippet(first.uppercased() + d.dropFirst(), 90))
        }
        return lines
    }

    /// The bolt menu's breakdown.
    public static func tokenLines(_ t: TokenBreakdown) -> [String] {
        ["Today: \(Fmt.millions(t.total)) tokens"]
            + [("Input", t.input), ("Output", t.output), ("Cache write", t.cacheWrite), ("Cache read", t.cacheRead)]
                .map { "    \($0.0): \(Fmt.millions($0.1))" }
    }

    /// "name: 4.20M · ctx 34%"
    public static func tokenRow(_ s: Session, usage: SessionUsage?) -> String {
        let ctx = usage.map { " · ctx \(Int($0.contextFraction * 100))%" } ?? ""
        return "\(s.name): \(Fmt.millions(usage?.today.total ?? 0))\(ctx)"
    }

    public static func bannerText(_ alert: Alert, session s: Session, request: PermissionRequest?,
                                  usage: SessionUsage?, diagnosis: String?) -> (title: String, body: String) {
        switch alert {
        case .needsInput:
            let body = request.map { "\($0.toolName): \(snippet($0.summary, 120))" }
                ?? usage?.lastText.map { snippet($0, 140) } ?? "Waiting for your input"
            return ("\(s.name) needs you", body)
        case .stuck:
            return ("\(s.name) looks stuck", diagnosis ?? "No activity for \(Int(s.silentFor / 60)) min")
        case .finished:
            return ("\(s.name) finished", usage?.lastText.map { snippet($0, 140) } ?? "Done")
        }
    }

    public static func permissionBanner(_ r: PermissionRequest, sessionName: String?) -> (title: String, body: String) {
        ("\(sessionName ?? "Claude"): approve \(r.toolName)?", snippet(r.summary, 160))
    }
}
