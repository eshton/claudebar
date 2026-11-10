import XCTest
@testable import ClaudeBarCore

private func tempHome() throws -> URL {
    let h = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: h.appendingPathComponent(".claude/clauderr"), withIntermediateDirectories: true)
    return h
}

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

final class ToolActivityTests: XCTestCase {
    private func use(_ id: String, _ tool: String, _ input: String, _ ts: String) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"\#(tool)","input":\#(input)}]}}"#
    }
    private func result(_ id: String, _ ts: String) -> String {
        #"{"type":"user","timestamp":"\#(ts)","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}}"#
    }

    func testRunningToolHasNoResult() {
        let tail = [result("old", "2026-01-01T10:00:00.000Z"),
                    use("t1", "Bash", #"{"command":"npm test"}"#, "2026-01-01T10:01:00.000Z")].joined(separator: "\n")
        let c = ToolActivity.lastCall(inTail: Data(tail.utf8))
        XCTAssertEqual(c?.name, "Bash"); XCTAssertEqual(c?.summary, "npm test")
        XCTAssertEqual(c?.isRunning, true)
    }

    func testFinishedToolAndPartialFirstLine() {
        let tail = ["garbage half line {\"typ",
                    use("t1", "Read", #"{"file_path":"/a/b.swift"}"#, "2026-01-01T10:01:00Z"),
                    result("t1", "2026-01-01T10:01:05Z")].joined(separator: "\n")
        let c = ToolActivity.lastCall(inTail: Data(tail.utf8))
        XCTAssertEqual(c?.summary, "/a/b.swift")
        XCTAssertEqual(c?.isRunning, false)
    }

    func testResultOfEarlierCallDoesNotFinishLaterOne() {
        let tail = [use("a", "Bash", #"{"command":"x"}"#, "2026-01-01T10:00:00Z"),
                    use("b", "Bash", #"{"command":"y"}"#, "2026-01-01T10:00:01Z"),
                    result("a", "2026-01-01T10:00:02Z")].joined(separator: "\n")
        let c = ToolActivity.lastCall(inTail: Data(tail.utf8))
        XCTAssertEqual(c?.summary, "y"); XCTAssertEqual(c?.isRunning, true)
    }

    func testNoToolCalls() {
        XCTAssertNil(ToolActivity.lastCall(inTail: Data(#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#.utf8)))
    }

    func testSummarizeTruncatesAndFlattens() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(ToolActivity.summarize(tool: "Bash", input: ["command": long]).count, 121)
        XCTAssertEqual(ToolActivity.summarize(tool: "Bash", input: ["command": "a\nb"]), "a b")
        XCTAssertEqual(ToolActivity.summarize(tool: "Grep", input: ["pattern": "foo"]), "foo")
    }

    func testDescribe() {
        let now = Date()
        let running = ToolCall(name: "Bash", summary: "sleep 9", startedAt: now.addingTimeInterval(-840), finishedAt: nil)
        XCTAssertEqual(ToolActivity.describe(running, now: now), "tool still running 14m: Bash `sleep 9`")
        let done = ToolCall(name: "Bash", summary: "", startedAt: now.addingTimeInterval(-900), finishedAt: now.addingTimeInterval(-600))
        XCTAssertTrue(ToolActivity.describe(done, now: now).hasPrefix("last tool finished 10m ago (Bash)"))
    }

    func testStoreReadsTranscriptTail() throws {
        let home = try tempHome()
        let proj = home.appendingPathComponent(".claude/projects/-x-y")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try use("t1", "Edit", #"{"file_path":"/f"}"#, "2026-01-01T10:00:00Z")
            .write(to: proj.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        let c = SessionStore(home: home).lastToolCall(sessionId: "s1", cwd: "/x/y")
        XCTAssertEqual(c?.name, "Edit")
    }
}

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

final class HookInstallerTests: XCTestCase {
    private func make(permission: Bool = true) throws -> (HookInstaller, URL) {
        let home = try tempHome()
        let src = home.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for n in ["mark.sh", "permission.sh"] { try "#!/bin/bash\n".write(to: src.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        return (HookInstaller(home: home, sourceDir: src, permissionHook: permission), home)
    }
    private func json(_ home: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))) as! [String: Any]
    }
    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        ((root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testFreshInstallIsIdempotent() throws {
        let (inst, home) = try make()
        XCTAssertEqual(inst.status(), .notInstalled)
        try inst.install(); try inst.install()
        XCTAssertEqual(inst.status(), .installed)
        let root = try json(home)
        XCTAssertEqual(commands(root, "Stop").count, 1)
        XCTAssertEqual(commands(root, "PermissionRequest").count, 1)
        let mark = home.appendingPathComponent(".claude/clauderr/hooks/mark.sh").path
        XCTAssertEqual(commands(root, "Notification"), ["\(mark) set"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: mark))
    }

    func testRepairsStalePathAndKeepsOtherHooks() throws {
        let (inst, home) = try make()
        let old = #"""
        {"model":"x","hooks":{
          "PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]},
                         {"hooks":[{"type":"command","command":"/Users/aston/clauderr/hooks/mark.sh clear"}]}],
          "Notification":[{"hooks":[{"type":"command","command":"/Users/aston/clauderr/hooks/mark.sh set"}]}]}}
        """#
        try old.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(inst.status(), .needsRepair)
        try inst.install()
        XCTAssertEqual(inst.status(), .installed)
        let root = try json(home)
        XCTAssertEqual(root["model"] as? String, "x")
        let post = commands(root, "PostToolUse")
        XCTAssertTrue(post.contains("rtk hook claude"))
        XCTAssertFalse(post.contains { $0.hasPrefix("/Users/aston/clauderr") })
        XCTAssertEqual(post.count, 2)
    }

    func testUninstallLeavesOthersAndBackupKeepsOriginal() throws {
        let (inst, home) = try make()
        let original = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other"}]}]}}"#
        try original.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        try inst.install(); try inst.install()
        try inst.uninstall()
        let root = try json(home)
        XCTAssertEqual(commands(root, "Stop"), ["other"])
        XCTAssertNil((root["hooks"] as? [String: Any])?["PermissionRequest"])
        let bak = try String(contentsOf: home.appendingPathComponent(".claude/settings.json.bak-clauderr"), encoding: .utf8)
        XCTAssertEqual(bak, original)
    }

    func testWithoutPermissionHook() throws {
        let (inst, home) = try make(permission: false)
        try inst.install()
        XCTAssertEqual(inst.status(), .installed)
        XCTAssertTrue(commands(try json(home), "PermissionRequest").isEmpty)
    }

    func testInvalidSettingsAreNotClobbered() throws {
        let (inst, home) = try make()
        let url = home.appendingPathComponent(".claude/settings.json")
        try "{ broken".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try inst.install())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ broken")
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
