import XCTest
@testable import ClaudeBarCore

final class TokenCounterTests: XCTestCase {
    func testCountsDedupesAndContext() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let proj = home.appendingPathComponent(".claude/projects/-p")
        try FileManager.default.createDirectory(at: proj.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        let old = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3 * 86400))
        func line(_ id: String, out: Int, ts: String, text: String? = nil, side: Bool = false) -> String {
            let content = text.map { #","content":[{"type":"text","text":"\#($0)"}]"# } ?? ""
            let usage = #""usage":{"input_tokens":10,"output_tokens":\#(out),"#
                + #""cache_creation_input_tokens":100,"cache_read_input_tokens":1000}"#
            let head = #"{"type":"assistant","timestamp":"\#(ts)","requestId":"r\#(id)","isSidechain":\#(side),"#
            return head + #""message":{"id":"m\#(id)","model":"x",\#(usage)\#(content)}}"#
        }
        let main = [line("1", out: 5, ts: ts), line("1", out: 50, ts: ts),   // streamed duplicate, final = 50
                    line("2", out: 7, ts: ts, text: "hello"), line("0", out: 999, ts: old)].joined(separator: "\n") + "\n"
        try main.write(to: proj.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        try (line("9", out: 3, ts: ts, side: true) + "\n")
            .write(to: proj.appendingPathComponent("s1/subagents/agent-a.jsonl"), atomically: true, encoding: .utf8)

        let c = TokenCounter(home: home)
        let s = c.scan(liveSessionIds: [], now: now)
        XCTAssertEqual(s.total.output, 50 + 7 + 3)          // dup collapsed, old day excluded, subagent included
        XCTAssertEqual(s.total.input, 30)
        XCTAssertEqual(s.perSession["s1"]?.contextTokens, 1110)
        XCTAssertEqual(s.perSession["s1"]?.lastText, "hello")
        XCTAssertEqual(s.perSession["s1"]?.contextWindow, 200_000)
        // incremental: appending a line adds only that line
        let h = try FileHandle(forWritingTo: proj.appendingPathComponent("s1.jsonl"))
        h.seekToEndOfFile(); h.write(Data((line("3", out: 4, ts: ts) + "\n").utf8)); try h.close()
        XCTAssertEqual(c.scan(liveSessionIds: [], now: now).total.output, 64)
    }
    func testFmt() {
        XCTAssertEqual(Fmt.millions(236_000_000), "236M")
        XCTAssertEqual(Fmt.millions(5_600_000), "5.60M")
        XCTAssertEqual(Fmt.compact(340_000), "340k")
    }
}
