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
