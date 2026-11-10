import Foundation

/// Fires MX Master 4 haptics through the third-party HapticWeb Logi Actions plugin
/// (https://github.com/Fallstop/HapticWebPlugin), which serves REST on localhost.
/// Fails silently if the plugin / Logi Options+ isn't running.
enum Haptics {
    static let base = "https://local.jmw.nz:41443/haptic/"
    private static var last = Date.distantPast

    static func fire(_ waveform: String) {
        // Collapse bursts (several sessions finishing together) into one buzz.
        guard Date().timeIntervalSince(last) > 1 else { return }
        last = Date()
        guard let url = URL(string: base + waveform) else { return }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "POST"
        req.httpBody = Data()
        URLSession.shared.dataTask(with: req).resume()
    }
}
