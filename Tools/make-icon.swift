// Renders the Agent Cats mark: a pixel cat whose eyes are a terminal prompt (">" and "_"), with a
// little speech bubble ("it asks you"), on a macOS-grid tile.
//   swift Tools/make-icon.swift            → Resources/AppIcon.icns
//   swift Tools/make-icon.swift --preview  → dist/logo/ (sizes sheet, 1024 png, README lockup)
import AppKit

// O orange · H highlight · D shade · P pink · C cream · K ink. Left half, mirrored; then the eyes.
let half = [
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
    "DOOOOOOCP",
    "DOOOOOCCC",
    ".DDOOOOCC",
    "..DDDOOOO",
    "....DDDDD",
]
let face: [String] = {
    var rows = half.map { Array($0 + String($0.reversed())) }
    // Eyes: a bold prompt chevron ">" and a cursor "_".
    for (r, cols) in [(5, [3, 4]), (6, [4, 5]), (7, [5, 6]), (8, [4, 5]), (9, [3, 4])] { for col in cols { rows[r][col] = "K" } }
    for r in [8, 9] { for col in 11...14 { rows[r][col] = "K" } }
    return rows.map { String($0) }
}()
let gridW = 18
func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let palette: [Character: NSColor] = [
    "O": c(0xEB8C54), "H": c(0xF4A873), "D": c(0xC96F3E), "P": c(0xF2A0A8), "C": c(0xF6E9CB), "K": c(0x1F2C26),
]
let green = c(0x3E6153), greenDeep = c(0x20332B), cream = c(0xF6E9CB), ink = c(0x1F2C26)

/// Draws the icon into a square of side `s` (bottom-left origin).
func drawIcon(_ s: CGFloat, bubble: Bool) {
    // macOS grid: 824/1024 tile, ~185/1024 corner radius, soft drop shadow.
    let inset = s * 100 / 1024
    let tile = NSRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012); shadow.set()
    greenDeep.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [c(0x4C7363), green, greenDeep])!.draw(in: tile, angle: -90)
    // Soft glow behind the head.
    NSGradient(colors: [c(0xF6E9CB, 0.22), c(0xF6E9CB, 0)])!
        .draw(fromCenter: NSPoint(x: tile.midX, y: tile.midY - tile.height * 0.04), radius: 0,
              toCenter: NSPoint(x: tile.midX, y: tile.midY - tile.height * 0.04), radius: tile.width * 0.48, options: [])
    // A faint pixel dither, like the room's wallpaper.
    if s >= 128 {
        c(0x000000, 0.10).setFill()
        let step = tile.width / 16
        for gx in 0..<16 { for gy in 0..<16 where (gx + gy) % 2 == 0 {
            let d = step * 0.12
            NSRect(x: tile.minX + (CGFloat(gx) + 0.5) * step - d / 2, y: tile.minY + (CGFloat(gy) + 0.5) * step - d / 2, width: d, height: d).fill()
        } }
    }
    NSGraphicsContext.restoreGraphicsState()

    // The cat: 18×15 pixels, snapped to whole device pixels so edges stay crisp.
    let px = (tile.width * (bubble ? 0.64 : 0.74) / CGFloat(gridW)).rounded(.down)
    let gw = px * CGFloat(gridW), gh = px * CGFloat(face.count)
    let ox = ((s - gw) / 2 - (bubble ? px * 0.6 : 0)).rounded(), oy = (tile.minY + (tile.height - gh) / 2 - (bubble ? px * 0.9 : 0)).rounded()
    func cell(_ col: Int, _ row: Int) -> NSRect {
        NSRect(x: ox + CGFloat(col) * px, y: oy + CGFloat(face.count - 1 - row) * px, width: px, height: px)
    }
    // Hard pixel shadow down-right.
    c(0x14201B, 0.55).setFill()
    for (r, line) in face.enumerated() { for (col, ch) in line.enumerated() where ch != "." {
        cell(col, r).offsetBy(dx: px * 0.5, dy: -px * 0.5).fill()
    } }
    for (r, line) in face.enumerated() { for (col, ch) in line.enumerated() where ch != "." {
        palette[ch]!.setFill(); cell(col, r).insetBy(dx: -0.5, dy: -0.5).fill()   // overlap hides seams
    } }

    // Speech bubble with "…", top right: the cat is asking you something.
    if bubble {
        let bw = px * 5.6, bh = px * 3.6
        let b = NSRect(x: ox + gw - px * 1.2, y: oy + gh - px * 0.4, width: bw, height: bh)
        let bp = NSBezierPath(roundedRect: b, xRadius: px * 1.1, yRadius: px * 1.1)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: b.minX + px * 0.9, y: b.minY + px * 0.2))
        tail.line(to: NSPoint(x: b.minX - px * 0.2, y: b.minY - px * 0.9))
        tail.line(to: NSPoint(x: b.minX + px * 2.0, y: b.minY + px * 0.2))
        tail.close()
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = c(0x14201B, 0.55); sh.shadowBlurRadius = 0
        sh.shadowOffset = NSSize(width: px * 0.5, height: -px * 0.5); sh.set()
        cream.setFill(); bp.fill(); tail.fill()
        NSGraphicsContext.restoreGraphicsState()
        palette["O"]!.setFill()
        for k in 0..<3 {
            NSRect(x: (b.minX + px * (1.0 + CGFloat(k) * 1.4)).rounded(), y: (b.midY - px * 0.4).rounded(), width: px * 0.8, height: px * 0.8).fill()
        }
    }
}

func render(_ size: Int, bubble: Bool? = nil) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if size < 64 {
        // Too small for whole pixels: draw the face-only mark large and resample it down.
        let big = render(512, bubble: false)
        let img = NSImage(size: NSSize(width: 512, height: 512)); img.addRepresentation(big)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    } else {
        NSGraphicsContext.current?.imageInterpolation = .none
        drawIcon(CGFloat(size), bubble: bubble ?? true)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

if CommandLine.arguments.contains("--preview") {
    try? FileManager.default.createDirectory(atPath: "dist/logo", withIntermediateDirectories: true)
    write(render(1024), "dist/logo/icon-1024.png")
    // Size sheet on light and dark backgrounds, each size at 1:1.
    let sizes = [512, 256, 128, 64, 32, 16]
    let sheetW = sizes.reduce(0) { $0 + $1 + 40 } + 40, sheetH = 2 * (512 + 80)
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sheetW, pixelsHigh: sheetH, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    c(0xECECEC).setFill(); NSRect(x: 0, y: sheetH / 2, width: sheetW, height: sheetH / 2).fill()
    c(0x1E1E1E).setFill(); NSRect(x: 0, y: 0, width: sheetW, height: sheetH / 2).fill()
    for row in 0..<2 {
        var x = 40
        for sz in sizes {
            let img = NSImage(size: NSSize(width: sz, height: sz)); img.addRepresentation(render(sz))
            img.draw(in: NSRect(x: x, y: row * sheetH / 2 + 40, width: sz, height: sz))
            x += sz + 40
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    write(sheet, "dist/logo/sizes.png")
    print("wrote dist/logo/icon-1024.png, dist/logo/sizes.png")
} else {
    let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AgentCats.iconset")
    try? FileManager.default.removeItem(at: set)
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        write(render(base * scale), set.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png").path)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
    try! p.run(); p.waitUntilExit()
    print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
}
