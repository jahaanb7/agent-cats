import AppKit

/// The Agent Cats mark: a pixel cat that winks with a terminal prompt: ">" is one eye, a "_" cursor the
/// other, with a "…" speech bubble for "it asks you". Used by the app icon, the headers and the reel.
enum LogoArt {
    // O orange · H highlight · D shade · P pink · C cream · K ink. Left half, mirrored; eyes added below.
    private static let half = [
        "..OO.....",
        ".OHOO....",
        ".OHPOO...",
        ".OPPPOOOO",
        "OOPPOHHHH",
        "OOOOOOOOO",
        "OOOOOOOOO",
        "OOOOOOOOO",
        "OOOOOOOOO",
        "OOOOOOOOO",
        "OOOOOOOOO",   // a clear row between the eyes and the muzzle
        "DOOOOOOCP",
        "DOOOOOCCC",
        ".DDOOOOCC",
        "..DDDOOOO",
        "....DDDDD",
    ]
    static let face: [[Character]] = {
        var rows = half.map { Array($0 + String($0.reversed())) }
        // ">" eye (5 rows) and a "_" cursor eye level with the base of the chevron.
        for (r, cols) in [(5, [3, 4]), (6, [4, 5]), (7, [5, 6]), (8, [4, 5]), (9, [3, 4])] { for col in cols { rows[r][col] = "K" } }
        for r in [8, 9] { for col in 11...14 { rows[r][col] = "K" } }
        return rows
    }()
    static let gridW = 18
    private static let palette: [Character: NSColor] = [
        "O": c(0xEB8C54), "H": c(0xF4A873), "D": c(0xC96F3E), "P": c(0xF2A0A8), "C": c(0xF6E9CB), "K": c(0x1F2C26),
    ]
    private static func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }

    /// The tile (gradient, glow, cat, bubble) drawn into `tile` (bottom-left origin).
    private static func drawMark(in tile: NSRect, radius: CGFloat) {
        let s = tile.width
        let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [c(0x4C7363), c(0x3E6153), c(0x20332B)])!.draw(in: tile, angle: -90)
        let mid = NSPoint(x: tile.midX, y: tile.midY - s * 0.04)
        NSGradient(colors: [c(0xF6E9CB, 0.22), c(0xF6E9CB, 0)])!
            .draw(fromCenter: mid, radius: 0, toCenter: mid, radius: s * 0.48, options: [])
        if s >= 128 {
            c(0x000000, 0.10).setFill()
            let step = s / 16
            for gx in 0..<16 { for gy in 0..<16 where (gx + gy) % 2 == 0 {
                let d = step * 0.12
                NSRect(x: tile.minX + (CGFloat(gx) + 0.5) * step - d / 2, y: tile.minY + (CGFloat(gy) + 0.5) * step - d / 2, width: d, height: d).fill()
            } }
        }
        NSGraphicsContext.restoreGraphicsState()

        let px = max(1, (s * 0.60 / CGFloat(gridW)).rounded(.down))
        let gw = px * CGFloat(gridW), gh = px * CGFloat(face.count)
        let ox = (tile.minX + (s - gw) / 2 - px * 0.6).rounded(), oy = (tile.minY + (s - gh) / 2 - px * 0.5).rounded()
        func cell(_ col: Int, _ row: Int) -> NSRect {
            NSRect(x: ox + CGFloat(col) * px, y: oy + CGFloat(face.count - 1 - row) * px, width: px, height: px)
        }
        c(0x14201B, 0.55).setFill()
        for (r, line) in face.enumerated() { for (col, ch) in line.enumerated() where ch != "." {
            cell(col, r).offsetBy(dx: px * 0.5, dy: -px * 0.5).fill()
        } }
        for (r, line) in face.enumerated() { for (col, ch) in line.enumerated() where ch != "." {
            palette[ch]!.setFill(); cell(col, r).insetBy(dx: -0.5, dy: -0.5).fill()
        } }
        // Speech bubble with "…".
        let b = NSRect(x: ox + gw - px * 1.2, y: oy + gh - px * 0.6, width: px * 5.6, height: px * 3.6)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: b.minX + px * 0.9, y: b.minY + px * 0.2))
        tail.line(to: NSPoint(x: b.minX - px * 0.2, y: b.minY - px * 0.9))
        tail.line(to: NSPoint(x: b.minX + px * 2.0, y: b.minY + px * 0.2))
        tail.close()
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = c(0x14201B, 0.55); sh.shadowBlurRadius = 0
        sh.shadowOffset = NSSize(width: px * 0.5, height: -px * 0.5); sh.set()
        c(0xF6E9CB).setFill(); NSBezierPath(roundedRect: b, xRadius: px * 1.1, yRadius: px * 1.1).fill(); tail.fill()
        NSGraphicsContext.restoreGraphicsState()
        palette["O"]!.setFill()
        for k in 0..<3 {
            NSRect(x: (b.minX + px * (1.0 + CGFloat(k) * 1.4)).rounded(), y: (b.midY - px * 0.4).rounded(), width: px * 0.8, height: px * 0.8).fill()
        }
    }

    /// The macOS app icon (824/1024 tile, soft shadow), drawing into a square of side `s`.
    static func drawIcon(_ s: CGFloat) {
        let inset = s * 100 / 1024
        let tile = NSRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012); shadow.set()
        c(0x20332B).setFill(); NSBezierPath(roundedRect: tile, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024).fill()
        NSGraphicsContext.restoreGraphicsState()
        drawMark(in: tile, radius: s * 185 / 1024)
    }

    private static var tileCache: NSImage?
    /// The bare tile as an image of `size` points (rendered at 256 px so it stays sharp on Retina).
    static func tile(size: CGFloat) -> NSImage {
        let big: NSImage
        if let cached = tileCache { big = cached } else {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .none
            drawMark(in: NSRect(x: 0, y: 0, width: 256, height: 256), radius: 256 * 0.225)
            NSGraphicsContext.restoreGraphicsState()
            big = NSImage(size: NSSize(width: 256, height: 256)); big.addRepresentation(rep)
            tileCache = big
        }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            NSGraphicsContext.current?.imageInterpolation = .high
            big.draw(in: r)
            return true
        }
    }
}
