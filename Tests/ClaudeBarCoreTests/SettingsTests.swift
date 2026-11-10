import XCTest
@testable import ClaudeBarCore

final class SettingsTests: XCTestCase {
    func testDefaultsAndForgivingDecode() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"stuckMinutes":3}"#.utf8))
        XCTAssertEqual(s.stuckMinutes, 3)
        XCTAssertTrue(s.notifications); XCTAssertTrue(s.haptics); XCTAssertFalse(s.hideIdle)
        XCTAssertEqual(s.staleAfter, 180)
    }

    func testStuckMinutesNeverBelowOne() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"stuckMinutes":0}"#.utf8))
        XCTAssertEqual(s.stuckMinutes, 1)
    }

    func testRoundTripAndBadFileFallsBack() throws {
        let home = try tempHome()
        let store = SettingsStore(home: home)
        var s = Settings(); s.hideIdle = true; s.setMuted(true, sessionId: "a")
        store.save(s)
        XCTAssertEqual(store.load(), s)
        try "not json".write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), Settings())
    }

    func testMuteTogglePrune() {
        var s = Settings()
        s.setMuted(true, sessionId: "a"); s.setMuted(true, sessionId: "a"); s.setMuted(true, sessionId: "b")
        XCTAssertEqual(s.mutedSessions.sorted(), ["a", "b"])
        s.setMuted(false, sessionId: "a")
        XCTAssertFalse(s.isMuted("a"))
        s.pruneMutes(keeping: ["x"])
        XCTAssertTrue(s.mutedSessions.isEmpty)
    }
}
