import Foundation

/// Registers ClaudeBar's hooks in ~/.claude/settings.json, idempotently.
///
/// Scripts are copied to ~/.claude/clauderr/hooks/ and registered from there, so moving or rebuilding
/// the repo never leaves settings.json pointing at a path that no longer exists.
public struct HookInstaller {
    public enum Status: Equatable {
        case notInstalled
        /// Hooks of ours exist but differ from what should be installed (stale path, missing event, ...).
        case needsRepair
        case installed
    }

    public enum InstallError: Error, CustomStringConvertible {
        case unreadableSettings(String)
        case missingScript(String)
        public var description: String {
            switch self {
            case .unreadableSettings(let m): return "settings.json is not valid JSON, leaving it untouched (\(m))"
            case .missingScript(let p): return "hook script not found: \(p)"
            }
        }
    }

    public let settingsURL: URL
    public let installDir: URL
    /// Directory holding mark.sh / permission.sh to copy from (nil = scripts already in installDir).
    public let sourceDir: URL?
    public var permissionHook: Bool

    static let timeoutForPermission = 330

    public init(home: URL = AppHome.url, sourceDir: URL?, permissionHook: Bool) {
        settingsURL = home.appendingPathComponent(".claude/settings.json")
        installDir = home.appendingPathComponent(".claude/clauderr/hooks")
        self.sourceDir = sourceDir
        self.permissionHook = permissionHook
    }

    struct Entry: Equatable { let event: String; let command: String; let timeout: Int? }

    var desired: [Entry] {
        let mark = installDir.appendingPathComponent("mark.sh").path
        var e = [
            Entry(event: "Notification", command: "\(mark) set", timeout: nil),
            Entry(event: "UserPromptSubmit", command: "\(mark) clear", timeout: nil),
            Entry(event: "Stop", command: "\(mark) clear", timeout: nil),
            Entry(event: "PostToolUse", command: "\(mark) clear", timeout: nil),
        ]
        if permissionHook {
            e.append(Entry(event: "PermissionRequest",
                           command: installDir.appendingPathComponent("permission.sh").path,
                           timeout: Self.timeoutForPermission))
        }
        return e
    }

    /// Our hook commands are recognised by script name + "clauderr" in the path (covers old locations too).
    static func isOurs(_ command: String) -> Bool {
        command.contains("clauderr") && (command.contains("/hooks/mark.sh") || command.contains("/hooks/permission.sh"))
    }

    // MARK: status

    public func status() -> Status {
        guard let root = try? loadSettings() else { return .notInstalled }
        let ours = Self.ourEntries(in: root)
        if ours.isEmpty { return .notInstalled }
        let scriptsOK = desired.allSatisfy { FileManager.default.isExecutableFile(atPath: String($0.command.split(separator: " ")[0])) }
        func key(_ e: Entry) -> String { "\(e.event)|\(e.command)|\(e.timeout ?? 0)" }
        return Set(ours.map(key)) == Set(desired.map(key)) && scriptsOK
            ? .installed : .needsRepair
    }

    // MARK: install / uninstall

    public func install() throws {
        var root = try loadSettings()
        try copyScripts()
        Self.removeOurs(from: &root)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for e in desired {
            var groups = hooks[e.event] as? [[String: Any]] ?? []
            var h: [String: Any] = ["type": "command", "command": e.command]
            if let t = e.timeout { h["timeout"] = t }
            groups.append(["hooks": [h]])
            hooks[e.event] = groups
        }
        root["hooks"] = hooks
        try backupOnce()
        try write(root)
    }

    public func uninstall() throws {
        var root = try loadSettings()
        Self.removeOurs(from: &root)
        try backupOnce()
        try write(root)
    }

    // MARK: internals

    func copyScripts() throws {
        guard let src = sourceDir else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        for name in ["mark.sh", "permission.sh"] {
            let from = src.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else { throw InstallError.missingScript(from.path) }
            let to = installDir.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: from, to: to)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: to.path)
        }
    }

    func loadSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }   // no file yet
        if data.isEmpty { return [:] }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.unreadableSettings("top level is not an object")
            }
            return obj
        } catch let e as InstallError {
            throw e
        } catch {
            throw InstallError.unreadableSettings(error.localizedDescription)
        }
    }

    func write(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Keeps the very first backup (the user's original) and never overwrites it.
    func backupOnce() throws {
        let bak = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.bak-clauderr")
        let fm = FileManager.default
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: bak.path) {
            try fm.copyItem(at: settingsURL, to: bak)
        }
    }

    static func ourEntries(in root: [String: Any]) -> [Entry] {
        var out: [Entry] = []
        for (event, v) in root["hooks"] as? [String: Any] ?? [:] {
            for g in v as? [[String: Any]] ?? [] {
                for h in g["hooks"] as? [[String: Any]] ?? [] {
                    if let c = h["command"] as? String, isOurs(c) {
                        out.append(Entry(event: event, command: c, timeout: h["timeout"] as? Int))
                    }
                }
            }
        }
        return out
    }

    static func removeOurs(from root: inout [String: Any]) {
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, v) in hooks {
            var groups = v as? [[String: Any]] ?? []
            groups = groups.compactMap { g in
                var g = g
                let kept = (g["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0["command"] as? String ?? "") }
                if kept.isEmpty { return nil }      // group only held our hooks
                g["hooks"] = kept
                return g
            }
            if groups.isEmpty { hooks[event] = nil } else { hooks[event] = groups }
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
    }
}
