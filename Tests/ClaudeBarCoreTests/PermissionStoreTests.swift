import XCTest
@testable import ClaudeBarCore

final class PermissionStoreTests: XCTestCase {
    private func setup(alive: @escaping (Int32) -> Bool = { _ in true }) throws -> PermissionStore {
        let store = PermissionStore(home: try tempHome(), isAlive: alive)
        try FileManager.default.createDirectory(at: store.dir, withIntermediateDirectories: true)
        return store
    }
    private func request(_ store: PermissionStore, id: String, session: String = "s1") throws {
        try #"{"session_id":"\#(session)","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
            .write(to: store.dir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
    }

    func testPendingParsesRequest() throws {
        let store = try setup()
        try request(store, id: "1700000000123-4242")
        let p = store.pending()
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].sessionId, "s1"); XCTAssertEqual(p[0].toolName, "Bash")
        XCTAssertEqual(p[0].summary, "rm -rf build"); XCTAssertEqual(p[0].hookPid, 4242)
    }

    func testDeadHookAndDecidedAreNotPending() throws {
        let store = try setup(alive: { $0 != 1 })
        try request(store, id: "a-1")          // hook gone (answered in terminal)
        try request(store, id: "b-2")
        try store.decide("b-2", .allow)
        XCTAssertTrue(store.pending().isEmpty)
        let d = try String(contentsOf: store.dir.appendingPathComponent("b-2.decision"), encoding: .utf8)
        XCTAssertEqual(d, "allow")
    }

    func testDecideRejectsPathTricks() throws {
        let store = try setup()
        XCTAssertThrowsError(try store.decide("../x", .deny))
        XCTAssertThrowsError(try store.decide("a/b", .deny))
        XCTAssertThrowsError(try store.decide("", .deny))
    }

    func testDecideOverwritesNeverLeavesTmp() throws {
        let store = try setup()
        try request(store, id: "c-3")
        try store.decide("c-3", .deny)
        try store.decide("c-3", .allow)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.dir.path).sorted()
        XCTAssertEqual(names, ["c-3.decision", "c-3.json"])
    }

    func testPruneRemovesDeadRequests() throws {
        let store = try setup(alive: { $0 != 1 })
        try request(store, id: "a-1")
        try store.decide("a-1", .allow)
        store.prune()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.dir.path).isEmpty)
    }
}

final class PermissionPruneTests: XCTestCase {
    private func store() throws -> PermissionStore {
        let s = PermissionStore(home: try tempHome())
        try FileManager.default.createDirectory(at: s.dir, withIntermediateDirectories: true)
        return s
    }

    private func age(_ url: URL, seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    func testOrphanDecisionIsKeptBrieflyThenRemoved() throws {
        let s = try store()
        let orphan = s.dir.appendingPathComponent("ghost-1.decision")
        try "allow".write(to: orphan, atomically: true, encoding: .utf8)
        s.prune()                                          // fresh: the hook may simply not have picked it up yet
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        try age(orphan, seconds: 120)
        s.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testLiveRequestsSurvivePrune() throws {
        let s = try store()
        let req = s.dir.appendingPathComponent("a-\(getpid()).json")
        try #"{"session_id":"s1","tool_name":"Bash","tool_input":{}}"#.write(to: req, atomically: true, encoding: .utf8)
        s.prune()
        XCTAssertTrue(FileManager.default.fileExists(atPath: req.path))
        XCTAssertEqual(s.pending().count, 1)             // default liveness check sees this very process
    }

    func testMalformedRequestsAreIgnored() throws {
        let s = try store()
        try "not json".write(to: s.dir.appendingPathComponent("a-\(getpid()).json"), atomically: true, encoding: .utf8)
        try #"{"tool_name":"Bash"}"#.write(to: s.dir.appendingPathComponent("b-\(getpid()).json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(s.pending().isEmpty)               // second one has no session_id
    }

    func testMissingDirectoryIsEmpty() {
        XCTAssertTrue(PermissionStore(home: URL(fileURLWithPath: "/nonexistent")).pending().isEmpty)
    }
}
