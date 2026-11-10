import AppKit
import SwiftUI
import ClaudeBarCore

typealias UserSettings = ClaudeBarCore.Settings

/// Where the hook scripts to install live: app bundle resources, else the repo next to a dev build.
enum HookSource {
    static func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("hooks")) }
        if let exe = Bundle.main.executableURL {   // .build/<config>/ClaudeBar  ->  repo root
            candidates.append(exe.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("hooks"))
        }
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("mark.sh").path) }
    }
}

final class SettingsModel: ObservableObject {
    @Published var settings: UserSettings {
        didSet { if settings != oldValue { onChange(settings, oldValue) } }
    }
    @Published var hookStatus: HookInstaller.Status
    @Published var hookMessage = ""
    private let onChange: (UserSettings, UserSettings) -> Void

    init(settings: UserSettings, onChange: @escaping (UserSettings, UserSettings) -> Void) {
        self.settings = settings
        self.onChange = onChange
        hookStatus = SettingsModel.installer(settings).status()
    }

    static func installer(_ s: UserSettings) -> HookInstaller {
        HookInstaller(sourceDir: HookSource.locate(), permissionHook: s.permissionPrompts)
    }

    func refreshHookStatus() { hookStatus = Self.installer(settings).status() }

    func installHooks() {
        do {
            try Self.installer(settings).install()
            hookMessage = "Hooks installed. Restart running Claude sessions to pick them up."
        } catch { hookMessage = "\(error)" }
        refreshHookStatus()
    }

    func removeHooks() {
        do {
            try Self.installer(settings).uninstall()
            hookMessage = "Hooks removed."
        } catch {
            hookMessage = "\(error)"
        }
        refreshHookStatus()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private var statusText: String {
        switch model.hookStatus {
        case .installed: return "Installed"
        case .needsRepair: return "Needs repair (stale path or missing hook)"
        case .notInstalled: return "Not installed"
        }
    }

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("One icon for all sessions", isOn: $model.settings.singleIcon)
                Toggle("Spin the icon while a session is running", isOn: $model.settings.animateRunning)
                Toggle("Show token count next to the bolt", isOn: $model.settings.showTokenText)
                Text("Both save space. A full menu bar on a notch Mac hides new icons without any warning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Detection") {
                Stepper(value: $model.settings.stuckMinutes, in: 1...240) {
                    Text("Stuck after \(model.settings.stuckMinutes) min without activity")
                }
                Stepper(value: $model.settings.finishBlinkSeconds, in: 1...600, step: 5) {
                    Text("Blink the green check for \(model.settings.finishBlinkSeconds) s after a session finishes")
                }
                Toggle("Hide idle sessions", isOn: $model.settings.hideIdle)
            }
            Section("Alerts") {
                Toggle("Notifications", isOn: $model.settings.notifications)
                Toggle("Also notify when a session finishes", isOn: $model.settings.notifyOnFinish)
                    .disabled(!model.settings.notifications)
                Toggle("Sound", isOn: $model.settings.sound)
                Toggle("Haptics (MX Master)", isOn: $model.settings.haptics)
                Text("Mute a single session from its right-click menu.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code hooks") {
                Toggle("Approve / deny permission prompts from the menu bar", isOn: $model.settings.permissionPrompts)
                LabeledContent("Status", value: statusText)
                HStack {
                    Button(model.hookStatus == .installed ? "Reinstall" : "Install / repair") { model.installHooks() }
                    Button("Remove") { model.removeHooks() }.disabled(model.hookStatus == .notInstalled)
                }
                if !model.hookMessage.isEmpty {
                    Text(model.hookMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 580)
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    func show() {
        model.refreshHookStatus()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "ClaudeBar Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
