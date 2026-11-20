// Renders Resources/AppIcon.icns: the pixel cat head on a warm rounded tile.
// Run: swift Tools/make-icon.swift   (needs iconutil, part of macOS)
import AppKit

let head = ["#.......#", "##.....##", "###...###", "#########", "#..###..#", "#########", "####.####", "##.....##", ".#######."]
func draw(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none
    let s = CGFloat(size)
    let inset = s * 0.09
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.2, yRadius: s * 0.2)
    NSColor(srgbRed: 0.22, green: 0.32, blue: 0.28, alpha: 1).setFill(); path.fill()
    // Floor stripe.
    NSGraphicsContext.saveGraphicsState(); path.addClip()
    NSColor(srgbRed: 0.62, green: 0.43, blue: 0.29, alpha: 1).setFill()
    NSRect(x: 0, y: inset, width: s, height: tile.height * 0.2).fill()
    NSGraphicsContext.restoreGraphicsState()
    let px = (tile.width * 0.62 / 9).rounded(.down)
    let ox = (s - px * 9) / 2, oy = inset + tile.height * 0.22
    for (r, line) in head.enumerated() {
        for (c, ch) in line.enumerated() where ch == "#" {
            let rect = NSRect(x: ox + CGFloat(c) * px, y: oy + CGFloat(head.count - 1 - r) * px, width: px, height: px)
            NSColor(srgbRed: 0.14, green: 0.2, blue: 0.17, alpha: 1).setFill(); rect.offsetBy(dx: px * 0.25, dy: -px * 0.25).fill()
        }
    }
    for (r, line) in head.enumerated() {
        for (c, ch) in line.enumerated() where ch == "#" {
            NSColor(srgbRed: 0.92, green: 0.55, blue: 0.33, alpha: 1).setFill()
            NSRect(x: ox + CGFloat(c) * px, y: oy + CGFloat(head.count - 1 - r) * px, width: px, height: px).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AgentCats.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
    try! draw(base * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
