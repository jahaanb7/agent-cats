// Renders the Agent Cats icon: the orange cat with a bell on its tail, on a night tile.
//   Tools/make-icon.sh            → Resources/AppIcon.icns
//   Tools/make-icon.sh --preview  → dist/logo/ (size sheet + 1024 png)
import AppKit

func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if size < 128 {
        // Too small for whole pixels: render big and resample down.
        let img = NSImage(size: NSSize(width: 1024, height: 1024)); img.addRepresentation(render(1024))
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    } else {
        LogoArt.drawIcon(CGFloat(size))
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
