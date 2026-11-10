import AppKit
import ClaudeBarCore

/// Draws every menu bar image: state glyph, context-window gauge, mute fading, spinner rotation.
/// Spinning redraws ~10x/s, so each distinct frame is built once and cached.
final class IconRenderer {
    private var cache: [String: NSImage] = [:]
    private let maxCached = 600

    /// A finished menu bar icon. `angle` only matters for the running spinner.
    func icon(_ kind: IconKind, angle: CGFloat, contextFraction: Double?, muted: Bool) -> NSImage? {
        let key = "\(kind)|\(kind == .running ? Int(angle) : 0)|\(contextFraction.map { Int($0 * 100) } ?? -1)|\(muted)"
        if let hit = cache[key] { return hit }
        var img = withContextBar(kind == .running ? rotated(glyph(kind), degrees: angle) : glyph(kind), fraction: contextFraction)
        if muted { img = dimmed(img) }
        if cache.count > maxCached { cache.removeAll() }
        if let img { cache[key] = img }
        return img
    }

    func glyph(_ kind: IconKind) -> NSImage? {
        switch kind {
        case .stuck: return symbol("exclamationmark.triangle.fill", .systemRed)
        case .waiting: return symbol("exclamationmark.bubble.fill", .systemOrange)
        case .running: return symbol("arrow.triangle.2.circlepath", .systemGreen)
        case .idle: return symbol("pause.circle.fill", .systemGray)
        case .finishedFilled: return symbol("checkmark.circle.fill", .systemGreen)
        case .finishedOutline: return symbol("checkmark.circle", .systemGreen)
        }
    }

    func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        // Two-layer filled symbols: white glyph (primary) on colored shape (secondary), else the glyph vanishes.
        let twoLayer = name.contains("circle.fill") || name.contains("bubble.fill") || name.contains("triangle.fill")
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Claude session")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: twoLayer ? [.white, color] : [color]))
        img?.isTemplate = false
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
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: barW, height: barH), xRadius: 1.5, yRadius: 1.5).fill()
            color.setFill()
            let fillH = max(2, barH * CGFloat(fraction))
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

    /// Rotates an icon clockwise around its centre (the running spinner).
    private func rotated(_ base: NSImage?, degrees: CGFloat) -> NSImage? {
        guard let base, degrees != 0 else { return base }
        let img = NSImage(size: base.size, flipped: false) { rect in
            let t = NSAffineTransform()
            t.translateX(by: rect.midX, yBy: rect.midY)
            t.rotate(byDegrees: -degrees)
            t.translateX(by: -rect.midX, yBy: -rect.midY)
            t.concat()
            base.draw(in: rect)
            return true
        }
        img.isTemplate = false
        return img
    }
}
