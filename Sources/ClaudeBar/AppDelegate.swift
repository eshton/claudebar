import AppKit
import ClaudeBarCore

/// Payload of an Approve / Deny menu item.
private final class PermissionChoice: NSObject {
    let id: String, verdict: PermissionVerdict
    init(_ id: String, _ verdict: PermissionVerdict) { self.id = id; self.verdict = verdict }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store = SessionStore()
    private let settingsStore = SettingsStore()
    private var settings = Settings()
    private let permissions = PermissionStore()
    private let notifier = Notifier()
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?

    /// `--selftest`: run against CLAUDEBAR_HOME, print what the menu bar would show as JSON, exit. No sound/alerts/instance kill.
    private let selfTest: Bool

    init(selfTest: Bool = false) {
        self.selfTest = selfTest
        super.init()
    }

    private var items: [Int32: NSStatusItem] = [:]
    private var singleItem: NSStatusItem?              // single-icon mode: one item for every session
    private var lastNotificationClick = Date.distantPast
    private var visibility = MenuBarVisibility()
    private var visibilityTimer: Timer?
    private var sessions: [Int32: Session] = [:]
    private var lastState: [Int32: SessionState] = [:]
    private var finishedUntil: [Int32: Date] = [:]   // "just finished" animation deadline per session
    private var animTick = 0
    private var placeholder: NSStatusItem?
    private var pollTimer: Timer?
    private var animTimer: Timer?
    private var animInterval: TimeInterval = 0
    private var watchers: [DispatchSourceFileSystemObject] = []

    // permission requests waiting for approve / deny
    private var visibleSessions: [Session] = []        // sessions that currently get an icon (hide-idle applied)
    private var pending: [PermissionRequest] = []
    private var announced = Set<String>()
    private var hookStatus: HookInstaller.Status = .installed

    // stuck diagnosis, cached so tooltips refreshing every 2s don't re-read transcripts
    private var diagCache: [String: (at: Date, text: String?)] = [:]

    // token usage
    private let counter = TokenCounter()
    private var usage = UsageSnapshot()
    private var tokenItem: NSStatusItem?
    private var tokenTimer: Timer?
    private var scanning = false

    /// Newest launch wins: an older copy (e.g. from a moved folder, or a stale login item) is asked to quit,
    /// so two ClaudeBars never fight over the menu bar.
    private func replaceOtherInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app.processIdentifier != getpid() {
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if !app.isTerminated { app.forceTerminate() } }
        }
    }

    /// Running `open ClaudeBar.app` again (or double-clicking it) opens Settings: the way back in when the icons are hidden.
    /// Clicking a notification sends a reopen too, so wait a beat for the click to register before deciding.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let reopenedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, ReopenPolicy.opensSettings(reopenAt: reopenedAt, lastNotificationClick: self.lastNotificationClick) else { return }
            self.openSettings()
        }
        return true
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if !selfTest { replaceOtherInstances() }
        settings = settingsStore.load()
        store.staleAfter = settings.staleAfter
        hookStatus = SettingsModel.installer(settings).status()

        notifier.onInteraction = { [weak self] in self?.lastNotificationClick = Date() }
        notifier.onDecision = { [weak self] id, verdict in self?.resolve(id, verdict) }
        notifier.onOpen = { [weak self] sessionId in
            if let s = self?.sessions.values.first(where: { $0.sessionId == sessionId }) { self?.focus(s) }
        }
        if !selfTest { notifier.start() }

        try? FileManager.default.createDirectory(at: store.markerDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: permissions.dir, withIntermediateDirectories: true)
        makeTokenItem()          // created first => sits rightmost, session icons to its left
        scanTokens()
        tokenTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scanTokens() }
        refresh()
        // Fallback poll (also catches pid death, which fires no fs event).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        for dir in [store.sessionsDir, store.markerDir, permissions.dir] { watch(dir) }
        if selfTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                print(self.snapshotJSON()); exit(0)
            }
        } else {
            visibilityTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.checkMenuBarVisibility() }
        }
    }

    // MARK: "are my icons actually on screen?"

    /// Our status item windows live at window layer 25. A full menu bar on a notch Mac leaves them off screen without any error.
    private func checkMenuBarVisibility() {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let flags = info
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int) == 25 }
            .map { $0[kCGWindowIsOnscreen as String] as? Bool ?? false }
        if visibility.observe(flags) { showHiddenAlert() }
    }

    private func showHiddenAlert() {
        let a = NSAlert()
        a.messageText = "ClaudeBar's menu bar icons are hidden"
        a.informativeText = "Your menu bar is full, so macOS hides new items (on notch Macs, anything that doesn't fit beside the notch). "
            + "Quit or ⌘-drag away a few other menu bar icons"
            + (settings.singleIcon ? "." : ", or turn on \"One icon for all sessions\" in Settings.")
            + " Opening ClaudeBar.app again always brings up Settings."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    /// What the menu bar would show, as JSON (used by Tests/smoke.sh).
    private func snapshotJSON() -> String {
        func entry(_ it: NSStatusItem) -> [String: Any] {
            ["tooltip": it.button?.toolTip ?? "", "hasImage": it.button?.image != nil, "title": it.button?.title ?? ""]
        }
        let sessionItems = (singleItem.map { [$0] } ?? items.sorted { $0.key < $1.key }.map(\.value)).map(entry)
        var d: [String: Any] = ["singleIcon": settings.singleIcon, "sessionItems": sessionItems,
                                "placeholder": placeholder != nil, "pending": pending.count, "animating": animTimer != nil]
        if let t = tokenItem { d["token"] = entry(t) }
        let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func watch(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers.append(src)
    }

    // MARK: refresh

    private func refresh() {
        let now = Date()
        permissions.prune()
        let list = store.load()
        sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) })

        let before = settings.mutedSessions
        settings.pruneMutes(keeping: Set(list.map(\.sessionId)))
        if settings.mutedSessions != before { settingsStore.save(settings) }

        // 1. state transitions -> alerts (for every live session, shown or not)
        let live = Set(list.map(\.pid))
        for pid in lastState.keys where !live.contains(pid) { lastState[pid] = nil; finishedUntil[pid] = nil }
        var alerts: [(Session, Alert)] = []
        for s in list.sorted(by: { $0.pid < $1.pid }) where lastState[s.pid] != s.state {
            if let a = AlertPolicy.alert(from: lastState[s.pid], to: s.state, muted: settings.isMuted(s.sessionId)) {
                alerts.append((s, a))
            }
            if let prev = lastState[s.pid], prev != .idle, s.state == .idle {
                finishedUntil[s.pid] = now.addingTimeInterval(TimeInterval(settings.finishBlinkSeconds))
            } else if s.state != .idle {
                finishedUntil[s.pid] = nil
            }
            lastState[s.pid] = s.state
        }

        // 2. permission requests
        pending = permissions.pending()
        announcePermissions()

        // 3. which sessions get a menu bar icon
        let pendingSessions = Set(pending.map(\.sessionId))
        let visible = list.filter {
            IconModel.isVisible(state: $0.state, hideIdle: settings.hideIdle,
                                finishing: (finishedUntil[$0.pid] ?? .distantPast) > now,
                                hasPendingPermission: pendingSessions.contains($0.sessionId))
        }
        visibleSessions = visible
        if settings.singleIcon {
            for pid in Array(items.keys) { NSStatusBar.system.removeStatusItem(items[pid]!); items[pid] = nil }
            if visible.isEmpty, let one = singleItem { NSStatusBar.system.removeStatusItem(one); singleItem = nil }
            if !visible.isEmpty && singleItem == nil { singleItem = makeSingleItem() }
        } else {
            if let one = singleItem { NSStatusBar.system.removeStatusItem(one); singleItem = nil }
            let shown = Set(visible.map(\.pid))
            for pid in Array(items.keys) where !shown.contains(pid) {
                NSStatusBar.system.removeStatusItem(items[pid]!)
                items[pid] = nil
            }
            for s in visible.sorted(by: { $0.pid < $1.pid }) where items[s.pid] == nil { _ = makeItem(for: s.pid) }
        }

        if visible.isEmpty {
            if placeholder == nil { placeholder = makePlaceholder() }
            placeholder?.button?.toolTip = list.isEmpty ? "No Claude sessions" : "All sessions idle (hidden)"
        } else if let p = placeholder {
            NSStatusBar.system.removeStatusItem(p)
            placeholder = nil
        }

        deliver(alerts)
        updateTooltips()
        updateIcons()
        updateAnimTimer()
    }

    // MARK: alerts

    private func deliver(_ alerts: [(Session, Alert)]) {
        guard !selfTest else { return }
        var sound = false
        var haptic: String?
        for (s, a) in alerts {
            let d = AlertPolicy.delivery(for: a, settings: settings)
            sound = sound || d.sound
            if let h = d.haptic, haptic == nil || h == "angry_alert" { haptic = h }   // stuck outranks finished
            if d.banner { banner(for: s, a) }
        }
        if sound { NSSound(named: "Ping")?.play() }
        if let haptic { Haptics.fire(haptic) }
    }

    private func banner(for s: Session, _ a: Alert) {
        let title: String, body: String
        switch a {
        case .needsInput:
            title = "\(s.name) needs you"
            if let r = pending.first(where: { $0.sessionId == s.sessionId }) {
                body = "\(r.toolName): \(snippet(r.summary, 120))"
            } else {
                body = usage.perSession[s.sessionId]?.lastText.map { snippet($0, 140) } ?? "Waiting for your input"
            }
        case .stuck:
            title = "\(s.name) looks stuck"
            body = diagnosis(s, fresh: true) ?? "No activity for \(Int(s.silentFor / 60)) min"
        case .finished:
            title = "\(s.name) finished"
            body = usage.perSession[s.sessionId]?.lastText.map { snippet($0, 140) } ?? "Done"
        }
        notifier.post(id: "alert-\(s.sessionId)-\(a)", title: title, body: body, sessionId: s.sessionId)
    }

    /// Banner (with Approve / Deny buttons) for each new permission request; withdraw those that are gone.
    private func announcePermissions() {
        let ids = Set(pending.map(\.id))
        var sound = false
        for r in pending where !announced.contains(r.id) {
            announced.insert(r.id)
            guard !settings.isMuted(r.sessionId) else { continue }
            sound = sound || settings.sound
            guard settings.notifications else { continue }
            let name = sessions.values.first { $0.sessionId == r.sessionId }?.name ?? "Claude"
            notifier.post(id: "perm-\(r.id)", title: "\(name): approve \(r.toolName)?",
                          body: snippet(r.summary, 160), sessionId: r.sessionId, permissionId: r.id)
        }
        let gone = announced.subtracting(ids)
        if !gone.isEmpty { notifier.withdraw(ids: gone.map { "perm-\($0)" }); announced.subtract(gone) }
        if sound && !selfTest { NSSound(named: "Ping")?.play() }
    }

    private func resolve(_ id: String, _ verdict: PermissionVerdict) {
        do { try permissions.decide(id, verdict) } catch { NSSound.beep() }
        pending.removeAll { $0.id == id }
        notifier.withdraw(ids: ["perm-\(id)"])
        refresh()
    }

    /// Why a session is quiet: a tool that never returned, or a model that went silent after one did.
    private func diagnosis(_ s: Session, fresh: Bool = false) -> String? {
        if !fresh, let c = diagCache[s.sessionId], Date().timeIntervalSince(c.at) < 15 { return c.text }
        let text = store.lastToolCall(sessionId: s.sessionId, cwd: s.cwd).map { ToolActivity.describe($0) }
        diagCache[s.sessionId] = (Date(), text)
        return text
    }

    // MARK: status items

    private func makeItem(for pid: Int32) -> NSStatusItem {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.tag = Int(pid)
        it.button?.target = self
        it.button?.action = #selector(clicked(_:))
        it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        items[pid] = it
        return it
    }

    private func makeSingleItem() -> NSStatusItem {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.imagePosition = .imageLeft
        it.button?.target = self
        it.button?.action = #selector(singleClicked(_:))
        it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return it
    }

    private func makePlaceholder() -> NSStatusItem {
        let p = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        p.button?.image = symbol("moon.zzz", .tertiaryLabelColor)
        let m = NSMenu()
        m.addItem(withTitle: "No Claude sessions", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        addFooter(to: m)
        p.menu = m
        return p
    }

    private func tooltip(for s: Session) -> String {
        let quiet = (s.state == .stuck || s.state == .running) ? " (no activity \(Int(s.silentFor / 60))m)" : ""
        let muted = settings.isMuted(s.sessionId) ? " · muted" : ""
        var t = "\(s.name) — \(label(s.state))\(quiet)\(muted)\n\(s.cwd)" + detail(for: s, withLast: true)
        for r in pending where r.sessionId == s.sessionId {
            t += "\nApproval needed: \(r.toolName) \(snippet(r.summary, 80))"
        }
        if s.state == .stuck, let d = diagnosis(s) { t += "\nDiagnosis: " + d }
        return t + "\n(click: focus in Ghostty · right-click: menu)"
    }

    private func updateTooltips() {
        for (pid, it) in items { if let s = sessions[pid] { it.button?.toolTip = tooltip(for: s) } }
        guard let one = singleItem else { return }
        let rows = visibleSessions.sorted { ($0.state, $1.name) > ($1.state, $0.name) }.map { s -> String in
            let ask = pending.contains { $0.sessionId == s.sessionId } ? " · approval needed" : ""
            let mute = settings.isMuted(s.sessionId) ? " · muted" : ""
            return "• \(s.name) — \(label(s.state))\(ask)\(mute)"
        }
        one.button?.toolTip = rows.joined(separator: "\n") + "\n(click: focus / list · right-click: list)"
    }

    // MARK: icons + "just finished" animation

    private func updateIcons() {
        let now = Date()
        for (pid, it) in items {
            guard let s = sessions[pid] else { continue }
            let kind = IconModel.kind(state: s.state, finishedUntil: finishedUntil[pid], tick: animTick, now: now)
            it.button?.image = cachedIcon(kind, angle: spinAngle(), fraction: usage.perSession[s.sessionId]?.contextFraction,
                                          muted: settings.isMuted(s.sessionId))
        }
        updateSingleIcon(now: now)
    }

    private func updateSingleIcon(now: Date) {
        guard let one = singleItem,
              let sum = IconModel.summary(states: visibleSessions.map(\.state),
                                          finishedUntil: visibleSessions.compactMap { finishedUntil[$0.pid] }.max(),
                                          tick: animTick, now: now) else { return }
        let fraction = visibleSessions.compactMap { usage.perSession[$0.sessionId]?.contextFraction }.max()
        let allMuted = !visibleSessions.isEmpty && visibleSessions.allSatisfy { settings.isMuted($0.sessionId) }
        one.button?.image = cachedIcon(sum.kind, angle: spinAngle(), fraction: fraction, muted: allMuted)
        one.button?.title = sum.badge.map { " \($0)" } ?? ""
    }

    /// Finished icon (glyph + context bar + mute dimming). Spinning redraws ~10x/s, so each distinct frame is built once.
    private var iconCache: [String: NSImage] = [:]
    private func cachedIcon(_ kind: IconKind, angle: CGFloat, fraction: Double?, muted: Bool) -> NSImage? {
        let key = "\(kind)|\(kind == .running ? Int(angle) : 0)|\(fraction.map { Int($0 * 100) } ?? -1)|\(muted)"
        if let hit = iconCache[key] { return hit }
        var img = withContextBar(kind == .running ? rotated(image(kind), degrees: angle) : image(kind), fraction: fraction)
        if muted { img = dimmed(img) }
        if iconCache.count > 600 { iconCache.removeAll() }
        if let img { iconCache[key] = img }
        return img
    }

    /// Context-window gauge: thin vertical bar right of the icon.
    private func withContextBar(_ base: NSImage?, fraction: Double?) -> NSImage? {
        guard let base, let fraction else { return base }
        let barW: CGFloat = 3, gap: CGFloat = 3, h: CGFloat = 16
        let size = NSSize(width: base.size.width + gap + barW, height: max(h, base.size.height))
        let color: NSColor
        switch IconModel.contextLevel(fraction) {
        case .critical: color = .systemRed
        case .warn: color = .systemOrange
        case .ok: color = .systemGreen
        }
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: (rect.height - base.size.height) / 2,
                                 width: base.size.width, height: base.size.height))
            let barH = rect.height - 2
            let x = base.size.width + gap
            let track = NSRect(x: x, y: 1, width: barW, height: barH)
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            let fillH = max(2, barH * CGFloat(fraction))
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: barW, height: fillH), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Muted sessions are drawn faded.
    private func dimmed(_ base: NSImage?) -> NSImage? {
        guard let base else { return nil }
        let img = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Spinning needs ~10 redraws/s; the finish blink alone only ~3/s.
    private var isSpinning: Bool {
        settings.animateRunning && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && visibleSessions.contains { $0.state == .running }
    }

    private func updateAnimTimer() {
        let now = Date()
        finishedUntil = finishedUntil.filter { $0.value > now }
        let spinning = isSpinning
        guard spinning || !finishedUntil.isEmpty else {
            animTimer?.invalidate(); animTimer = nil
            return
        }
        let interval: TimeInterval = spinning ? 0.1 : 0.35
        guard animTimer == nil || animInterval != interval else { return }
        animTimer?.invalidate()
        animInterval = interval
        animTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.animTick = Int(Date().timeIntervalSinceReferenceDate / 0.35)   // blink phase from the clock
            self.updateIcons()
            self.updateAnimTimer()
        }
    }

    /// Rotates an icon around its centre (the running spinner).
    private func rotated(_ base: NSImage?, degrees: CGFloat) -> NSImage? {
        guard let base, degrees != 0 else { return base }
        let img = NSImage(size: base.size, flipped: false) { rect in
            let t = NSAffineTransform()
            t.translateX(by: rect.midX, yBy: rect.midY)
            t.rotate(byDegrees: -degrees)            // clockwise
            t.translateX(by: -rect.midX, yBy: -rect.midY)
            t.concat()
            base.draw(in: rect)
            return true
        }
        img.isTemplate = false
        return img
    }

    private func spinAngle() -> CGFloat {
        isSpinning ? CGFloat(IconModel.spinDegrees(now: Date())) : 0
    }

    private func label(_ s: SessionState) -> String {
        switch s { case .stuck: return "stuck"; case .waiting: return "waiting"; case .running: return "running"; case .idle: return "idle" }
    }

    private func image(_ kind: IconKind) -> NSImage? {
        switch kind {
        case .stuck:           return symbol("exclamationmark.triangle.fill", .systemRed)
        case .waiting:         return symbol("exclamationmark.bubble.fill", .systemOrange)
        case .running:         return symbol("arrow.triangle.2.circlepath", .systemGreen)
        case .idle:            return symbol("pause.circle.fill", .systemGray)
        case .finishedFilled:  return symbol("checkmark.circle.fill", .systemGreen)
        case .finishedOutline: return symbol("checkmark.circle", .systemGreen)
        }
    }

    private func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        // Two-layer filled symbols: white glyph (primary) on colored shape (secondary), else the glyph vanishes.
        let twoLayer = name.contains("circle.fill") || name.contains("bubble.fill") || name.contains("triangle.fill")
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Claude session")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: twoLayer ? [.white, color] : [color]))
        img?.isTemplate = false
        return img
    }

    // MARK: token usage

    private func snippet(_ t: String, _ n: Int) -> String {
        let one = t.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    private func detail(for s: Session, withLast: Bool) -> String {
        guard let u = usage.perSession[s.sessionId] else { return "" }
        var out = "\nToday \(Fmt.millions(u.today.total)) · context \(Fmt.compact(u.contextTokens))/\(Fmt.compact(u.contextWindow)) (\(Int(u.contextFraction * 100))%)"
        if withLast, let last = u.lastText { out += "\nLast: " + snippet(last, 200) }
        return out
    }

    private func makeTokenItem() {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = symbol("bolt.fill", .systemYellow)
        let m = NSMenu()
        m.delegate = self          // rebuilt on open so numbers are current
        it.menu = m
        tokenItem = it
        applyTokenStyle()
    }

    /// Bolt alone by default (narrow); with "show token count" the total sits beside it.
    private func applyTokenStyle() {
        guard let b = tokenItem?.button else { return }
        let total = usage.total.total
        b.title = settings.showTokenText ? " " + (total > 0 ? Fmt.millions(total) : "…") : ""
        b.imagePosition = settings.showTokenText ? .imageLeft : .imageOnly
        b.toolTip = total > 0 ? "Tokens used today: \(Fmt.millions(total)) (incl. cache reads)" : "Tokens used today (incl. cache reads)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tokenItem?.menu else { return }
        menu.removeAllItems()
        if hookStatus != .installed {
            let fix = NSMenuItem(title: "⚠︎ Hooks \(hookStatus == .notInstalled ? "not installed" : "need repair"), open Settings…",
                                 action: #selector(openSettings), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(.separator())
        }
        if !pending.isEmpty {
            menu.addItem(withTitle: "Waiting for approval", action: nil, keyEquivalent: "")
            addPermissionItems(to: menu, for: pending)
            menu.addItem(.separator())
        }
        let t = usage.total
        menu.addItem(withTitle: "Today: \(Fmt.millions(t.total)) tokens", action: nil, keyEquivalent: "")
        for (name, v) in [("Input", t.input), ("Output", t.output), ("Cache write", t.cacheWrite), ("Cache read", t.cacheRead)] {
            menu.addItem(withTitle: "    \(name): \(Fmt.millions(v))", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        let live = sessions.values.sorted { (usage.perSession[$0.sessionId]?.today.total ?? 0) > (usage.perSession[$1.sessionId]?.today.total ?? 0) }
        for s in live {
            let u = usage.perSession[s.sessionId]
            let ctx = u.map { " · ctx \(Int($0.contextFraction * 100))%" } ?? ""
            menu.addItem(withTitle: "\(s.name): \(Fmt.millions(u?.today.total ?? 0))\(ctx)", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        addFooter(to: menu)
    }

    private func addFooter(to menu: NSMenu) {
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(withTitle: "Quit ClaudeBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func scanTokens() {
        guard !scanning else { return }
        scanning = true
        let live = Set(sessions.values.map(\.sessionId))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snap = self.counter.scan(liveSessionIds: live)
            DispatchQueue.main.async {
                self.usage = snap
                self.scanning = false
                self.applyTokenStyle()
                self.updateIcons()
                self.updateTooltips()   // pick up the new numbers
            }
        }
    }

    // MARK: clicks + menus

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let pid = Int32(sender.tag)
        guard let s = sessions[pid], let it = items[pid] else { return }
        finishedUntil[pid] = nil   // acknowledged
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            it.menu = menu(for: s)
            it.button?.performClick(nil)   // shows the menu
            it.menu = nil                  // so left-click keeps hitting the action
        } else {
            focus(s)
        }
        updateIcons()
    }

    @objc private func singleClicked(_ sender: NSStatusBarButton) {
        guard let it = singleItem else { return }
        let e = NSApp.currentEvent
        let wantsList = e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true
        if !wantsList, visibleSessions.count == 1, let only = visibleSessions.first {
            finishedUntil[only.pid] = nil      // acknowledged
            focus(only)
            updateIcons()
            return
        }
        visibleSessions.forEach { finishedUntil[$0.pid] = nil }
        it.menu = singleMenu()
        it.button?.performClick(nil)
        it.menu = nil
        updateIcons()
    }

    /// One row per session (state glyph, submenu with the full per-session menu), then approvals and totals.
    private func singleMenu() -> NSMenu {
        let m = NSMenu()
        if !pending.isEmpty {
            m.addItem(withTitle: "Waiting for approval", action: nil, keyEquivalent: "")
            addPermissionItems(to: m, for: pending)
            m.addItem(.separator())
        }
        for s in visibleSessions.sorted(by: { ($0.state, $1.name) > ($1.state, $0.name) }) {
            let ask = pending.contains { $0.sessionId == s.sessionId } ? " · approval needed" : ""
            let row = NSMenuItem(title: "\(s.name) — \(label(s.state))\(ask)", action: nil, keyEquivalent: "")
            if let img = image(IconModel.kind(state: s.state, finishedUntil: nil, tick: 0, now: Date())) {
                img.size = NSSize(width: 15, height: 15)
                row.image = img
            }
            row.submenu = menu(for: s, footer: false)
            m.addItem(row)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Today: \(Fmt.millions(usage.total.total)) tokens", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        addFooter(to: m)
        return m
    }

    private func menu(for s: Session, footer: Bool = true) -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: s.name, action: nil, keyEquivalent: "")
        m.addItem(withTitle: "State: \(label(s.state))", action: nil, keyEquivalent: "")
        m.addItem(withTitle: s.cwd, action: nil, keyEquivalent: "")
        if let u = usage.perSession[s.sessionId] {
            m.addItem(withTitle: "Today: \(Fmt.millions(u.today.total)) tokens", action: nil, keyEquivalent: "")
            m.addItem(withTitle: "Context: \(Fmt.compact(u.contextTokens)) / \(Fmt.compact(u.contextWindow)) (\(Int(u.contextFraction * 100))%)", action: nil, keyEquivalent: "")
            if let last = u.lastText { m.addItem(withTitle: "Last: " + snippet(last, 70), action: nil, keyEquivalent: "") }
        }
        if s.state == .running || s.state == .stuck, let d = diagnosis(s, fresh: true) {
            m.addItem(withTitle: snippet(d.prefix(1).uppercased() + d.dropFirst(), 90), action: nil, keyEquivalent: "")
        }
        let reqs = pending.filter { $0.sessionId == s.sessionId }
        if !reqs.isEmpty {
            m.addItem(.separator())
            addPermissionItems(to: m, for: reqs)
        }
        m.addItem(.separator())
        let focus = NSMenuItem(title: "Focus in Ghostty", action: #selector(menuFocus(_:)), keyEquivalent: "")
        focus.target = self
        focus.representedObject = NSNumber(value: s.pid)
        m.addItem(focus)
        let open = NSMenuItem(title: "Open folder in Terminal", action: #selector(openCwd(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = s.cwd
        m.addItem(open)
        let mute = NSMenuItem(title: "Mute alerts for this session", action: #selector(toggleMute(_:)), keyEquivalent: "")
        mute.target = self
        mute.state = settings.isMuted(s.sessionId) ? .on : .off
        mute.representedObject = s.sessionId
        m.addItem(mute)
        if footer {
            m.addItem(.separator())
            addFooter(to: m)
        }
        return m
    }

    private func addPermissionItems(to menu: NSMenu, for reqs: [PermissionRequest]) {
        for r in reqs {
            let who = sessions.values.first { $0.sessionId == r.sessionId }?.name ?? "Claude"
            menu.addItem(withTitle: "\(who): \(r.toolName) \(snippet(r.summary, 60))", action: nil, keyEquivalent: "")
            for (title, verdict) in [("    Approve", PermissionVerdict.allow), ("    Deny", .deny)] {
                let it = NSMenuItem(title: title, action: #selector(decide(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = PermissionChoice(r.id, verdict)
                menu.addItem(it)
            }
        }
    }

    @objc private func decide(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? PermissionChoice else { return }
        resolve(c.id, c.verdict)
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.setMuted(!settings.isMuted(id), sessionId: id)
        settingsStore.save(settings)
        settingsModel?.settings = settings
        updateTooltips(); updateIcons()
    }

    @objc private func menuFocus(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? NSNumber, let s = sessions[n.int32Value] { focus(s) }
    }

    private func focus(_ s: Session) {
        let title = store.title(sessionId: s.sessionId, cwd: s.cwd)
        let terms = GhosttyMatcher.parse(Ghostty.listTerminals())
        if let id = GhosttyMatcher.pick(terms, title: title, cwd: s.cwd, busy: GhosttyMatcher.busyHint(for: s.state)) {
            Ghostty.focus(id)
        } else {
            Ghostty.activate()   // not in a Ghostty tab we can find
        }
    }

    @objc private func openCwd(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, !path.isEmpty else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: settings

    @objc private func openSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(settings: settings) { [weak self] new, old in self?.settingsChanged(new, old) }
            settingsModel = model
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsWindow?.show()
    }

    private func settingsChanged(_ new: Settings, _ old: Settings) {
        guard new != settings else { return }       // echo of a change made from the menu
        settings = new
        settingsStore.save(new)
        store.staleAfter = new.staleAfter
        if new.permissionPrompts != old.permissionPrompts,
           SettingsModel.installer(old).status() != .notInstalled {
            try? SettingsModel.installer(new).install()     // add / drop the PermissionRequest hook
        }
        hookStatus = SettingsModel.installer(new).status()
        settingsModel?.refreshHookStatus()
        applyTokenStyle()
        refresh()
        updateAnimTimer()
    }
}
