import XCTest
@testable import ClaudeBarCore

final class TranscriptScanTests: XCTestCase {
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func testLastMessageSkipsMetadataAndMetaEntries() {
        let tail = """
        {"type":"user","timestamp":"2026-11-16T14:20:00.000Z","message":{"content":"hi"}}
        {"type":"assistant","timestamp":"2026-11-16T14:27:30.935Z","message":{"content":[]}}
        {"type":"system","subtype":"away_summary","timestamp":"2026-11-23T08:39:00.000Z"}
        {"type":"user","isMeta":true,"timestamp":"2026-11-23T08:39:01.000Z","message":{"content":"x"}}
        {"type":"mode","mode":"default"}
        {"type":"permission-mode","permissionMode":"auto"}
        """
        XCTAssertEqual(TranscriptScan.lastMessageTime(inTail: Data(tail.utf8)), iso.date(from: "2026-11-16T14:27:30.935Z"))
    }

    func testCutFirstLineAndNoMessages() {
        XCTAssertNil(TranscriptScan.lastMessageTime(inTail: Data(#"ser","timestamp":"2026-11-16T14:20:00.000Z"}"#.utf8)))
        XCTAssertNil(TranscriptScan.lastMessageTime(inTail: Data(#"{"type":"mode"}"#.utf8)))
    }

    func testStoreUsesMessageTimeNotMtime() throws {
        let home = try tempHome()
        let sd = home.appendingPathComponent(".claude/sessions")
        let proj = home.appendingPathComponent(".claude/projects/-x-y")
        try FileManager.default.createDirectory(at: sd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try #"{"pid":1,"sessionId":"s1","cwd":"/x/y","name":"n","status":"idle"}"#
            .write(to: sd.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        let now = Date()
        let old = iso.string(from: now.addingTimeInterval(-3 * 86_400 - 30))
        let t = proj.appendingPathComponent("s1.jsonl")
        // file written just now (fresh mtime), but the last message is 3 days old
        try (#"{"type":"assistant","timestamp":"\#(old)"}"# + "\n" + #"{"type":"mode"}"# + "\n")
            .write(to: t, atomically: true, encoding: .utf8)
        let store = SessionStore(home: home, isAlive: { _ in true })
        let s = try XCTUnwrap(store.load(now: now).first)
        XCTAssertLessThan(s.silentFor, 60)
        XCTAssertEqual(try XCTUnwrap(s.sinceMessage), 3 * 86_400 + 30, accuracy: 1)
        XCTAssertEqual(SessionText.rowTitle(s, hasApproval: false), "n — idle · 3d0h ago")

        // a new message invalidates the cache
        let h = try FileHandle(forWritingTo: t)
        h.seekToEndOfFile()
        h.write(Data((#"{"type":"user","timestamp":"\#(iso.string(from: now.addingTimeInterval(-120)))"}"# + "\n").utf8))
        try h.close()
        XCTAssertEqual(try XCTUnwrap(store.load(now: now).first?.sinceMessage), 120, accuracy: 1)
    }
}
