// Renders README mockups of ClaudeBar offscreen (no screen recording needed).
// Made-up demo data, real SF Symbols and system font. Regenerate: make readme-images
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let scale: CGFloat = 2

// MARK: palette per appearance

struct Theme {
    let dark: Bool
    var name: String { dark ? "dark" : "light" }
    var appearance: NSAppearance { NSAppearance(named: dark ? .darkAqua : .aqua)! }
    var wallTop: NSColor { dark ? NSColor(srgbRed: 0.10, green: 0.12, blue: 0.22, alpha: 1) : NSColor(srgbRed: 0.62, green: 0.74, blue: 0.95, alpha: 1) }
    var wallBottom: NSColor { dark ? NSColor(srgbRed: 0.20, green: 0.12, blue: 0.28, alpha: 1) : NSColor(srgbRed: 0.86, green: 0.78, blue: 0.95, alpha: 1) }
    var bar: NSColor { dark ? NSColor(white: 0.08, alpha: 0.55) : NSColor(white: 1, alpha: 0.55) }
    var barText: NSColor { dark ? .white : .black }
    var menuBG: NSColor { dark ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 0.97) : NSColor(white: 0.97, alpha: 0.97) }
    var menuBorder: NSColor { dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12) }
    var text: NSColor { dark ? NSColor(white: 1, alpha: 0.88) : NSColor(white: 0, alpha: 0.86) }
    var disabled: NSColor { dark ? NSColor(white: 1, alpha: 0.38) : NSColor(white: 0, alpha: 0.32) }
    var separator: NSColor { dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.10) }
    var highlight: NSColor { NSColor(srgbRed: 0.04, green: 0.45, blue: 0.98, alpha: 1) }
    var cardBG: NSColor { dark ? NSColor(srgbRed: 0.20, green: 0.20, blue: 0.23, alpha: 0.96) : NSColor(white: 0.98, alpha: 0.96) }
}

// MARK: drawing helpers (flipped coordinates: y grows downwards)

let menuFont = NSFont.menuFont(ofSize: 13)
let barFont = NSFont.systemFont(ofSize: 13, weight: .medium)

func color(_ name: String) -> NSColor {
    switch name {
    case "red": return .systemRed
    case "orange": return .systemOrange
    case "green": return .systemGreen
    case "gray": return .systemGray
    case "yellow": return .systemYellow
    default: return .labelColor
    }
}

/// Same symbol + palette the app uses (IconRenderer.symbol).
func symbol(_ name: String, _ c: NSColor, size: CGFloat = 15, weight: NSFont.Weight = .regular) -> NSImage {
    let twoLayer = name.contains("circle.fill") || name.contains("bubble.fill") || name.contains("triangle.fill")
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: twoLayer ? [.white, c] : [c]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
}

func draw(_ img: NSImage, centeredIn r: NSRect) {
    let s = img.size
    img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func text(_ s: String, _ p: NSPoint, _ c: NSColor, _ f: NSFont = menuFont) {
    (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: c])
}

func width(_ s: String, _ f: NSFont = menuFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }

func render(_ name: String, _ size: NSSize, _ t: Theme, _ body: (Theme) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let base = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = base.cgContext
    // flip so y grows downwards, and tell AppKit the context is flipped so text and images stay upright
    cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    t.appearance.performAsCurrentDrawingAppearance { body(t) }
    NSGraphicsContext.restoreGraphicsState()
    let url = out.appendingPathComponent("\(name)-\(t.name).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print(url.path)
}

func wallpaper(_ size: NSSize, _ t: Theme) {
    NSGradient(starting: t.wallTop, ending: t.wallBottom)!.draw(in: NSRect(origin: .zero, size: size), angle: 90)
}

func shadowed(_ r: NSRect, radius: CGFloat, fill: NSColor, border: NSColor) {
    let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.28); sh.shadowBlurRadius = 18; sh.shadowOffset = NSSize(width: 0, height: -6)
    sh.set(); fill.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    border.setStroke(); path.lineWidth = 0.5; path.stroke()
}

// MARK: menu bar

let barH: CGFloat = 26

/// An icon in the bar: glyph, optional context gauge, optional badge text. Returns its frame.
struct BarIcon { var glyph: NSImage; var gauge: (Double, NSColor)? = nil; var badge: String? = nil }

func barIconWidth(_ i: BarIcon) -> CGFloat {
    var w = i.glyph.size.width + 16
    if i.gauge != nil { w += 6 }
    if let b = i.badge { w += width(b, barFont) + 2 }
    return w
}

@discardableResult
func drawBarIcon(_ i: BarIcon, x: CGFloat, _ t: Theme, pressed: Bool = false) -> NSRect {
    let w = barIconWidth(i)
    let r = NSRect(x: x, y: 2, width: w, height: barH - 4)
    if pressed {
        (t.dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.12)).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
    }
    var cx = x + 8
    draw(i.glyph, centeredIn: NSRect(x: cx, y: 0, width: i.glyph.size.width, height: barH))
    cx += i.glyph.size.width
    if let (f, c) = i.gauge {   // IconRenderer.withContextBar: 3pt bar, 3pt gap, 16pt high
        let h: CGFloat = 14, top = (barH - h) / 2
        let bx = cx + 3
        t.barText.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: bx, y: top, width: 3, height: h), xRadius: 1.5, yRadius: 1.5).fill()
        c.setFill()
        let fh = max(2, h * f)
        NSBezierPath(roundedRect: NSRect(x: bx, y: top + h - fh, width: 3, height: fh), xRadius: 1.5, yRadius: 1.5).fill()
        cx += 6
    }
    if let b = i.badge {
        text(b, NSPoint(x: cx + 2, y: (barH - 16) / 2), t.barText, barFont)
    }
    return r
}

/// Draws the bar, the ClaudeBar icons, then the system items to their right. Returns the frames of the app icons.
func menuBar(_ size: NSSize, _ t: Theme, icons: [BarIcon], pressed: Int? = nil) -> [NSRect] {
    t.bar.setFill(); NSRect(x: 0, y: 0, width: size.width, height: barH).fill()
    // system items, right to left
    var x = size.width - 12
    let clock = "Wed 11 Nov  19:58"
    x -= width(clock, barFont); text(clock, NSPoint(x: x, y: (barH - 16) / 2), t.barText, barFont)
    for s in ["switch.2", "battery.75percent", "wifi"] {
        let img = symbol(s, t.barText, size: 14)
        x -= img.size.width + 18
        draw(img, centeredIn: NSRect(x: x, y: 0, width: img.size.width + 18, height: barH))
    }
    x -= 6
    let total = icons.map(barIconWidth).reduce(0, +)
    x -= total
    var frames: [NSRect] = []
    for (n, i) in icons.enumerated() {
        let r = drawBarIcon(i, x: x, t, pressed: pressed == n)
        frames.append(r); x += r.width
    }
    return frames
}

// MARK: menus

enum Row {
    case item(String, glyph: NSImage? = nil, enabled: Bool = true, key: String? = nil, submenu: Bool = false,
              highlighted: Bool = false, checked: Bool = false)
    case separator
}

let rowH: CGFloat = 22, sepH: CGFloat = 11, menuPad: CGFloat = 5

func menuSize(_ rows: [Row]) -> NSSize {
    var h = menuPad * 2, w: CGFloat = 0
    let hasGlyph = rows.contains { if case .item(_, let g, _, _, _, _, _) = $0 { return g != nil } else { return false } }
    for r in rows {
        switch r {
        case .separator: h += sepH
        case let .item(title, _, _, key, sub, _, _):
            h += rowH
            w = max(w, width(title) + (key.map { width($0) + 28 } ?? 0) + (sub ? 28 : 0))
        }
    }
    return NSSize(width: w + (hasGlyph ? 34 : 22) + 22, height: h)
}

@discardableResult
func drawMenu(_ rows: [Row], at p: NSPoint, _ t: Theme, minWidth: CGFloat = 0) -> NSRect {
    var s = menuSize(rows); s.width = max(s.width, minWidth)
    let frame = NSRect(origin: p, size: s)
    shadowed(frame, radius: 9, fill: t.menuBG, border: t.menuBorder)
    let hasGlyph = rows.contains { if case .item(_, let g, _, _, _, _, _) = $0 { return g != nil } else { return false } }
    let textX = p.x + (hasGlyph ? 34 : 22)
    var y = p.y + menuPad
    for r in rows {
        switch r {
        case .separator:
            t.separator.setFill(); NSRect(x: p.x + 12, y: y + sepH / 2, width: s.width - 24, height: 1).fill()
            y += sepH
        case let .item(title, glyph, enabled, key, sub, hl, checked):
            if hl {
                t.highlight.setFill()
                NSBezierPath(roundedRect: NSRect(x: p.x + 5, y: y, width: s.width - 10, height: rowH), xRadius: 5, yRadius: 5).fill()
            }
            let c = hl ? NSColor.white : enabled ? t.text : t.disabled
            if checked { text("✓", NSPoint(x: p.x + 10, y: y + 3), c) }
            if let g = glyph { draw(g, centeredIn: NSRect(x: p.x + 12, y: y, width: 16, height: rowH)) }
            text(title, NSPoint(x: textX, y: y + 3), c)
            if let k = key {
                let kc = hl ? NSColor.white : t.disabled
                text(k, NSPoint(x: frame.maxX - 16 - width(k), y: y + 3), kc)
            }
            if sub {
                let ch = symbol("chevron.right", hl ? .white : t.disabled, size: 10, weight: .semibold)
                draw(ch, centeredIn: NSRect(x: frame.maxX - 26, y: y, width: 14, height: rowH))
            }
            y += rowH
        }
    }
    return frame
}

// MARK: demo data (made up; matches what SessionText would print)

func g(_ kind: String) -> NSImage {
    switch kind {
    case "stuck": return symbol("exclamationmark.triangle.fill", .systemRed)
    case "waiting": return symbol("exclamationmark.bubble.fill", .systemOrange)
    case "running": return symbol("arrow.triangle.2.circlepath", .systemGreen)
    case "finished": return symbol("checkmark.circle.fill", .systemGreen)
    default: return symbol("pause.circle.fill", .systemGray)
    }
}
let bolt = BarIcon(glyph: symbol("bolt.fill", .systemYellow))
let footer: [Row] = [.item("ClaudeBar 0.3.0", enabled: false), .item("Settings…", key: "⌘,"), .item("Quit ClaudeBar", key: "⌘Q")]

// 1. Single icon: two sessions waiting (badge 2), menu open with a session submenu.
func singleMenuShot(_ t: Theme) {
    let size = NSSize(width: 820, height: 272)
    render("menu", size, t) { t in
        wallpaper(size, t)
        let frames = menuBar(size, t, icons: [BarIcon(glyph: g("waiting"), gauge: (0.75, .systemOrange), badge: "2"), bolt], pressed: 0)
        let main: [Row] = [
            .item("web — waiting", glyph: g("waiting"), submenu: true, highlighted: true),
            .item("ios — waiting · approval needed", glyph: g("waiting"), submenu: true),
            .item("api — running", glyph: g("running"), submenu: true),
            .item("docs — idle", glyph: g("idle"), submenu: true),
            .separator,
            .item("Today: 18.4M tokens", enabled: false),
            .separator,
        ] + footer
        let mf = drawMenu(main, at: NSPoint(x: frames[0].minX, y: barH + 4), t)
        let sub: [Row] = [
            .item("web", enabled: false),
            .item("State: waiting", enabled: false),
            .item("/Users/dev/code/web", enabled: false),
            .item("Today: 6.12M tokens", enabled: false),
            .item("Context: 151k / 200k (75%)", enabled: false),
            .item("Last: Should I also update the snapshot tests?", enabled: false),
            .separator,
            .item("Focus in Ghostty"),
            .item("Open folder in Terminal"),
            .item("Mute alerts for this session"),
        ]
        let ss = menuSize(sub)
        drawMenu(sub, at: NSPoint(x: mf.minX - ss.width + 4, y: mf.minY), t)
    }
}

// 2. Per-session icons, one of each state.
func perSessionShot(_ t: Theme) {
    let size = NSSize(width: 620, height: 26)
    render("icons", size, t) { t in
        wallpaper(size, t)
        _ = menuBar(size, t, icons: [
            BarIcon(glyph: g("stuck"), gauge: (0.32, .systemGreen)),
            BarIcon(glyph: g("waiting"), gauge: (0.75, .systemOrange)),
            BarIcon(glyph: g("running"), gauge: (0.46, .systemGreen)),
            BarIcon(glyph: g("finished"), gauge: (0.88, .systemRed)),
            BarIcon(glyph: g("idle"), gauge: (0.19, .systemGreen)),
            bolt,
        ])
    }
}

// 3. Bolt menu: token breakdown + per-session rows.
func boltShot(_ t: Theme) {
    let size = NSSize(width: 560, height: 330)
    render("tokens", size, t) { t in
        wallpaper(size, t)
        let frames = menuBar(size, t, icons: [BarIcon(glyph: g("running"), gauge: (0.46, .systemGreen), badge: "2"), bolt], pressed: 1)
        let rows: [Row] = [
            .item("Today: 18.4M tokens", enabled: false),
            .item("    Input: 0.06M", enabled: false),
            .item("    Output: 0.29M", enabled: false),
            .item("    Cache write: 1.12M", enabled: false),
            .item("    Cache read: 16.9M", enabled: false),
            .separator,
            .item("web: 6.12M · ctx 75%", glyph: g("waiting")),
            .item("api: 5.30M · ctx 46%", glyph: g("running"), highlighted: true),
            .item("ios: 4.71M · ctx 58%", glyph: g("running")),
            .item("docs: 2.27M · ctx 19%", glyph: g("idle")),
            .separator,
        ] + footer
        let s = menuSize(rows)
        drawMenu(rows, at: NSPoint(x: min(frames[1].minX, size.width - s.width - 8), y: barH + 4), t)
    }
}

// 4. Notifications: approval request with Approve / Deny, and a stuck diagnosis.
func notificationsShot(_ t: Theme) {
    let size = NSSize(width: 440, height: 210)
    render("notifications", size, t) { t in
        wallpaper(size, t)
        let appIcon = NSWorkspace.shared.icon(for: .applicationBundle)
        func card(_ y: CGFloat, title: String, body: String, actions: [String]) {
            let r = NSRect(x: 20, y: y, width: size.width - 40, height: 78)
            shadowed(r, radius: 16, fill: t.cardBG, border: t.menuBorder)
            appIcon.draw(in: NSRect(x: r.minX + 12, y: r.minY + 19, width: 40, height: 40), from: .zero,
                         operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let actW: CGFloat = actions.isEmpty ? 0 : 84
            let tx = r.minX + 62
            text(title, NSPoint(x: tx, y: r.minY + 14), t.text, .systemFont(ofSize: 13, weight: .semibold))
            let now = "now"
            text(now, NSPoint(x: r.maxX - actW - 12 - width(now, .systemFont(ofSize: 12)), y: r.minY + 15), t.disabled, .systemFont(ofSize: 12))
            let bodyRect = NSRect(x: tx, y: r.minY + 33, width: r.width - 62 - actW - 14, height: 36)
            (body as NSString).draw(with: bodyRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: t.text.withAlphaComponent(0.75)])
            guard !actions.isEmpty else { return }
            let ax = r.maxX - actW
            t.separator.setFill()
            NSRect(x: ax, y: r.minY, width: 1, height: r.height).fill()
            NSRect(x: ax, y: r.midY, width: actW, height: 1).fill()
            for (n, a) in actions.enumerated() {
                let f = NSFont.systemFont(ofSize: 13, weight: .medium)
                text(a, NSPoint(x: ax + (actW - width(a, f)) / 2, y: r.minY + CGFloat(n) * r.height / 2 + (r.height / 2 - 16) / 2),
                     t.text, f)
            }
        }
        card(18, title: "ios: approve Bash?", body: "xcodebuild test -scheme App -destination 'platform=iOS Simulator'",
             actions: ["Approve", "Deny"])
        card(112, title: "ml looks stuck", body: "tool still running 14m: Bash `python bench_loader.py --batch 512`", actions: [])
    }
}

for t in [Theme(dark: false), Theme(dark: true)] {
    singleMenuShot(t); perSessionShot(t); boltShot(t); notificationsShot(t)
}
