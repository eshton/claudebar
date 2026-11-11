import XCTest
@testable import ClaudeBarCore

final class SessionTrackerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1000)

    func testAlertsOnlyOnChange() {
        var t = SessionTracker()
        var a = t.update([makeSession(state: .running)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        XCTAssertTrue(a.isEmpty)
        a = t.update([makeSession(state: .waiting)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        XCTAssertEqual(a.map(\.alert), [.needsInput])
        a = t.update([makeSession(state: .waiting)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        XCTAssertTrue(a.isEmpty)       // same state again: nothing new
    }

    func testMutedSessionsStaySilentButStillTracked() {
        var t = SessionTracker()
        _ = t.update([makeSession(state: .running)], now: now, blinkSeconds: 15, isMuted: { _ in true })
        let a = t.update([makeSession(state: .stuck)], now: now, blinkSeconds: 15, isMuted: { _ in true })
        XCTAssertTrue(a.isEmpty)
        XCTAssertEqual(t.lastState[1], .stuck)
    }

    func testFinishStartsBlinkUntilDeadline() {
        var t = SessionTracker()
        _ = t.update([makeSession(state: .running)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        let a = t.update([makeSession(state: .idle)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        XCTAssertEqual(a.map(\.alert), [.finished])
        XCTAssertTrue(t.isFinishing(1, now: now.addingTimeInterval(14)))
        XCTAssertFalse(t.isFinishing(1, now: now.addingTimeInterval(16)))
        XCTAssertTrue(t.hasFinishing)
        t.expire(now: now.addingTimeInterval(16))
        XCTAssertFalse(t.hasFinishing)
    }

    func testSessionFirstSeenIdleDoesNotBlink() {
        var t = SessionTracker()
        _ = t.update([makeSession(state: .idle)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        XCTAssertFalse(t.hasFinishing)
    }

    func testResumingWorkCancelsBlinkAndAcknowledgeStopsIt() {
        var t = SessionTracker()
        _ = t.update([makeSession(state: .running)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        _ = t.update([makeSession(state: .idle)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        _ = t.update([makeSession(state: .running)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        XCTAssertFalse(t.hasFinishing)
        _ = t.update([makeSession(state: .idle)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        t.acknowledge(1)
        XCTAssertFalse(t.isFinishing(1, now: now))
    }

    func testDeadSessionsAreForgotten() {
        var t = SessionTracker()
        _ = t.update([makeSession(pid: 1, state: .running), makeSession(pid: 2, state: .running)],
                     now: now, blinkSeconds: 15, isMuted: { _ in false })
        _ = t.update([makeSession(pid: 2, state: .running)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        XCTAssertNil(t.lastState[1]); XCTAssertNotNil(t.lastState[2])
    }

    func testLatestFinish() {
        var t = SessionTracker()
        let list = [makeSession(pid: 1, id: "a", state: .running), makeSession(pid: 2, id: "b", state: .running)]
        _ = t.update(list, now: now, blinkSeconds: 5, isMuted: { _ in false })
        _ = t.update([makeSession(pid: 1, id: "a", state: .idle), makeSession(pid: 2, id: "b", state: .running)],
                     now: now, blinkSeconds: 5, isMuted: { _ in false })
        XCTAssertEqual(t.latestFinish(of: [1, 2]), now.addingTimeInterval(5))
        XCTAssertNil(t.latestFinish(of: [2]))
    }

    func testVisibleHonoursHideIdleFinishAndApprovals() {
        var t = SessionTracker()
        let list = [makeSession(pid: 1, id: "a", state: .idle), makeSession(pid: 2, id: "b", state: .idle),
                    makeSession(pid: 3, id: "c", state: .running)]
        _ = t.update([makeSession(pid: 1, id: "a", state: .running)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        _ = t.update(list, now: now, blinkSeconds: 15, isMuted: { _ in false })     // pid 1 just finished
        let v = t.visible(list, hideIdle: true, pendingSessionIds: ["b"], now: now)
        XCTAssertEqual(v.map(\.pid), [1, 2, 3])
        XCTAssertEqual(t.visible(list, hideIdle: true, pendingSessionIds: [], now: now.addingTimeInterval(60)).map(\.pid), [3])
        XCTAssertEqual(t.visible(list, hideIdle: false, pendingSessionIds: [], now: now).count, 3)
    }
}

final class LingerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1000)

    /// A session that just finished and is blinking.
    private func finished() -> SessionTracker {
        var t = SessionTracker()
        _ = t.update([makeSession(state: .running)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        _ = t.update([makeSession(state: .idle)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        return t
    }

    func testClickingAFinishedSessionStopsTheBlinkButKeepsItForTwoMinutes() {
        var t = finished()
        let click = now.addingTimeInterval(5)
        t.acknowledge(1, now: click, lingerSeconds: 120)
        XCTAssertFalse(t.isFinishing(1, now: click))                                  // blinking stopped
        XCTAssertTrue(t.isLingering(1, now: click.addingTimeInterval(119)))
        XCTAssertFalse(t.isLingering(1, now: click.addingTimeInterval(121)))
    }

    func testHiddenIdleSessionStaysVisibleWhileLingering() {
        var t = finished()
        let list = [makeSession(state: .idle)]
        t.acknowledge(1, now: now, lingerSeconds: 120)
        XCTAssertEqual(t.visible(list, hideIdle: true, pendingSessionIds: [], now: now.addingTimeInterval(100)).count, 1)
        XCTAssertEqual(t.visible(list, hideIdle: true, pendingSessionIds: [], now: now.addingTimeInterval(121)).count, 0)
    }

    func testClickWithoutAFinishDoesNotLinger() {
        var t = SessionTracker()
        _ = t.update([makeSession(state: .idle)], now: now, blinkSeconds: 15, isMuted: { _ in false })
        t.acknowledge(1, now: now, lingerSeconds: 120)
        XCTAssertFalse(t.isLingering(1, now: now))
    }

    func testClickAfterTheBlinkEndedDoesNotLinger() {
        var t = finished()
        t.acknowledge(1, now: now.addingTimeInterval(60), lingerSeconds: 120)        // blink (15s) is long over
        XCTAssertFalse(t.isLingering(1, now: now.addingTimeInterval(60)))
    }

    func testZeroSecondsMeansGoneAtOnce() {
        var t = finished()
        t.acknowledge(1, now: now, lingerSeconds: 0)
        XCTAssertFalse(t.isLingering(1, now: now))
        XCTAssertFalse(t.isFinishing(1, now: now))
    }

    func testResumingWorkEndsTheLinger() {
        var t = finished()
        t.acknowledge(1, now: now, lingerSeconds: 120)
        _ = t.update([makeSession(state: .running)], now: now.addingTimeInterval(10), blinkSeconds: 15, isMuted: { _ in false })
        XCTAssertFalse(t.isLingering(1, now: now.addingTimeInterval(10)))
    }

    func testDeadSessionsAndExpiryClearIt() {
        var t = finished()
        t.acknowledge(1, now: now, lingerSeconds: 120)
        XCTAssertEqual(t.latestLinger(of: [1]), now.addingTimeInterval(120))
        t.expire(now: now.addingTimeInterval(121))
        XCTAssertNil(t.latestLinger(of: [1]))
        t.acknowledge(1, now: now, lingerSeconds: 120)
        _ = t.update([], now: now, blinkSeconds: 15, isMuted: { _ in false })       // session ended
        XCTAssertNil(t.lingerUntil[1])
    }
}

final class PermissionAnnouncementsTests: XCTestCase {
    func testAnnouncesOnceAndReportsGone() {
        var a = PermissionAnnouncements()
        var r = a.update([makeRequest(id: "1"), makeRequest(id: "2")])
        XCTAssertEqual(r.new.map(\.id), ["1", "2"]); XCTAssertTrue(r.gone.isEmpty)
        r = a.update([makeRequest(id: "2"), makeRequest(id: "3")])
        XCTAssertEqual(r.new.map(\.id), ["3"]); XCTAssertEqual(r.gone, ["1"])
        r = a.update([])
        XCTAssertTrue(r.new.isEmpty); XCTAssertEqual(r.gone, ["2", "3"])
    }

    func testReappearingIdIsNewAgain() {
        var a = PermissionAnnouncements()
        _ = a.update([makeRequest(id: "1")]); _ = a.update([])
        XCTAssertEqual(a.update([makeRequest(id: "1")]).new.map(\.id), ["1"])
    }
}
