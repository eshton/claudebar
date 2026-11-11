import Foundation

/// Home directory all ClaudeBar state lives under. `CLAUDEBAR_HOME` redirects it (smoke tests run against a fake home;
/// `$HOME` alone is ignored by Foundation's home lookup).
public enum AppHome {
    public static var url: URL {
        if let p = ProcessInfo.processInfo.environment["CLAUDEBAR_HOME"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// User preferences, persisted at ~/.claude/clauderr/settings.json.
/// Decoding is forgiving: missing keys fall back to defaults so older files keep working.
public struct Settings: Codable, Equatable {
    /// A busy session silent for this many minutes is "stuck".
    public var stuckMinutes = 10
    /// How long the green check blinks after a session finishes.
    public var finishBlinkSeconds = 15
    /// macOS banners (waiting / stuck / permission requests).
    public var notifications = true
    /// Also banner when a session finishes. Off by default: noisy with many sessions.
    public var notifyOnFinish = false
    public var sound = true
    public var haptics = true
    /// One menu bar icon for all sessions (worst state + count) instead of one icon per session. Saves menu bar space.
    public var singleIcon = true
    /// After you click a finished session, its green check stays (steady) for this long. 0 = drop it at once.
    public var finishLingerSeconds = 120
    /// macOS system sound played when a job finishes ("None" = silent). Soft on purpose: errors use "Ping".
    public var finishSound = "Glass"
    /// Spin the running icon (skipped when macOS "Reduce motion" is on).
    public var animateRunning = true
    /// Show today's token total next to the bolt. Off by default: the menu bar is crowded (notch Macs hide overflow).
    public var showTokenText = false
    /// Hide the icon of idle sessions (they come back when they need you).
    public var hideIdle = false
    /// Ask ClaudeBar to approve/deny permission prompts (installs the PermissionRequest hook).
    public var permissionPrompts = true
    /// Session ids with alerts muted.
    public var mutedSessions: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case singleIcon, animateRunning, showTokenText, stuckMinutes, finishBlinkSeconds, finishLingerSeconds, finishSound
        case notifications, notifyOnFinish, sound, haptics, hideIdle, permissionPrompts, mutedSessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        singleIcon = try c.decodeIfPresent(Bool.self, forKey: .singleIcon) ?? d.singleIcon
        animateRunning = try c.decodeIfPresent(Bool.self, forKey: .animateRunning) ?? d.animateRunning
        showTokenText = try c.decodeIfPresent(Bool.self, forKey: .showTokenText) ?? d.showTokenText
        stuckMinutes = max(1, try c.decodeIfPresent(Int.self, forKey: .stuckMinutes) ?? d.stuckMinutes)
        finishBlinkSeconds = min(600, max(1, try c.decodeIfPresent(Int.self, forKey: .finishBlinkSeconds) ?? d.finishBlinkSeconds))
        finishLingerSeconds = min(3600, max(0, try c.decodeIfPresent(Int.self, forKey: .finishLingerSeconds) ?? d.finishLingerSeconds))
        finishSound = try c.decodeIfPresent(String.self, forKey: .finishSound) ?? d.finishSound
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? d.notifications
        notifyOnFinish = try c.decodeIfPresent(Bool.self, forKey: .notifyOnFinish) ?? d.notifyOnFinish
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? d.sound
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        hideIdle = try c.decodeIfPresent(Bool.self, forKey: .hideIdle) ?? d.hideIdle
        permissionPrompts = try c.decodeIfPresent(Bool.self, forKey: .permissionPrompts) ?? d.permissionPrompts
        mutedSessions = try c.decodeIfPresent([String].self, forKey: .mutedSessions) ?? d.mutedSessions
    }

    /// The finish sound's name, or nil when it is off.
    public var finishSoundName: String? {
        finishSound.isEmpty || finishSound == "None" ? nil : finishSound
    }

    public var staleAfter: TimeInterval { TimeInterval(max(1, stuckMinutes) * 60) }

    public func isMuted(_ sessionId: String) -> Bool { mutedSessions.contains(sessionId) }

    public mutating func setMuted(_ muted: Bool, sessionId: String) {
        mutedSessions.removeAll { $0 == sessionId }
        if muted { mutedSessions.append(sessionId) }
    }

    /// Forget mutes for sessions that no longer exist so the file doesn't grow forever.
    public mutating func pruneMutes(keeping live: Set<String>) {
        mutedSessions.removeAll { !live.contains($0) }
    }
}

public struct SettingsStore {
    public let url: URL

    public init(home: URL = AppHome.url) {
        url = home.appendingPathComponent(".claude/clauderr/settings.json")
    }

    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(_ s: Settings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
