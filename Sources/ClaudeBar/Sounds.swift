import AppKit

/// Plays macOS system sounds (Ping, Glass, ...). Unknown names are silent.
enum Sounds {
    static func play(_ name: String, volume: Float = 1) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.stop()                 // restart if the same sound is still playing
        sound.volume = volume
        sound.play()
    }

    /// Choices offered in Settings. System sounds, so nothing to ship.
    static let finishChoices = ["None", "Glass", "Tink", "Pop", "Purr"]
}
