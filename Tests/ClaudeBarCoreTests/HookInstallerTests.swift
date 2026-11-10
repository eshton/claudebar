import XCTest
@testable import ClaudeBarCore

final class HookInstallerTests: XCTestCase {
    private func make(permission: Bool = true) throws -> (HookInstaller, URL) {
        let home = try tempHome()
        let src = home.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for n in ["mark.sh", "permission.sh"] {
            try "#!/bin/bash\n".write(to: src.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        return (HookInstaller(home: home, sourceDir: src, permissionHook: permission), home)
    }
    private func json(_ home: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

    func testMissingScriptFailsWithoutTouchingSettings() throws {
        let (inst, home) = try make()
        try FileManager.default.removeItem(at: home.appendingPathComponent("src/permission.sh"))
        XCTAssertThrowsError(try inst.install())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    func testNonExecutableScriptNeedsRepair() throws {
        let (inst, home) = try make()
        try inst.install()
        XCTAssertEqual(inst.status(), .installed)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: home.appendingPathComponent(".claude/clauderr/hooks/mark.sh").path)
        XCTAssertEqual(inst.status(), .needsRepair)
        try inst.install()                                  // repair
        XCTAssertEqual(inst.status(), .installed)
    }

    func testTogglingPermissionHookRewritesSettings() throws {
        let (inst, home) = try make(permission: true)
        try inst.install()
        var without = inst
        without.permissionHook = false
        XCTAssertEqual(without.status(), .needsRepair)          // PermissionRequest is registered but no longer wanted
        try without.install()
        XCTAssertEqual(without.status(), .installed)
        XCTAssertTrue(commands(try json(home), "PermissionRequest").isEmpty)
    }
}
