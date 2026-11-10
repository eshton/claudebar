import XCTest
@testable import ClaudeBarCore

final class StateTests: XCTestCase {
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

final class GhosttyTests: XCTestCase {
    func testPickPrefersTitleThenCwd() {
        let t = [GhosttyTerminal(id: "A", cwd: "/p", name: "✳ First"),
                 GhosttyTerminal(id: "B", cwd: "/p", name: "◑ Second PR"),
                 GhosttyTerminal(id: "C", cwd: "/q", name: "sudo x")]
        XCTAssertEqual(GhosttyMatcher.pick(t, title: "Second PR", cwd: "/p"), "B")
        XCTAssertEqual(GhosttyMatcher.pick(t, title: nil, cwd: "/q"), "C")
        XCTAssertEqual(GhosttyMatcher.pick(t, title: "nope", cwd: "/p"), "A")
        XCTAssertNil(GhosttyMatcher.pick(t, title: nil, cwd: "/zzz"))
    }
    func testParse() {
        XCTAssertEqual(GhosttyMatcher.parse("id1\t/a\t✳ x y\n").first, GhosttyTerminal(id: "id1", cwd: "/a", name: "✳ x y"))
    }
}

final class TokenTests: XCTestCase {
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

final class GhosttyTieBreakTests: XCTestCase {
    /// Real tabs seen on the user's machine: two sessions, same repo, identical title, different glyph.
    private let live = [
        GhosttyTerminal(id: "main", cwd: "/g/clauderr", name: "◑ Project review"),
        GhosttyTerminal(id: "vpn", cwd: "/g/clauderr", name: "sudo ~/fortivpn.sh"),
        GhosttyTerminal(id: "docIdle", cwd: "/e/Supplier.DocumentLibrary", name: "✳ Supplier.DocumentLibrary PR 234661"),
        GhosttyTerminal(id: "docBusy", cwd: "/e/Supplier.DocumentLibrary", name: "◑ Supplier.DocumentLibrary PR 234661"),
    ]
    private let title = "Supplier.DocumentLibrary PR 234661"

    func testIdenticalTitlesResolvedByState() {
        XCTAssertEqual(GhosttyMatcher.pick(live, title: title, cwd: "/e/Supplier.DocumentLibrary", busy: true), "docBusy")
        XCTAssertEqual(GhosttyMatcher.pick(live, title: title, cwd: "/e/Supplier.DocumentLibrary", busy: false), "docIdle")
    }

    func testUnknownStateKeepsFirstMatch() {
        XCTAssertEqual(GhosttyMatcher.pick(live, title: title, cwd: "/e/Supplier.DocumentLibrary", busy: nil), "docIdle")
    }

    func testSpinnerFramesCountAsBusy() {
        let t = [GhosttyTerminal(id: "i", cwd: "/p", name: "✳ T"), GhosttyTerminal(id: "b", cwd: "/p", name: "◐ T")]
        XCTAssertEqual(GhosttyMatcher.pick(t, title: "T", cwd: "/p", busy: true), "b")
    }

    func testFolderFallbackPrefersClaudeTabOverShell() {
        // title didn't match (e.g. renamed): the plain `sudo` shell in the same folder must not win
        let t = [GhosttyTerminal(id: "vpn", cwd: "/g/clauderr", name: "sudo ~/fortivpn.sh"),
                 GhosttyTerminal(id: "main", cwd: "/g/clauderr", name: "◑ Project review")]
        XCTAssertEqual(GhosttyMatcher.pick(t, title: "stale title", cwd: "/g/clauderr", busy: true), "main")
        XCTAssertEqual(GhosttyMatcher.pick(t, title: nil, cwd: "/g/clauderr"), "main")
    }

    func testStateDisagreeingWithEveryGlyphStillPicksSomething() {
        let t = [GhosttyTerminal(id: "i", cwd: "/p", name: "✳ T")]
        XCTAssertEqual(GhosttyMatcher.pick(t, title: "T", cwd: "/p", busy: true), "i")   // tab glyph lags the real state
    }

    func testPlainShellOnlyFolderStillMatches() {
        let t = [GhosttyTerminal(id: "sh", cwd: "/p", name: "zsh")]
        XCTAssertEqual(GhosttyMatcher.pick(t, title: nil, cwd: "/p"), "sh")
    }
}
