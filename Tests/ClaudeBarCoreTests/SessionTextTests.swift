import XCTest
@testable import ClaudeBarCore

final class SessionTextTests: XCTestCase {
    func testLabelAndSnippet() {
        XCTAssertEqual([SessionState.idle, .running, .waiting, .stuck].map(SessionText.label), ["idle", "running", "waiting", "stuck"])
        XCTAssertEqual(SessionText.snippet("a\nb", 10), "a b")
        XCTAssertEqual(SessionText.snippet("abcdef", 3), "abc…")
        XCTAssertEqual(SessionText.snippet("abc", 3), "abc")
    }

    func testQuietOnlyForActiveStates() {
        XCTAssertEqual(SessionText.quiet(makeSession(state: .stuck, silentFor: 720)), " (no activity 12m)")
        XCTAssertEqual(SessionText.quiet(makeSession(state: .running, silentFor: 30)), " (no activity 0m)")
        XCTAssertEqual(SessionText.quiet(makeSession(state: .idle, silentFor: 9999)), "")
        XCTAssertEqual(SessionText.quiet(makeSession(state: .waiting, silentFor: 9999)), "")
    }

    func testUsageLines() {
        let u = makeUsage()
        // above 200k tokens seen => the 1M window is assumed
        XCTAssertEqual(SessionText.usageSummary(u), "Today 12.3M · context 340k/1.0M (34%)")
        XCTAssertEqual(SessionText.contextLine(makeUsage(context: 100_000)), "Context: 100k / 200k (50%)")
    }

    func testTooltipFull() {
        let s = makeSession(state: .stuck, silentFor: 660)
        let t = SessionText.tooltip(for: s, usage: makeUsage(today: 1_000_000, context: 100_000, last: "done\nnow"),
                                    pending: [makeRequest(), makeRequest(id: "r2", session: "other")],
                                    muted: true, diagnosis: "tool still running 11m: Bash `x`")
        XCTAssertEqual(t, """
            alpha — stuck (no activity 11m) · muted
            /p
            Today 1.00M · context 100k/200k (50%)
            Last: done now
            Approval needed: Bash rm -rf x
            Diagnosis: tool still running 11m: Bash `x`
            (click: focus in Ghostty · right-click: menu)
            """)
    }

    func testTooltipMinimal() {
        let t = SessionText.tooltip(for: makeSession(state: .idle), usage: nil, pending: [], muted: false, diagnosis: "ignored")
        XCTAssertEqual(t, "alpha — idle\n/p\n(click: focus in Ghostty · right-click: menu)")   // diagnosis only for stuck
    }

    func testListOrderMostRecentFirstThenName() {
        let list = [makeSession(pid: 1, name: "b", state: .stuck, silentFor: 900),
                    makeSession(pid: 2, name: "c", state: .idle, silentFor: 70),
                    makeSession(pid: 3, name: "a", state: .waiting, silentFor: 100),
                    makeSession(pid: 4, name: "d", state: .running, silentFor: 5)]
        XCTAssertEqual(SessionText.listOrder(list).map(\.name), ["d", "c", "a", "b"])
    }

    func testDuration() {
        XCTAssertEqual(SessionText.duration(seconds: 0), "0s")
        XCTAssertEqual(SessionText.duration(seconds: 42), "42s")
        XCTAssertEqual(SessionText.duration(seconds: 182), "3m2s")
        XCTAssertEqual(SessionText.duration(seconds: 3_600), "1h0m")
        XCTAssertEqual(SessionText.duration(seconds: 11_100), "3h5m")
        XCTAssertEqual(SessionText.duration(seconds: 184_332), "2d3h")
        XCTAssertEqual(SessionText.duration(seconds: 519_960), "6d0h")
    }

    func testAgoPrefersMessageTime() {
        // the transcript was touched recently (silentFor), but the last message is 2 days old
        let s = makeSession(name: "n", state: .idle, silentFor: 30, sinceMessage: 2 * 86_400)
        XCTAssertEqual(SessionText.rowTitle(s, hasApproval: false), "n — idle · 2d0h ago")
        let fresh = makeSession(pid: 2, name: "m", state: .idle, silentFor: 9_000, sinceMessage: 60)
        XCTAssertEqual(SessionText.listOrder([s, fresh]).map(\.name), ["m", "n"])
    }

    func testRowTitleShowsMinutesSinceLastMessage() {
        XCTAssertEqual(SessionText.rowTitle(makeSession(state: .idle, silentFor: 185), hasApproval: false),
                       "alpha — idle · 3m5s ago")
        XCTAssertEqual(SessionText.rowTitle(makeSession(state: .waiting, silentFor: 20), hasApproval: true),
                       "alpha — waiting · 20s ago · approval needed")
    }

    func testSingleTooltip() {
        let list = [makeSession(pid: 1, id: "s1", name: "a", state: .running, silentFor: 240),
                    makeSession(pid: 2, id: "s2", name: "b", state: .waiting, silentFor: 60)]
        let t = SessionText.singleTooltip(list, pending: [makeRequest(session: "s2")], mutedIds: ["s1"])
        XCTAssertEqual(t, "• b — waiting · 1m0s ago · approval needed\n• a — running · 4m0s ago · muted\n"
                          + "(click: focus / list · right-click: list)")
    }

    func testMenuLines() {
        let s = makeSession(state: .running)
        XCTAssertEqual(SessionText.menuLines(for: s, usage: nil, diagnosis: nil), ["alpha", "State: running", "/p"])
        let lines = SessionText.menuLines(for: s, usage: makeUsage(today: 2_000_000, context: 50_000, last: "hi"),
                                          diagnosis: "tool still running 3m: Bash `x`")
        XCTAssertEqual(lines.suffix(4), ["Today: 2.00M tokens", "Context: 50k / 200k (25%)", "Last: hi",
                                         "Tool still running 3m: Bash `x`"])
        // an idle session never shows a diagnosis
        XCTAssertFalse(SessionText.menuLines(for: makeSession(state: .idle), usage: nil, diagnosis: "x").contains("X"))
    }

    func testTokenLines() {
        var t = TokenBreakdown()
        t.input = 1_000_000; t.output = 500_000; t.cacheRead = 3_000_000
        XCTAssertEqual(SessionText.tokenLines(t), ["Today: 4.50M tokens", "    Input: 1.00M", "    Output: 0.50M",
                                                   "    Cache write: 0.00M", "    Cache read: 3.00M"])
        XCTAssertEqual(SessionText.tokenRow(makeSession(), usage: makeUsage(today: 4_200_000, context: 68_000)),
                       "alpha: 4.20M · ctx 34% · 0s ago")
        XCTAssertEqual(SessionText.tokenRow(makeSession(), usage: nil), "alpha: 0.00M · 0s ago")
    }

    func testBanners() {
        let s = makeSession(name: "alpha", state: .stuck, silentFor: 900)
        XCTAssertEqual(SessionText.bannerText(.needsInput, session: s, request: makeRequest(), usage: nil, diagnosis: nil).body,
                       "Bash: rm -rf x")
        let asked = SessionText.bannerText(.needsInput, session: s, request: nil, usage: makeUsage(last: "question?"), diagnosis: nil)
        XCTAssertEqual(asked.body, "question?")
        XCTAssertEqual(SessionText.bannerText(.needsInput, session: s, request: nil, usage: nil, diagnosis: nil).body,
                       "Waiting for your input")
        let stuck = SessionText.bannerText(.stuck, session: s, request: nil, usage: nil, diagnosis: nil)
        XCTAssertEqual(stuck.title, "alpha looks stuck"); XCTAssertEqual(stuck.body, "No activity for 15 min")
        XCTAssertEqual(SessionText.bannerText(.stuck, session: s, request: nil, usage: nil, diagnosis: "hung").body, "hung")
        let done = SessionText.bannerText(.finished, session: s, request: nil, usage: nil, diagnosis: nil)
        XCTAssertEqual(done.title, "alpha finished"); XCTAssertEqual(done.body, "Done")
    }

    func testPermissionBanner() {
        let b = SessionText.permissionBanner(makeRequest(), sessionName: "alpha")
        XCTAssertEqual(b.title, "alpha: approve Bash?"); XCTAssertEqual(b.body, "rm -rf x")
        XCTAssertEqual(SessionText.permissionBanner(makeRequest(), sessionName: nil).title, "Claude: approve Bash?")
    }
}
