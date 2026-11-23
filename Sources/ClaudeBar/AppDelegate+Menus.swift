import AppKit
import ClaudeBarCore

/// Payload of an Approve / Deny menu item.
private final class PermissionChoice: NSObject {
    let id: String, verdict: PermissionVerdict
    init(_ id: String, _ verdict: PermissionVerdict) { self.id = id; self.verdict = verdict }
}

// Everything that builds or reacts to NSMenus. Text comes from `SessionText` (tested); this file only lays it out.
extension AppDelegate: NSMenuDelegate {
    /// The bolt menu is rebuilt each time it opens so the numbers are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tokenItem?.menu else { return }
        menu.removeAllItems()
        if hookStatus != .installed {
            let what = hookStatus == .notInstalled ? "not installed" : "need repair"
            let fix = NSMenuItem(title: "⚠︎ Hooks \(what), open Settings…", action: #selector(openSettings), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(.separator())
        }
        if !pending.isEmpty {
            menu.addItem(withTitle: "Waiting for approval", action: nil, keyEquivalent: "")
            addPermissionItems(to: menu, for: pending)
            menu.addItem(.separator())
        }
        let lines = SessionText.tokenLines(usage.total)
        menu.addItem(withTitle: lines[0], action: nil, keyEquivalent: "")
        lines.dropFirst().forEach { menu.addItem(withTitle: $0, action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        for s in SessionText.listOrder(Array(sessions.values)) {   // click a row to jump to that session's tab
            let row = actionItem(SessionText.tokenRow(s, usage: usage.perSession[s.sessionId]),
                                 #selector(menuFocus(_:)), object: NSNumber(value: s.pid))
            if let img = renderer.glyph(IconModel.kind(state: s.state, finishedUntil: nil, tick: 0, now: Date())) {
                img.size = NSSize(width: 15, height: 15)
                row.image = img
            }
            menu.addItem(row)
        }
        menu.addItem(.separator())
        addFooter(to: menu)
    }

    func addFooter(to menu: NSMenu) {
        let about = NSMenuItem(title: "ClaudeBar \(AppInfo.version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(withTitle: "Quit ClaudeBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// One row per session (state glyph, submenu with the full per-session menu), then approvals and totals.
    func singleMenu() -> NSMenu {
        let m = NSMenu()
        if !pending.isEmpty {
            m.addItem(withTitle: "Waiting for approval", action: nil, keyEquivalent: "")
            addPermissionItems(to: m, for: pending)
            m.addItem(.separator())
        }
        for s in SessionText.listOrder(visibleSessions) {
            let ask = pending.contains { $0.sessionId == s.sessionId }
            let row = NSMenuItem(title: SessionText.rowTitle(s, hasApproval: ask), action: nil, keyEquivalent: "")
            if let img = renderer.glyph(IconModel.kind(state: s.state, finishedUntil: nil, tick: 0, now: Date())) {
                img.size = NSSize(width: 15, height: 15)
                row.image = img
            }
            row.submenu = menu(for: s, footer: false)
            m.addItem(row)
        }
        m.addItem(.separator())
        m.addItem(withTitle: SessionText.tokenLines(usage.total)[0], action: nil, keyEquivalent: "")
        m.addItem(.separator())
        addFooter(to: m)
        return m
    }

    func menu(for s: Session, footer: Bool = true) -> NSMenu {
        let m = NSMenu()
        let diag = s.state == .running || s.state == .stuck ? diagnosis(s, fresh: true) : nil
        for line in SessionText.menuLines(for: s, usage: usage.perSession[s.sessionId], diagnosis: diag) {
            m.addItem(withTitle: line, action: nil, keyEquivalent: "")
        }
        let reqs = pending.filter { $0.sessionId == s.sessionId }
        if !reqs.isEmpty {
            m.addItem(.separator())
            addPermissionItems(to: m, for: reqs)
        }
        m.addItem(.separator())
        m.addItem(actionItem("Focus in Ghostty", #selector(menuFocus(_:)), object: NSNumber(value: s.pid)))
        m.addItem(actionItem("Open folder in Terminal", #selector(openCwd(_:)), object: s.cwd))
        let mute = actionItem("Mute alerts for this session", #selector(toggleMute(_:)), object: s.sessionId)
        mute.state = settings.isMuted(s.sessionId) ? .on : .off
        m.addItem(mute)
        if footer {
            m.addItem(.separator())
            addFooter(to: m)
        }
        return m
    }

    private func actionItem(_ title: String, _ action: Selector, object: Any) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        it.representedObject = object
        return it
    }

    func addPermissionItems(to menu: NSMenu, for reqs: [PermissionRequest]) {
        for r in reqs {
            let who = sessions.values.first { $0.sessionId == r.sessionId }?.name ?? "Claude"
            menu.addItem(withTitle: "\(who): \(r.toolName) \(SessionText.snippet(r.summary, 60))", action: nil, keyEquivalent: "")
            for (title, verdict) in [("    Approve", PermissionVerdict.allow), ("    Deny", .deny)] {
                menu.addItem(actionItem(title, #selector(decide(_:)), object: PermissionChoice(r.id, verdict)))
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
        updateTooltips()
        updateIcons()
    }

    /// Same as clicking the session's icon: acknowledges a finished job, then jumps to its tab.
    @objc private func menuFocus(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber, let s = sessions[n.int32Value] else { return }
        tracker.acknowledge(s.pid, lingerSeconds: settings.finishLingerSeconds)
        focus(s)
        updateIcons()
    }

    @objc private func openCwd(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, !path.isEmpty else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }
}
