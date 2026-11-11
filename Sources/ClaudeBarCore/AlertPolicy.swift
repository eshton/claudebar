import Foundation

public enum Alert: Equatable {
    case needsInput, stuck, finished
}

/// What an alert should do, given the user's settings. Pure so it can be tested.
public struct AlertDelivery: Equatable {
    /// macOS system sound to play, nil = silent.
    public var sound: String?
    public var volume: Float
    public var haptic: String?
    public var banner: Bool

    public init(sound: String? = nil, volume: Float = 1, haptic: String? = nil, banner: Bool = false) {
        self.sound = sound; self.volume = volume; self.haptic = haptic; self.banner = banner
    }
}

public enum AlertPolicy {
    /// Alerts for a session whose state just changed from `from` (nil = first time seen) to `to`.
    public static func alert(from: SessionState?, to: SessionState, muted: Bool) -> Alert? {
        guard from != to, !muted else { return nil }
        switch to {
        case .waiting: return .needsInput
        case .stuck: return .stuck
        case .idle:
            if let from, from != .idle { return .finished }
            return nil
        case .running: return nil
        }
    }

    /// Errors and "needs you" use the attention sound; a finished job gets a soft bell at half volume.
    public static let attentionSound = "Ping"
    public static let finishVolume: Float = 0.5

    public static func delivery(for alert: Alert, settings: Settings) -> AlertDelivery {
        let attention = settings.sound ? attentionSound : nil
        switch alert {
        case .needsInput:
            return AlertDelivery(sound: attention, haptic: nil, banner: settings.notifications)
        case .stuck:
            return AlertDelivery(sound: attention, haptic: settings.haptics ? "angry_alert" : nil,
                                 banner: settings.notifications)
        case .finished:
            return AlertDelivery(sound: settings.sound ? settings.finishSoundName : nil, volume: finishVolume,
                                 haptic: settings.haptics ? "completed" : nil,
                                 banner: settings.notifications && settings.notifyOnFinish)
        }
    }
}

public enum ContextLevel: Equatable {
    case ok, warn, critical
}

public enum IconKind: Equatable {
    case stuck, waiting, running, idle, finishedFilled, finishedOutline
}

public struct IconSummary: Equatable {
    public let kind: IconKind
    public let badge: Int?
}

public enum IconModel {
    /// Which glyph a session shows. A fresh finish blinks a green check for a few seconds.
    /// After a click the blink stops but the check stays steady until `lingerUntil`.
    public static func kind(state: SessionState, finishedUntil: Date?, lingerUntil: Date? = nil,
                            tick: Int, now: Date) -> IconKind {
        if state == .idle, let until = finishedUntil, until > now {
            return tick % 2 == 0 ? .finishedFilled : .finishedOutline
        }
        if state == .idle, let until = lingerUntil, until > now { return .finishedFilled }
        switch state {
        case .stuck: return .stuck
        case .waiting: return .waiting
        case .running: return .running
        case .idle: return .idle
        }
    }

    /// Single-icon mode: the worst state wins; the badge counts sessions in that state (nil when just one).
    public static func summary(states: [SessionState], finishedUntil: Date?, lingerUntil: Date? = nil,
                               tick: Int, now: Date) -> IconSummary? {
        guard let worst = states.max() else { return nil }
        let n = states.filter { $0 == worst }.count
        return IconSummary(kind: kind(state: worst, finishedUntil: finishedUntil, lingerUntil: lingerUntil,
                                      tick: tick, now: now),
                           badge: worst != .idle && n > 1 ? n : nil)
    }

    /// Rotation of the running icon: 12 steps of 30 degrees per `period` seconds, derived from the clock so every
    /// redraw (any timer interval) agrees on the angle.
    public static func spinDegrees(now: Date, period: TimeInterval = 1.2) -> Double {
        let step = Int(now.timeIntervalSinceReferenceDate / (period / 12)) % 12
        return Double(step * 30)
    }

    /// green < 60%, orange < 85%, red beyond.
    public static func contextLevel(_ fraction: Double) -> ContextLevel {
        fraction >= 0.85 ? .critical : fraction >= 0.60 ? .warn : .ok
    }

    /// With "hide idle" on, idle sessions disappear unless something about them still matters.
    public static func isVisible(state: SessionState, hideIdle: Bool, finishing: Bool, hasPendingPermission: Bool) -> Bool {
        guard hideIdle, state == .idle else { return true }
        return finishing || hasPendingPermission
    }
}

/// Detects "my menu bar icons never made it on screen" (a full menu bar on a notch Mac hides overflow silently).
/// Feed it periodic observations; it reports true exactly once after `threshold` consecutive all-hidden checks.
/// Once per launch on purpose: a fullscreen app also hides the menu bar, and one warning is enough.
public struct MenuBarVisibility {
    public let threshold: Int
    private var streak = 0
    private var warned = false

    public init(threshold: Int = 3) { self.threshold = max(1, threshold) }

    public mutating func observe(_ itemsOnScreen: [Bool]) -> Bool {
        guard !itemsOnScreen.isEmpty, !itemsOnScreen.contains(true) else { streak = 0; return false }
        streak += 1
        guard streak >= threshold, !warned else { return false }
        warned = true
        return true
    }
}

public enum ReopenPolicy {
    /// macOS sends a "reopen" both when the user launches the app again and when they click one of its notifications.
    /// Only the first should open Settings, so a reopen that lands within `window` of a notification click is ignored.
    public static func opensSettings(reopenAt: Date, lastNotificationClick: Date, window: TimeInterval = 2) -> Bool {
        abs(lastNotificationClick.timeIntervalSince(reopenAt)) > window
    }
}
