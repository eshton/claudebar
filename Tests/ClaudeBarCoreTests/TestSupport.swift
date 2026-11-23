import XCTest
@testable import ClaudeBarCore

// Shared builders for the tests.

func tempHome() throws -> URL {
    let h = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: h.appendingPathComponent(".claude/clauderr"), withIntermediateDirectories: true)
    return h
}

func makeSession(pid: Int32 = 1, id: String = "s1", name: String = "alpha", cwd: String = "/p",
                 state: SessionState = .running, silentFor: TimeInterval = 0,
                 sinceMessage: TimeInterval? = nil) -> Session {
    Session(pid: pid, sessionId: id, name: name, cwd: cwd, state: state, silentFor: silentFor, sinceMessage: sinceMessage)
}

func makeUsage(today: Int = 12_300_000, context: Int = 340_000, last: String? = nil) -> SessionUsage {
    var u = SessionUsage()
    u.today.input = today
    u.contextTokens = context
    u.maxContext = context
    u.lastText = last
    return u
}

func makeRequest(id: String = "r1", session: String = "s1", tool: String = "Bash", summary: String = "rm -rf x") -> PermissionRequest {
    PermissionRequest(id: id, hookPid: 1, sessionId: session, toolName: tool, summary: summary, createdAt: Date())
}
