import Foundation

enum AppInfo {
    /// From Info.plist (VERSION file via scripts/build.sh); "dev" for `swift run` / test builds.
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
