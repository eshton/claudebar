import XCTest
@testable import ClaudeBarCore

final class SessionStoreTests: XCTestCase {
    func testDerive() {
        XCTAssertEqual(SessionState.derive(status: "idle", hasWaitingMarker: false), .idle)
        XCTAssertEqual(SessionState.derive(status: "idle", hasWaitingMarker: true), .idle)
        XCTAssertEqual(SessionState.derive(status: "busy", hasWaitingMarker: false), .running)
        XCTAssertEqual(SessionState.derive(status: "shell", hasWaitingMarker: false), .running)
        XCTAssertEqual(SessionState.derive(status: "busy", hasWaitingMarker: true), .waiting)
    }

    func testLoadSkipsDeadAndMergesMarkers() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sd = home.appendingPathComponent(".claude/sessions")
        let md = home.appendingPathComponent(".claude/clauderr")
        try FileManager.default.createDirectory(at: sd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: md, withIntermediateDirectories: true)
        func w(_ pid: Int, _ id: String, _ st: String) throws {
            try #"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"/x","name":"n\#(pid)","status":"\#(st)"}"#
                .write(to: sd.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        }
        try w(1, "a", "busy"); try w(2, "b", "idle"); try w(3, "c", "busy")
        FileManager.default.createFile(atPath: md.appendingPathComponent("a.waiting").path, contents: nil)
        let store = SessionStore(home: home, isAlive: { $0 != 3 })
        let s = store.load()
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.first?.state, .waiting)
        XCTAssertEqual(SessionStore.aggregate(s), .waiting)
    }

    func testStuckWhenSilent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sd = home.appendingPathComponent(".claude/sessions")
        let proj = home.appendingPathComponent(".claude/projects/-x-y")
        let subs = proj.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: sd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        try #"{"pid":1,"sessionId":"s1","cwd":"/x/y","name":"n","status":"busy","statusUpdatedAt":1000}"#
            .write(to: sd.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)
        let t = proj.appendingPathComponent("s1.jsonl")
        FileManager.default.createFile(atPath: t.path, contents: nil)
        let old = Date().addingTimeInterval(-1200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: t.path)
        let store = SessionStore(home: home, staleAfter: 600, isAlive: { _ in true })
        XCTAssertEqual(store.load().first?.state, .stuck)
        // fresh subagent activity un-sticks it
        FileManager.default.createFile(atPath: subs.appendingPathComponent("agent-1.jsonl").path, contents: nil)
        XCTAssertEqual(store.load().first?.state, .running)
    }
}

final class SessionTitleTests: XCTestCase {
    private func transcript(_ home: URL, dir: String = "-x-y", session: String = "s1", _ text: String) throws {
        let proj = home.appendingPathComponent(".claude/projects/\(dir)")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try text.write(to: proj.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
    }

    func testCustomTitleBeatsAiTitle() throws {
        let home = try tempHome()
        try transcript(home, #"{"customTitle":"My rename"}"# + "\n" + #"{"aiTitle":"Auto title"}"# + "\n")
        XCTAssertEqual(SessionStore(home: home).title(sessionId: "s1", cwd: "/x/y"), "My rename")
    }

    func testLatestTitleWins() throws {
        let home = try tempHome()
        try transcript(home, #"{"aiTitle":"First"}"# + "\n" + #"{"aiTitle":"Second"}"# + "\n")
        XCTAssertEqual(SessionStore(home: home).title(sessionId: "s1", cwd: "/x/y"), "Second")
    }

    func testNoTitleOrNoTranscriptIsNil() throws {
        let home = try tempHome()
        XCTAssertNil(SessionStore(home: home).title(sessionId: "missing", cwd: "/x/y"))
        try transcript(home, #"{"type":"user"}"# + "\n")
        XCTAssertNil(SessionStore(home: home).title(sessionId: "s1", cwd: "/x/y"))
    }

    func testFindsTranscriptWhenFolderSlugDoesNotMatchCwd() throws {
        // e.g. the session was started elsewhere and later cd'ed, or the folder was renamed
        let home = try tempHome()
        try transcript(home, dir: "-some-other-dir", #"{"aiTitle":"Found anyway"}"# + "\n")
        XCTAssertEqual(SessionStore(home: home).title(sessionId: "s1", cwd: "/x/y"), "Found anyway")
    }

    func testOnlyTheTranscriptTailIsRead() throws {
        let home = try tempHome()
        let filler = String(repeating: #"{"type":"user","text":"padding padding padding"}"# + "\n", count: 80_000)   // ~4MB
        try transcript(home, #"{"aiTitle":"Ancient"}"# + "\n" + filler)
        XCTAssertNil(SessionStore(home: home).title(sessionId: "s1", cwd: "/x/y"))
        try transcript(home, #"{"aiTitle":"Ancient"}"# + "\n" + filler + #"{"aiTitle":"Recent"}"# + "\n")
        XCTAssertEqual(SessionStore(home: home).title(sessionId: "s1", cwd: "/x/y"), "Recent")
    }

    func testDefaultLivenessCheckUsesRealProcesses() {
        let store = SessionStore(home: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertTrue(store.isAlive(getpid()))
        XCTAssertFalse(store.isAlive(Int32.max - 1))
    }

    func testAggregateIsWorstState() {
        XCTAssertNil(SessionStore.aggregate([]))
        XCTAssertEqual(SessionStore.aggregate([makeSession(state: .idle), makeSession(state: .stuck)]), .stuck)
    }
}
