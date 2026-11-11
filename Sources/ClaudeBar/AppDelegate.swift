import AppKit
import ClaudeBarCore

/// Owns the menu bar items and the refresh loop. Decisions live in ClaudeBarCore (alerts, tracking, text);
/// drawing lives in `IconRenderer`; menus live in `AppDelegate+Menus.swift`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // data sources
    var store = SessionStore()
    let settingsStore = SettingsStore()
    var settings = Settings()
    let permissions = PermissionStore()
    let counter = TokenCounter()

    // collaborators
    let notifier = Notifier()
    let renderer = IconRenderer()
    var settingsModel: SettingsModel?
    var settingsWindow: SettingsWindowController?

    // derived state
    var tracker = SessionTracker()
    var announcements = PermissionAnnouncements()
    var sessions: [Int32: Session] = [:]
    var visibleSessions: [Session] = []          // sessions that currently get an icon (hide-idle applied)
    var pending: [PermissionRequest] = []
    var usage = UsageSnapshot()
    var hookStatus: HookInstaller.Status = .installed
    private var visibility = MenuBarVisibility()
    private var lastNotificationClick = Date.distantPast
    // stuck diagnosis, cached so tooltips refreshing every 2s don't re-read transcripts
    private var diagCache: [String: (at: Date, text: String?)] = [:]

    // menu bar items
    var items: [Int32: NSStatusItem] = [:]       // per-session mode
    var singleItem: NSStatusItem?                // single-icon mode: one item for every session
    var placeholder: NSStatusItem?
    var tokenItem: NSStatusItem?

    // timers and watchers
    private var pollTimer: Timer?
    private var tokenTimer: Timer?
    private var visibilityTimer: Timer?
    private var animTimer: Timer?
    private var animInterval: TimeInterval = 0
    private var animTick = 0
    private var scanning = false
    private var watchers: [DispatchSourceFileSystemObject] = []

    /// `--selftest`: run against CLAUDEBAR_HOME, print what the menu bar would show as JSON, exit. No sound/alerts/instance kill.
    private let selfTest: Bool

    init(selfTest: Bool = false) {
        self.selfTest = selfTest
        super.init()
    }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                print(self.snapshotJSON())
                exit(0)
            }
        } else {
            visibilityTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                self?.checkMenuBarVisibility()
            }
        }
    }

    /// Newest launch wins: an older copy (e.g. from a moved folder, or a stale login item) is asked to quit,
    /// so two ClaudeBars never fight over the menu bar.
    private func replaceOtherInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() }
        for app in others {
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if !app.isTerminated { app.forceTerminate() } }
        }
    }

    /// Running `open ClaudeBar.app` again (or double-clicking it) opens Settings: the way back in when the icons are hidden.
    /// Clicking a notification sends a reopen too, so wait a beat for the click to register before deciding.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let reopenedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self,
                  ReopenPolicy.opensSettings(reopenAt: reopenedAt, lastNotificationClick: self.lastNotificationClick) else { return }
            self.openSettings()
        }
        return true
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
        a.informativeText = "Your menu bar is full, so macOS hides new items "
            + "(on notch Macs, anything that doesn't fit beside the notch). "
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
        if let m = tokenItem?.menu {
            menuNeedsUpdate(m)
            d["tokenMenu"] = m.items.map { ["title": $0.title, "clickable": $0.action != nil] as [String: Any] }
        }
        let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: refresh

    func refresh() {
        let now = Date()
        permissions.prune()
        let list = store.load()
        sessions = Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) })
        pruneMutes(keeping: list)

        let current = settings
        let alerts = tracker.update(list, now: now, blinkSeconds: settings.finishBlinkSeconds) { current.isMuted($0) }
        pending = permissions.pending()
        announcePermissions()

        visibleSessions = tracker.visible(list, hideIdle: settings.hideIdle,
                                          pendingSessionIds: Set(pending.map(\.sessionId)), now: now)
        syncStatusItems(totalSessions: list.count)

        deliver(alerts)
        updateTooltips()
        updateIcons()
        updateAnimTimer()
    }

    private func pruneMutes(keeping list: [Session]) {
        let before = settings.mutedSessions
        settings.pruneMutes(keeping: Set(list.map(\.sessionId)))
        if settings.mutedSessions != before { settingsStore.save(settings) }
    }

    // MARK: alerts

    private func deliver(_ alerts: [(session: Session, alert: Alert)]) {
        guard !selfTest else { return }
        var sound: (name: String, volume: Float)?
        var haptic: String?
        for (s, a) in alerts {
            let d = AlertPolicy.delivery(for: a, settings: settings)
            // one sound per refresh; attention (errors, "needs you") outranks the finish bell
            if let name = d.sound, sound == nil || a != .finished { sound = (name, d.volume) }
            if let h = d.haptic, haptic == nil || h == "angry_alert" { haptic = h }   // stuck outranks finished
            if d.banner { banner(for: s, a) }
        }
        if let sound { Sounds.play(sound.name, volume: sound.volume) }
        if let haptic { Haptics.fire(haptic) }
    }

    private func banner(for s: Session, _ a: Alert) {
        let text = SessionText.bannerText(a, session: s, request: pending.first { $0.sessionId == s.sessionId },
                                          usage: usage.perSession[s.sessionId],
                                          diagnosis: a == .stuck ? diagnosis(s, fresh: true) : nil)
        notifier.post(id: "alert-\(s.sessionId)-\(a)", title: text.title, body: text.body, sessionId: s.sessionId)
    }

    /// Banner (with Approve / Deny buttons) for each new permission request; withdraw those that are gone.
    private func announcePermissions() {
        let diff = announcements.update(pending)
        var sound = false
        for r in diff.new where !settings.isMuted(r.sessionId) {
            sound = sound || settings.sound
            guard settings.notifications else { continue }
            let name = sessions.values.first { $0.sessionId == r.sessionId }?.name
            let text = SessionText.permissionBanner(r, sessionName: name)
            notifier.post(id: "perm-\(r.id)", title: text.title, body: text.body, sessionId: r.sessionId, permissionId: r.id)
        }
        if !diff.gone.isEmpty { notifier.withdraw(ids: diff.gone.map { "perm-\($0)" }) }
        if sound && !selfTest { Sounds.play(AlertPolicy.attentionSound) }
    }

    func resolve(_ id: String, _ verdict: PermissionVerdict) {
        do { try permissions.decide(id, verdict) } catch { NSSound.beep() }
        pending.removeAll { $0.id == id }
        notifier.withdraw(ids: ["perm-\(id)"])
        refresh()
    }

    /// Why a session is quiet: a tool that never returned, or a model that went silent after one did.
    func diagnosis(_ s: Session, fresh: Bool = false) -> String? {
        if !fresh, let c = diagCache[s.sessionId], Date().timeIntervalSince(c.at) < 15 { return c.text }
        let text = store.lastToolCall(sessionId: s.sessionId, cwd: s.cwd).map { ToolActivity.describe($0) }
        diagCache[s.sessionId] = (Date(), text)
        return text
    }

    // MARK: status items

    /// Create / remove menu bar items so they match the mode (single or per-session) and the visible sessions.
    private func syncStatusItems(totalSessions: Int) {
        if settings.singleIcon {
            removeSessionItems()
            if visibleSessions.isEmpty, let one = singleItem { NSStatusBar.system.removeStatusItem(one); singleItem = nil }
            if !visibleSessions.isEmpty && singleItem == nil { singleItem = makeSingleItem() }
        } else {
            if let one = singleItem { NSStatusBar.system.removeStatusItem(one); singleItem = nil }
            let shown = Set(visibleSessions.map(\.pid))
            removeSessionItems(except: shown)
            for s in visibleSessions.sorted(by: { $0.pid < $1.pid }) where items[s.pid] == nil { items[s.pid] = makeItem(for: s.pid) }
        }

        if visibleSessions.isEmpty {
            if placeholder == nil { placeholder = makePlaceholder() }
            placeholder?.button?.toolTip = totalSessions == 0 ? "No Claude sessions" : "All sessions idle (hidden)"
        } else if let p = placeholder {
            NSStatusBar.system.removeStatusItem(p)
            placeholder = nil
        }
    }

    private func removeSessionItems(except keep: Set<Int32> = []) {
        for pid in Array(items.keys) where !keep.contains(pid) {
            if let it = items[pid] { NSStatusBar.system.removeStatusItem(it) }
            items[pid] = nil
        }
    }

    private func makeItem(for pid: Int32) -> NSStatusItem {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.tag = Int(pid)
        it.button?.target = self
        it.button?.action = #selector(clicked(_:))
        it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        p.button?.image = renderer.symbol("moon.zzz", .tertiaryLabelColor)
        let m = NSMenu()
        m.addItem(withTitle: "No Claude sessions", action: nil, keyEquivalent: "")
        m.addItem(.separator())
        addFooter(to: m)
        p.menu = m
        return p
    }

    func updateTooltips() {
        let muted = Set(settings.mutedSessions)
        for (pid, it) in items {
            guard let s = sessions[pid] else { continue }
            it.button?.toolTip = SessionText.tooltip(
                for: s, usage: usage.perSession[s.sessionId], pending: pending, muted: muted.contains(s.sessionId),
                diagnosis: s.state == .stuck ? diagnosis(s) : nil)
        }
        singleItem?.button?.toolTip = SessionText.singleTooltip(visibleSessions, pending: pending, mutedIds: muted)
    }

    // MARK: icons + animation

    func updateIcons() {
        let now = Date()
        for (pid, it) in items {
            guard let s = sessions[pid] else { continue }
            let kind = IconModel.kind(state: s.state, finishedUntil: tracker.finishedUntil[pid],
                                      lingerUntil: tracker.lingerUntil[pid], tick: animTick, now: now)
            it.button?.image = renderer.icon(kind, angle: spinAngle(), contextFraction: usage.perSession[s.sessionId]?.contextFraction,
                                             muted: settings.isMuted(s.sessionId))
        }
        updateSingleIcon(now: now)
    }

    private func updateSingleIcon(now: Date) {
        guard let one = singleItem,
              let sum = IconModel.summary(states: visibleSessions.map(\.state),
                                          finishedUntil: tracker.latestFinish(of: visibleSessions.map(\.pid)),
                                          lingerUntil: tracker.latestLinger(of: visibleSessions.map(\.pid)),
                                          tick: animTick, now: now) else { return }
        let fraction = visibleSessions.compactMap { usage.perSession[$0.sessionId]?.contextFraction }.max()
        let allMuted = !visibleSessions.isEmpty && visibleSessions.allSatisfy { settings.isMuted($0.sessionId) }
        one.button?.image = renderer.icon(sum.kind, angle: spinAngle(), contextFraction: fraction, muted: allMuted)
        one.button?.title = sum.badge.map { " \($0)" } ?? ""
    }

    /// Spinning needs ~10 redraws/s; the finish blink alone only ~3/s.
    private var isSpinning: Bool {
        settings.animateRunning && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && visibleSessions.contains { $0.state == .running }
    }

    private func spinAngle() -> CGFloat {
        isSpinning ? CGFloat(IconModel.spinDegrees(now: Date())) : 0
    }

    func updateAnimTimer() {
        tracker.expire(now: Date())
        let spinning = isSpinning
        guard spinning || tracker.hasFinishing else {
            animTimer?.invalidate()
            animTimer = nil
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

    // MARK: token usage

    private func makeTokenItem() {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = renderer.symbol("bolt.fill", .systemYellow)
        let m = NSMenu()
        m.delegate = self
        it.menu = m
        tokenItem = it
        applyTokenStyle()
    }

    /// Bolt alone by default (narrow); with "show token count" the total sits beside it.
    func applyTokenStyle() {
        guard let b = tokenItem?.button else { return }
        let total = usage.total.total
        b.title = settings.showTokenText ? " " + (total > 0 ? Fmt.millions(total) : "…") : ""
        b.imagePosition = settings.showTokenText ? .imageLeft : .imageOnly
        b.toolTip = total > 0 ? "Tokens used today: \(Fmt.millions(total)) (incl. cache reads)" : "Tokens used today (incl. cache reads)"
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

    // MARK: clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let pid = Int32(sender.tag)
        guard let s = sessions[pid], let it = items[pid] else { return }
        tracker.acknowledge(pid, lingerSeconds: settings.finishLingerSeconds)
        if wantsMenu() {
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
        visibleSessions.forEach { tracker.acknowledge($0.pid, lingerSeconds: settings.finishLingerSeconds) }
        if !wantsMenu(), visibleSessions.count == 1, let only = visibleSessions.first {
            focus(only)
        } else {
            it.menu = singleMenu()
            it.button?.performClick(nil)
            it.menu = nil
        }
        updateIcons()
    }

    /// Right-click or control-click asks for the menu; a plain click acts.
    private func wantsMenu() -> Bool {
        let e = NSApp.currentEvent
        return e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true
    }

    func focus(_ s: Session) {
        let terms = GhosttyMatcher.parse(Ghostty.listTerminals())
        if let hit = Ghostty.tab(for: s, store: store, terms: terms) {
            Ghostty.focus(hit.tab.id)
        } else {
            Ghostty.activate()   // not in a Ghostty tab we can find
        }
    }

    // MARK: settings

    @objc func openSettings() {
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
