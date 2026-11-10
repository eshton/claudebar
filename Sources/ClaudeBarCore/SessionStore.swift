import Foundation

public struct SessionStore {
    public let sessionsDir: URL
    public let markerDir: URL
    public let projectsDir: URL
    /// A busy/shell session with no activity for this long is "stuck".
    public var staleAfter: TimeInterval
    public var isAlive: (Int32) -> Bool

    public init(
        home: URL = AppHome.url,
        staleAfter: TimeInterval = 600,
        isAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) {
        self.staleAfter = staleAfter
        projectsDir = home.appendingPathComponent(".claude/projects")
        sessionsDir = home.appendingPathComponent(".claude/sessions")
        markerDir = home.appendingPathComponent(".claude/clauderr")
        self.isAlive = isAlive
    }

    public func load(now: Date = Date()) -> [Session] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        var out: [Session] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let raw = try? dec.decode(RawSession.self, from: data),
                  isAlive(raw.pid) else { continue }
            let marker = markerDir.appendingPathComponent("\(raw.sessionId).waiting").path
            var state = SessionState.derive(
                status: raw.status ?? "idle",
                hasWaitingMarker: fm.fileExists(atPath: marker))
            let last = lastActivity(raw)
            let silent = max(0, now.timeIntervalSince(last))
            if state == .running && silent > staleAfter { state = .stuck }
            out.append(Session(pid: raw.pid, sessionId: raw.sessionId,
                               name: raw.name ?? raw.sessionId, cwd: raw.cwd ?? "",
                               state: state, silentFor: silent))
        }
        // waiting first, then running, then idle; stable by name
        return out.sorted { ($0.state, $1.name) > ($1.state, $0.name) }
    }

    /// Newest of: status change time, session transcript mtime, subagent transcript mtimes.
    func lastActivity(_ raw: RawSession) -> Date {
        let fm = FileManager.default
        var newest = Date(timeIntervalSince1970: (raw.statusUpdatedAt ?? 0) / 1000)
        func bump(_ u: URL) {
            if let m = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date, m > newest { newest = m }
        }
        guard let project = projectDir(for: raw) else { return newest }
        bump(project.appendingPathComponent("\(raw.sessionId).jsonl"))
        let subs = project.appendingPathComponent("\(raw.sessionId)/subagents")
        for f in (try? fm.contentsOfDirectory(at: subs, includingPropertiesForKeys: nil)) ?? [] { bump(f) }
        return newest
    }

    /// ~/.claude/projects/<cwd with non-alphanumerics -> '-'>; falls back to scanning for the session file.
    func projectDir(for raw: RawSession) -> URL? {
        let fm = FileManager.default
        if let cwd = raw.cwd {
            let slug = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let d = projectsDir.appendingPathComponent(slug)
            if fm.fileExists(atPath: d.appendingPathComponent("\(raw.sessionId).jsonl").path) { return d }
        }
        for d in (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? [] {
            if fm.fileExists(atPath: d.appendingPathComponent("\(raw.sessionId).jsonl").path) { return d }
        }
        return nil
    }

    /// Current conversation title (user /rename wins over auto title), read from the transcript tail.
    public func title(sessionId: String, cwd: String) -> String? {
        guard let data = readTail(sessionId: sessionId, cwd: cwd, window: 2_000_000),
              let text = String(data: data, encoding: .utf8) else { return nil }
        func last(_ key: String) -> String? {
            guard let r = text.range(of: "\"\(key)\":\"", options: .backwards) else { return nil }
            let rest = text[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        return last("customTitle") ?? last("aiTitle")
    }

    /// Last bytes of the session transcript (may start mid-line; callers tolerate that).
    func readTail(sessionId: String, cwd: String, window: UInt64) -> Data? {
        let raw = RawSession(pid: 0, sessionId: sessionId, cwd: cwd, name: nil, status: nil, statusUpdatedAt: nil)
        guard let dir = projectDir(for: raw),
              let h = try? FileHandle(forReadingFrom: dir.appendingPathComponent("\(sessionId).jsonl")) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > window ? size - window : 0)
        return try? h.readToEnd()
    }

    /// Most recent tool call of a session and whether it finished. Used to diagnose "stuck".
    public func lastToolCall(sessionId: String, cwd: String) -> ToolCall? {
        guard let data = readTail(sessionId: sessionId, cwd: cwd, window: 1_000_000) else { return nil }
        return ToolActivity.lastCall(inTail: data)
    }

    public static func aggregate(_ s: [Session]) -> SessionState? {
        s.map(\.state).max()
    }
}
