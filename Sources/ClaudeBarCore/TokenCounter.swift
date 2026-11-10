import Foundation

public struct TokenBreakdown: Equatable {
    public var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    public var total: Int { input + output + cacheWrite + cacheRead }
    public init() {}
    static func - (a: TokenBreakdown, b: TokenBreakdown) -> TokenBreakdown {
        var r = TokenBreakdown()
        r.input = a.input - b.input; r.output = a.output - b.output
        r.cacheWrite = a.cacheWrite - b.cacheWrite; r.cacheRead = a.cacheRead - b.cacheRead
        return r
    }
    mutating func add(_ o: TokenBreakdown) {
        input += o.input; output += o.output; cacheWrite += o.cacheWrite; cacheRead += o.cacheRead
    }
}

public struct SessionUsage {
    public var today = TokenBreakdown()
    /// Prompt size of the latest main-thread assistant message (input + cache read + cache write).
    public var contextTokens = 0
    var maxContext = 0
    public var lastText: String?
    /// Estimate: transcripts don't record the window size. Anything seen above 200k implies the 1M window.
    public var contextWindow: Int { maxContext > 200_000 ? 1_000_000 : 200_000 }
    public var contextFraction: Double { min(1, Double(contextTokens) / Double(contextWindow)) }
    public init() {}
}

public struct UsageSnapshot {
    public var total = TokenBreakdown()
    public var perSession: [String: SessionUsage] = [:]
    public init() {}
}

public enum Fmt {
    /// Menu bar style: 0.47M / 5.60M / 23.6M / 236M
    public static func millions(_ n: Int) -> String {
        let m = Double(n) / 1e6
        return m >= 100 ? String(format: "%.0fM", m) : m >= 10 ? String(format: "%.1fM", m) : String(format: "%.2fM", m)
    }
    /// 812 / 340k / 1.2M
    public static func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

/// Incrementally scans ~/.claude/projects transcripts (incl. subagents) for today's token usage.
public final class TokenCounter {
    private let projectsDir: URL
    private let lock = NSLock()
    private var offsets: [String: UInt64] = [:]
    /// Last usage seen per streamed message, so growing re-writes of the same message only count their delta.
    private struct CountedMessage { let session: String; let usage: TokenBreakdown; let today: Bool }
    private var counted: [String: CountedMessage] = [:]
    private var snap = UsageSnapshot()
    private var dayStart = Date.distantPast
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private let isoPlain = ISO8601DateFormatter()

    private func parseDate(_ s: String) -> Date {
        iso.date(from: s) ?? isoPlain.date(from: s) ?? .distantPast
    }

    public init(home: URL = AppHome.url) {
        projectsDir = home.appendingPathComponent(".claude/projects")
    }

    public var snapshot: UsageSnapshot { lock.lock(); defer { lock.unlock() }; return snap }

    /// `liveSessionIds`: transcripts of running sessions are read even if untouched today (for context % / last message).
    @discardableResult
    public func scan(liveSessionIds: Set<String>, now: Date = Date()) -> UsageSnapshot {
        lock.lock(); defer { lock.unlock() }
        let start = Calendar.current.startOfDay(for: now)
        if start != dayStart {           // new day: recount from scratch
            dayStart = start; offsets = [:]; counted = [:]; snap = UsageSnapshot()
        }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        for proj in (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: keys)) ?? [] {
            for e in (try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: keys)) ?? [] where e.pathExtension == "jsonl" {
                let id = e.deletingPathExtension().lastPathComponent
                let m = (try? e.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                guard m >= start || liveSessionIds.contains(id) else { continue }
                process(e, session: id, isMain: true)
                let subs = proj.appendingPathComponent("\(id)/subagents")
                for f in (try? fm.contentsOfDirectory(at: subs, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "jsonl" {
                    process(f, session: id, isMain: false)
                }
            }
        }
        return snap
    }

    private func process(_ url: URL, session: String, isMain: Bool) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 else { return }
        var off = offsets[url.path] ?? 0
        if size < off { off = 0 }
        guard size > off, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: off)
        guard let data = try? h.readToEnd(), let lastNL = data.lastIndex(of: 0x0A) else { return }
        offsets[url.path] = off + UInt64(lastNL + 1)
        for line in data[..<lastNL].split(separator: 0x0A) {
            handle(Data(line), session: session, isMain: isMain)
        }
    }

    private func handle(_ line: Data, session: String, isMain: Bool) {
        // cheap prefilter before JSON parsing
        guard line.range(of: Data("\"type\":\"assistant\"".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              msg["model"] as? String != "<synthetic>" else { return }

        let sidechain = obj["isSidechain"] as? Bool ?? false
        var u = snap.perSession[session] ?? SessionUsage()

        if let usage = msg["usage"] as? [String: Any] {
            var b = TokenBreakdown()
            b.input = usage["input_tokens"] as? Int ?? 0
            b.output = usage["output_tokens"] as? Int ?? 0
            b.cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            b.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

            let ts = (obj["timestamp"] as? String).map(parseDate) ?? .distantPast
            let isToday = ts >= dayStart
            // Streaming writes the same message several times with growing output_tokens: keep the latest, count the delta.
            let key = "\(msg["id"] as? String ?? UUID().uuidString)|\(obj["requestId"] as? String ?? "")"
            let prev = counted[key]?.usage ?? TokenBreakdown()
            if isToday {
                let d = b - prev
                snap.total.add(d); u.today.add(d)
            }
            counted[key] = CountedMessage(session: session, usage: b, today: isToday)

            if isMain && !sidechain {
                u.contextTokens = b.input + b.cacheRead + b.cacheWrite
                u.maxContext = max(u.maxContext, u.contextTokens)
            }
        }
        if isMain && !sidechain, let blocks = msg["content"] as? [[String: Any]] {
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { u.lastText = t }
        }
        snap.perSession[session] = u
    }
}
