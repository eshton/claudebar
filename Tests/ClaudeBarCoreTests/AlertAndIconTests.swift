import XCTest
@testable import ClaudeBarCore

final class AlertTests: XCTestCase {
    func testTransitions() {
        XCTAssertEqual(AlertPolicy.alert(from: .running, to: .waiting, muted: false), .needsInput)
        XCTAssertEqual(AlertPolicy.alert(from: nil, to: .waiting, muted: false), .needsInput)
        XCTAssertEqual(AlertPolicy.alert(from: .running, to: .stuck, muted: false), .stuck)
        XCTAssertEqual(AlertPolicy.alert(from: .running, to: .idle, muted: false), .finished)
        XCTAssertNil(AlertPolicy.alert(from: nil, to: .idle, muted: false))       // first sight of an idle session
        XCTAssertNil(AlertPolicy.alert(from: .idle, to: .running, muted: false))
        XCTAssertNil(AlertPolicy.alert(from: .waiting, to: .waiting, muted: false))
    }

    func testMutedSuppressesEverything() {
        for to in [SessionState.waiting, .stuck, .idle] {
            XCTAssertNil(AlertPolicy.alert(from: .running, to: to, muted: true))
        }
    }

    func testDeliveryFollowsSettings() {
        var s = Settings()
        XCTAssertEqual(AlertPolicy.delivery(for: .stuck, settings: s),
                       AlertDelivery(sound: true, haptic: "angry_alert", banner: true))
        XCTAssertEqual(AlertPolicy.delivery(for: .finished, settings: s),
                       AlertDelivery(sound: false, haptic: "completed", banner: false))   // notifyOnFinish off
        s.notifyOnFinish = true; s.haptics = false; s.sound = false; s.notifications = false
        XCTAssertEqual(AlertPolicy.delivery(for: .finished, settings: s), AlertDelivery(sound: false, haptic: nil, banner: false))
        XCTAssertEqual(AlertPolicy.delivery(for: .needsInput, settings: s), AlertDelivery(sound: false, haptic: nil, banner: false))
    }
}

final class IconModelTests: XCTestCase {
    func testKind() {
        let now = Date()
        XCTAssertEqual(IconModel.kind(state: .waiting, finishedUntil: nil, tick: 0, now: now), .waiting)
        XCTAssertEqual(IconModel.kind(state: .idle, finishedUntil: now.addingTimeInterval(3), tick: 0, now: now), .finishedFilled)
        XCTAssertEqual(IconModel.kind(state: .idle, finishedUntil: now.addingTimeInterval(3), tick: 1, now: now), .finishedOutline)
        XCTAssertEqual(IconModel.kind(state: .idle, finishedUntil: now.addingTimeInterval(-1), tick: 0, now: now), .idle)
        XCTAssertEqual(IconModel.kind(state: .running, finishedUntil: now.addingTimeInterval(3), tick: 0, now: now), .running)
    }

    func testContextLevel() {
        XCTAssertEqual(IconModel.contextLevel(0.59), .ok)
        XCTAssertEqual(IconModel.contextLevel(0.60), .warn)
        XCTAssertEqual(IconModel.contextLevel(0.85), .critical)
    }

    func testVisibility() {
        XCTAssertTrue(IconModel.isVisible(state: .idle, hideIdle: false, finishing: false, hasPendingPermission: false))
        XCTAssertFalse(IconModel.isVisible(state: .idle, hideIdle: true, finishing: false, hasPendingPermission: false))
        XCTAssertTrue(IconModel.isVisible(state: .idle, hideIdle: true, finishing: true, hasPendingPermission: false))
        XCTAssertTrue(IconModel.isVisible(state: .idle, hideIdle: true, finishing: false, hasPendingPermission: true))
        XCTAssertTrue(IconModel.isVisible(state: .running, hideIdle: true, finishing: false, hasPendingPermission: false))
    }
}

final class SingleIconTests: XCTestCase {
    func testWorstStateWinsWithBadge() {
        let now = Date()
        let s = IconModel.summary(states: [.idle, .running, .waiting, .waiting], finishedUntil: nil, tick: 0, now: now)
        XCTAssertEqual(s, IconSummary(kind: .waiting, badge: 2))
        XCTAssertEqual(IconModel.summary(states: [.running, .idle], finishedUntil: nil, tick: 0, now: now),
                       IconSummary(kind: .running, badge: nil))
        XCTAssertEqual(IconModel.summary(states: [.stuck, .waiting], finishedUntil: nil, tick: 0, now: now)?.kind, .stuck)
    }

    func testIdleHasNoBadgeAndFinishBlinks() {
        let now = Date()
        XCTAssertEqual(IconModel.summary(states: [.idle, .idle], finishedUntil: nil, tick: 0, now: now),
                       IconSummary(kind: .idle, badge: nil))
        XCTAssertEqual(IconModel.summary(states: [.idle], finishedUntil: now.addingTimeInterval(3), tick: 1, now: now)?.kind,
                       .finishedOutline)
    }

    func testNoSessionsNoSummary() {
        XCTAssertNil(IconModel.summary(states: [], finishedUntil: nil, tick: 0, now: Date()))
    }

    func testNewSettingsDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(s.singleIcon); XCTAssertFalse(s.showTokenText)
        XCTAssertEqual(s.finishBlinkSeconds, 15)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(#"{"finishBlinkSeconds":0}"#.utf8)).finishBlinkSeconds, 1)
        let t = try JSONDecoder().decode(Settings.self, from: Data(#"{"singleIcon":false,"showTokenText":true}"#.utf8))
        XCTAssertFalse(t.singleIcon); XCTAssertTrue(t.showTokenText)
    }
}

final class MenuBarVisibilityTests: XCTestCase {
    func testWarnsOnceAfterThresholdHiddenChecks() {
        var v = MenuBarVisibility(threshold: 3)
        XCTAssertFalse(v.observe([false, false]))
        XCTAssertFalse(v.observe([false, false]))
        XCTAssertTrue(v.observe([false, false]))
        XCTAssertFalse(v.observe([false, false]))     // only once per launch
    }

    func testAnyVisibleItemResetsStreak() {
        var v = MenuBarVisibility(threshold: 2)
        XCTAssertFalse(v.observe([false]))
        XCTAssertFalse(v.observe([false, true]))      // one visible is enough
        XCTAssertFalse(v.observe([false]))
        XCTAssertTrue(v.observe([false]))
    }

    func testNoItemsIsNotHidden() {
        var v = MenuBarVisibility(threshold: 1)
        XCTAssertFalse(v.observe([]))
    }
}

final class ReopenPolicyTests: XCTestCase {
    func testRelaunchOpensSettings() {
        let now = Date()
        XCTAssertTrue(ReopenPolicy.opensSettings(reopenAt: now, lastNotificationClick: .distantPast))
        XCTAssertTrue(ReopenPolicy.opensSettings(reopenAt: now, lastNotificationClick: now.addingTimeInterval(-60)))
    }

    func testNotificationClickDoesNot() {
        let now = Date()
        XCTAssertFalse(ReopenPolicy.opensSettings(reopenAt: now, lastNotificationClick: now.addingTimeInterval(-0.3)))   // click first
        XCTAssertFalse(ReopenPolicy.opensSettings(reopenAt: now, lastNotificationClick: now.addingTimeInterval(0.4)))    // reopen first
    }
}

final class SpinTests: XCTestCase {
    func testStepsAreQuantizedAndWrap() {
        let t = Date(timeIntervalSinceReferenceDate: 1000)
        for i in 0..<40 {
            let d = IconModel.spinDegrees(now: t.addingTimeInterval(Double(i) * 0.05))
            XCTAssertTrue(d >= 0 && d < 360 && d.truncatingRemainder(dividingBy: 30) == 0)
        }
        XCTAssertEqual(IconModel.spinDegrees(now: t), IconModel.spinDegrees(now: t.addingTimeInterval(1.2)))
    }

    func testAdvancesOverTime() {
        let t = Date(timeIntervalSinceReferenceDate: 1000)
        let angles = Set((0..<12).map { IconModel.spinDegrees(now: t.addingTimeInterval(Double($0) * 0.1)) })
        XCTAssertEqual(angles.count, 12)       // a full turn in 1.2s, one distinct angle per 0.1s
    }

    func testAnimateRunningDefault() throws {
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).animateRunning)
    }
}
