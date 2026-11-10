import XCTest
@testable import ClaudeBarCore

final class ToolActivityTests: XCTestCase {
    private func use(_ id: String, _ tool: String, _ input: String, _ ts: String) -> String {
        let block = #"{"type":"tool_use","id":"\#(id)","name":"\#(tool)","input":\#(input)}"#
        return #"{"type":"assistant","timestamp":"\#(ts)","message":{"content":[\#(block)]}}"#
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
