import AppKit
import ClaudeBarCore

// Command line mode (used by install-hooks.sh): no UI, just manage the Claude Code hooks.
let selfTest = CommandLine.arguments.dropFirst().first == "--selftest"
if selfTest, ProcessInfo.processInfo.environment["CLAUDEBAR_HOME"] == nil {
    // Never inspect (or prune) the real ~/.claude by accident.
    FileHandle.standardError.write(Data("--selftest needs CLAUDEBAR_HOME pointing at a throwaway directory\n".utf8))
    exit(2)
}
if !selfTest, let cmd = CommandLine.arguments.dropFirst().first, cmd.hasPrefix("--") {
    let settings = SettingsStore().load()
    let installer = HookInstaller(sourceDir: HookSource.locate(), permissionHook: settings.permissionPrompts)
    do {
        switch cmd {
        case "--install-hooks":
            try installer.install()
            print("hooks installed (\(installer.status()))")
        case "--uninstall-hooks":
            try installer.uninstall()
            print("hooks removed")
        case "--focus-plan":      // read-only: which Ghostty tab each live session would focus
            let store = SessionStore()
            let terms = GhosttyMatcher.parse(Ghostty.listTerminals())
            for s in store.load() {
                let hit = Ghostty.tab(for: s, store: store, terms: terms)
                let target = hit.map { "\($0.tab.name)  (\($0.tab.cwd))  [by \($0.by.rawValue)]" } ?? "no Ghostty tab found"
                print("\(s.name) [\(s.state)] pid \(s.pid) tty \(ProcessTTY.of(s.pid) ?? "-") -> \(target)")
            }
        case "--version":
            print(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        case "--hooks-status":
            print(installer.status())
        default:
            print("usage: ClaudeBar [--install-hooks | --uninstall-hooks | --hooks-status | --focus-plan | --version]")
            exit(2)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(selfTest: selfTest)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
