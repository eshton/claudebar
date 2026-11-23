import Foundation

public enum SessionState: Int, Comparable {
    case idle = 0, running = 1, waiting = 2, stuck = 3

    public static func < (a: SessionState, b: SessionState) -> Bool { a.rawValue < b.rawValue }

    /// `status` comes from ~/.claude/sessions/<pid>.json (busy / idle / shell).
    /// `hasWaitingMarker` comes from the Notification hook. Claude also fires
    /// Notification when merely idle, so a marker only counts while not idle.
    public static func derive(status: String, hasWaitingMarker: Bool) -> SessionState {
        if status == "waiting" { return .waiting }
        if hasWaitingMarker && status != "idle" { return .waiting }
        switch status {
        case "idle": return .idle
        default: return .running   // busy, shell, unknown-active
        }
    }
}

public struct Session: Equatable {
    public let pid: Int32
    public let sessionId: String
    public let name: String
    public let cwd: String
    public let state: SessionState
    /// Seconds since last sign of life (transcript, subagent transcripts, status change).
    public let silentFor: TimeInterval
    /// Seconds since the last user or assistant message in the transcript; nil when none was found.
    /// Unlike `silentFor` this ignores metadata Claude Code rewrites into old transcripts.
    public let sinceMessage: TimeInterval?
}

struct RawSession: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String?
    let name: String?
    let status: String?
    let statusUpdatedAt: Double?
}
