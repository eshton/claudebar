import Foundation

public enum TranscriptScan {
    /// Timestamp of the newest user or assistant entry in a transcript tail. Skips `isMeta` entries and the
    /// metadata lines (mode, permission-mode, ...) that Claude Code appends to old transcripts on startup.
    public static func lastMessageTime(inTail data: Data) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let userMark = Data("\"type\":\"user\"".utf8), assistantMark = Data("\"type\":\"assistant\"".utf8)
        for line in data.split(separator: 0x0A).reversed() {
            let l = Data(line)
            guard l.range(of: userMark) != nil || l.range(of: assistantMark) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: l) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  obj["isMeta"] as? Bool != true,
                  let ts = obj["timestamp"] as? String,
                  let date = iso.date(from: ts) ?? plain.date(from: ts) else { continue }
            return date
        }
        return nil
    }
}

/// Last-message time per transcript path, valid while the file's size and mtime are unchanged.
final class MessageTimeCache {
    struct Key: Equatable { let size: UInt64; let mtime: Date }
    private var entries: [String: (key: Key, date: Date?)] = [:]
    private let lock = NSLock()

    /// Outer nil: miss. Inner nil: the transcript has no message.
    func get(_ path: String, _ key: Key) -> Date?? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[path], e.key == key else { return nil }
        return .some(e.date)
    }

    func set(_ path: String, _ key: Key, _ date: Date?) {
        lock.lock(); defer { lock.unlock() }
        entries[path] = (key, date)
    }
}
