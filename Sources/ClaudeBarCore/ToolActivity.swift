import Foundation

public struct ToolCall: Equatable {
    public let name: String
    public let summary: String
    public let startedAt: Date?
    /// nil while the tool has no result yet.
    public let finishedAt: Date?
    public var isRunning: Bool { finishedAt == nil }

    public init(name: String, summary: String, startedAt: Date?, finishedAt: Date?) {
        self.name = name; self.summary = summary; self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

public enum ToolActivity {
    /// One-line description of a tool call's input ("npm test", "/path/file.swift", ...).
    public static func summarize(tool: String, input: [String: Any]) -> String {
        func s(_ k: String) -> String? { input[k] as? String }
        let raw: String?
        switch tool {
        case "Bash": raw = s("command")
        case "Read", "Edit", "Write", "MultiEdit": raw = s("file_path")
        case "NotebookEdit": raw = s("notebook_path")
        case "Grep", "Glob": raw = s("pattern")
        case "Task", "Agent": raw = s("description")
        case "WebFetch": raw = s("url")
        case "WebSearch": raw = s("query")
        default: raw = input.keys.sorted().compactMap { s($0) }.first
        }
        let one = (raw ?? "").replacingOccurrences(of: "\n", with: " ")
        return one.count > 120 ? String(one.prefix(120)) + "…" : one
    }

    /// Latest tool call in a transcript tail, and whether its result has arrived.
    /// A call with no result for a long time is a hung tool; a finished call followed by silence is a silent model/API.
    public static func lastCall(inTail data: Data) -> ToolCall? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ o: [String: Any]) -> Date? {
            guard let s = o["timestamp"] as? String else { return nil }
            return iso.date(from: s) ?? plain.date(from: s)
        }

        var id: String?, name = "", summary = ""
        var started: Date?, finished: Date?
        let useMark = Data("\"tool_use\"".utf8), resultMark = Data("\"tool_result\"".utf8)

        for line in data.split(separator: 0x0A) {
            let l = Data(line)
            let hasUse = l.range(of: useMark) != nil
            let hasResult = l.range(of: resultMark) != nil
            guard hasUse || hasResult,
                  let obj = try? JSONSerialization.jsonObject(with: l) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { continue }
            for b in blocks {
                switch b["type"] as? String {
                case "tool_use" where obj["type"] as? String == "assistant":
                    id = b["id"] as? String
                    name = b["name"] as? String ?? "?"
                    summary = summarize(tool: name, input: b["input"] as? [String: Any] ?? [:])
                    started = date(obj); finished = nil
                case "tool_result":
                    if let id, b["tool_use_id"] as? String == id { finished = date(obj) ?? started }
                default: break
                }
            }
        }
        guard id != nil else { return nil }
        return ToolCall(name: name, summary: summary, startedAt: started, finishedAt: finished)
    }

    /// "Bash `npm test` running 14m" / "last tool finished 14m ago (Bash `npm test`), model silent since"
    public static func describe(_ call: ToolCall, now: Date = Date()) -> String {
        func mins(_ d: Date?) -> String {
            guard let d else { return "?" }
            let s = max(0, Int(now.timeIntervalSince(d)))
            return s >= 120 ? "\(s / 60)m" : "\(s)s"
        }
        let what = call.summary.isEmpty ? call.name : "\(call.name) `\(call.summary)`"
        if call.isRunning { return "tool still running \(mins(call.startedAt)): \(what)" }
        return "last tool finished \(mins(call.finishedAt)) ago (\(what)); model silent since"
    }
}
