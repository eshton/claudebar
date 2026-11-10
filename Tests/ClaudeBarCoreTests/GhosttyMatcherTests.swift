import XCTest
@testable import ClaudeBarCore

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

final class BusyHintTests: XCTestCase {
    func testStateToGlyphExpectation() {
        XCTAssertEqual(GhosttyMatcher.busyHint(for: .running), true)
        XCTAssertEqual(GhosttyMatcher.busyHint(for: .stuck), true)
        XCTAssertEqual(GhosttyMatcher.busyHint(for: .idle), false)
        XCTAssertNil(GhosttyMatcher.busyHint(for: .waiting))      // waiting tabs show an unknown glyph
    }

    func testStripGlyph() {
        XCTAssertEqual(GhosttyMatcher.stripGlyph("✳ Title here"), "Title here")
        XCTAssertEqual(GhosttyMatcher.stripGlyph("◑ Title"), "Title")
        XCTAssertEqual(GhosttyMatcher.stripGlyph("zsh"), "zsh")
        XCTAssertEqual(GhosttyMatcher.stripGlyph("sudo ~/x.sh"), "sudo ~/x.sh")
        XCTAssertEqual(GhosttyMatcher.stripGlyph(""), "")
    }
}

/// The case title and glyph can never solve: two idle sessions, same folder, same title, same glyph.
final class GhosttyTTYTests: XCTestCase {
    private let tabs = [
        GhosttyTerminal(id: "A", cwd: "/e/Doc", name: "✳ Doc PR 1", tty: "/dev/ttys005", pid: 52473),
        GhosttyTerminal(id: "B", cwd: "/e/Doc", name: "✳ Doc PR 1", tty: "/dev/ttys006", pid: 53118),
        GhosttyTerminal(id: "vpn", cwd: "/g/x", name: "sudo ~/fortivpn.sh", tty: "/dev/ttys002", pid: 70328),
    ]

    func testTTYSeparatesIdenticalTabs() {
        XCTAssertEqual(GhosttyMatcher.pickMatch(tabs, title: "Doc PR 1", cwd: "/e/Doc", busy: false, tty: "ttys005")?.id, "A")
        XCTAssertEqual(GhosttyMatcher.pickMatch(tabs, title: "Doc PR 1", cwd: "/e/Doc", busy: false, tty: "ttys006")?.id, "B")
        XCTAssertEqual(GhosttyMatcher.pickMatch(tabs, title: "Doc PR 1", cwd: "/e/Doc", tty: "ttys006")?.by, .tty)
    }

    func testTTYBeatsAMisleadingTitleAndFolder() {
        // renamed session, title lookup stale: tty still wins
        XCTAssertEqual(GhosttyMatcher.pick(tabs, title: "stale", cwd: "/somewhere/else", tty: "ttys002"), "vpn")
    }

    func testDevPrefixAndWhitespaceAreIgnored() {
        XCTAssertEqual(GhosttyMatcher.pick(tabs, title: nil, cwd: "", tty: "/dev/ttys006\n"), "B")
    }

    func testPidIsUsedWhenTTYUnknown() {
        XCTAssertEqual(GhosttyMatcher.pickMatch(tabs, title: nil, cwd: "", tty: nil, pid: 53118)?.id, "B")
        XCTAssertEqual(GhosttyMatcher.pickMatch(tabs, title: nil, cwd: "", tty: nil, pid: 53118)?.by, .pid)
    }

    func testSessionInAnotherTerminalIsNotGuessed() {
        // the session has a tty, Ghostty has ttys, none match: it is running in iTerm/Terminal, so do not
        // jump to a look-alike tab with the same title and folder
        XCTAssertNil(GhosttyMatcher.pick(tabs, title: "Doc PR 1", cwd: "/e/Doc", tty: "ttys099"))
    }

    func testOlderGhosttyWithoutTTYFallsBackToHeuristics() {
        let old = [GhosttyTerminal(id: "i", cwd: "/p", name: "✳ T"), GhosttyTerminal(id: "b", cwd: "/p", name: "◐ T")]
        XCTAssertEqual(GhosttyMatcher.pickMatch(old, title: "T", cwd: "/p", busy: true, tty: "ttys001")?.id, "b")
        XCTAssertEqual(GhosttyMatcher.pickMatch(old, title: "T", cwd: "/p", busy: true, tty: "ttys001")?.by, .title)
        XCTAssertEqual(GhosttyMatcher.pickMatch(old, title: nil, cwd: "/p", tty: nil)?.by, .folder)
    }

    func testSessionWithoutTTYUsesHeuristics() {
        XCTAssertEqual(GhosttyMatcher.pick(tabs, title: "Doc PR 1", cwd: "/e/Doc", tty: nil), "A")
    }

    func testParseNewAndLegacyFormats() {
        let new = GhosttyMatcher.parse("id1\t/dev/ttys005\t52473\t/e/Doc\t✳ Title\twith tab\n")
        XCTAssertEqual(new, [GhosttyTerminal(id: "id1", cwd: "/e/Doc", name: "✳ Title\twith tab", tty: "/dev/ttys005", pid: 52473)])
        XCTAssertEqual(GhosttyMatcher.parse("id1\t/a\t✳ x y\n"), [GhosttyTerminal(id: "id1", cwd: "/a", name: "✳ x y")])
        XCTAssertTrue(GhosttyMatcher.parse("garbage line\n\n").isEmpty)
    }

    func testProcessTTYParsing() {
        XCTAssertEqual(ProcessTTY.parse("ttys016\n"), "ttys016")
        XCTAssertEqual(ProcessTTY.parse("  ttys000 "), "ttys000")
        XCTAssertNil(ProcessTTY.parse("??\n"))
        XCTAssertNil(ProcessTTY.parse(""))
        XCTAssertNil(ProcessTTY.of(Int32.max - 1))          // no such process
    }
}
