import Foundation

public enum PermissionVerdict: String {
    case allow, deny
}

public struct PermissionRequest: Equatable, Identifiable {
    public let id: String
    /// pid of the waiting hook script; the request is dead once it exits (e.g. you answered in the terminal).
    public let hookPid: Int32
    public let sessionId: String
    public let toolName: String
    public let summary: String
    public let createdAt: Date
}

/// File-based mailbox between the PermissionRequest hook (hooks/permission.sh) and the app.
/// hook:  writes  permissions/<id>.json   (raw hook payload; id = "<epoch><rand>-<hook pid>")
/// app:   writes  permissions/<id>.decision  ("allow" or "deny")
/// hook:  polls for the decision, prints the hook JSON, removes both files.
public struct PermissionStore {
    public let dir: URL
    public var isAlive: (Int32) -> Bool

    public init(
        home: URL = AppHome.url,
        isAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) {
        dir = home.appendingPathComponent(".claude/clauderr/permissions")
        self.isAlive = isAlive
    }

    public func pending() -> [PermissionRequest] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [PermissionRequest] = []
        for f in files where f.pathExtension == "json" {
            let id = f.deletingPathExtension().lastPathComponent
            guard let pid = id.split(separator: "-").last.flatMap({ Int32($0) }), isAlive(pid),
                  !fm.fileExists(atPath: decisionURL(id).path),
                  let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = obj["session_id"] as? String else { continue }
            let tool = obj["tool_name"] as? String ?? "?"
            let summary = ToolActivity.summarize(tool: tool, input: obj["tool_input"] as? [String: Any] ?? [:])
            let created = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            out.append(PermissionRequest(id: id, hookPid: pid, sessionId: session, toolName: tool,
                                         summary: summary, createdAt: created))
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    public enum DecideError: Error { case badId }

    public func decide(_ id: String, _ verdict: PermissionVerdict) throws {
        guard !id.isEmpty, !id.contains("/"), !id.contains("..") else { throw DecideError.badId }
        let tmp = dir.appendingPathComponent("\(id).decision.tmp")
        try Data(verdict.rawValue.utf8).write(to: tmp)
        // Rename is atomic: the hook never sees a half-written decision.
        _ = try FileManager.default.replaceItemAt(decisionURL(id), withItemAt: tmp)
    }

    /// Remove requests whose hook died and decisions nobody is waiting for.
    public func prune(now: Date = Date()) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            let id = f.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".decision", with: "")
            let req = dir.appendingPathComponent("\(id).json")
            if f.pathExtension == "json" {
                if let pid = id.split(separator: "-").last.flatMap({ Int32($0) }), !isAlive(pid) {
                    try? fm.removeItem(at: f); try? fm.removeItem(at: decisionURL(id))
                }
            } else if !fm.fileExists(atPath: req.path) {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(m) > 30 { try? fm.removeItem(at: f) }
            }
        }
    }

    private func decisionURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).decision") }
}
