import Foundation

/// Remembers each session's previous state to turn changes into alerts, and runs the "just finished" blink deadline.
public struct SessionTracker {
    public private(set) var lastState: [Int32: SessionState] = [:]
    public private(set) var finishedUntil: [Int32: Date] = [:]
    /// Steady (non-blinking) check after the user acknowledged a finished session.
    public private(set) var lingerUntil: [Int32: Date] = [:]

    public init() {}

    /// Feed the current sessions. Returns the alerts for sessions whose state changed since the last call.
    public mutating func update(_ list: [Session], now: Date, blinkSeconds: Int,
                                isMuted: (String) -> Bool) -> [(session: Session, alert: Alert)] {
        let live = Set(list.map(\.pid))
        for pid in lastState.keys where !live.contains(pid) {
            lastState[pid] = nil
            finishedUntil[pid] = nil
            lingerUntil[pid] = nil
        }
        var alerts: [(session: Session, alert: Alert)] = []
        for s in list.sorted(by: { $0.pid < $1.pid }) where lastState[s.pid] != s.state {
            if let a = AlertPolicy.alert(from: lastState[s.pid], to: s.state, muted: isMuted(s.sessionId)) {
                alerts.append((s, a))
            }
            if let prev = lastState[s.pid], prev != .idle, s.state == .idle {
                finishedUntil[s.pid] = now.addingTimeInterval(TimeInterval(blinkSeconds))
            } else if s.state != .idle {
                finishedUntil[s.pid] = nil
                lingerUntil[s.pid] = nil       // working again: the check no longer applies
            }
            lastState[s.pid] = s.state
        }
        return alerts
    }

    public func isFinishing(_ pid: Int32, now: Date) -> Bool {
        (finishedUntil[pid] ?? .distantPast) > now
    }

    /// Latest blink deadline among these sessions (the single icon blinks while any of them is finishing).
    public func latestFinish(of pids: [Int32]) -> Date? {
        pids.compactMap { finishedUntil[$0] }.max()
    }

    public func isLingering(_ pid: Int32, now: Date) -> Bool {
        (lingerUntil[pid] ?? .distantPast) > now
    }

    public func latestLinger(of pids: [Int32]) -> Date? {
        pids.compactMap { lingerUntil[$0] }.max()
    }

    /// The user looked at it: stop blinking. A session that was blinking keeps a steady check for `lingerSeconds`
    /// so the finished job doesn't vanish the moment it is clicked.
    public mutating func acknowledge(_ pid: Int32, now: Date = Date(), lingerSeconds: Int = 0) {
        if isFinishing(pid, now: now), lingerSeconds > 0 {
            lingerUntil[pid] = now.addingTimeInterval(TimeInterval(lingerSeconds))
        }
        finishedUntil[pid] = nil
    }

    public mutating func expire(now: Date) {
        finishedUntil = finishedUntil.filter { $0.value > now }
        lingerUntil = lingerUntil.filter { $0.value > now }
    }

    public var hasFinishing: Bool { !finishedUntil.isEmpty }

    /// Sessions that currently get an icon ("hide idle" applied).
    public func visible(_ list: [Session], hideIdle: Bool, pendingSessionIds: Set<String>, now: Date) -> [Session] {
        list.filter {
            let keepShowing = isFinishing($0.pid, now: now) || isLingering($0.pid, now: now)
            return IconModel.isVisible(state: $0.state, hideIdle: hideIdle, finishing: keepShowing,
                                       hasPendingPermission: pendingSessionIds.contains($0.sessionId))
        }
    }
}

/// Which permission requests are new (announce them) and which vanished (withdraw their banners).
public struct PermissionAnnouncements {
    private var announced = Set<String>()

    public init() {}

    public mutating func update(_ pending: [PermissionRequest]) -> (new: [PermissionRequest], gone: [String]) {
        let ids = Set(pending.map(\.id))
        let new = pending.filter { !announced.contains($0.id) }
        let gone = announced.subtracting(ids)
        announced.formUnion(new.map(\.id))
        announced.subtract(gone)
        return (new, gone.sorted())
    }
}
