// Run after `swift Tools/make-icon.swift --preview`: swiftc -o /tmp/lockup Sources/App/PixelFont.swift Tools/Lockup/main.swift && /tmp/lockup
import AppKit
// README lockup: app icon + pixel wordmark + tagline on a transparent canvas.
let icon = NSImage(contentsOfFile: "dist/logo/icon-1024.png")!
func c(_ h: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(h >> 16 & 255)/255, green: CGFloat(h >> 8 & 255)/255, blue: CGFloat(h & 255)/255, alpha: 1) }
let word = PixelFont.image("AGENT CATS", px: 12, fill: c(0xEB8C54), shadow: c(0xA9552B))
let W: CGFloat = 1280, H: CGFloat = 320
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high
let iconS: CGFloat = 300
let total = iconS + 30 + word.size.width
let x0 = (W - total) / 2
icon.draw(in: NSRect(x: x0, y: (H - iconS) / 2, width: iconS, height: iconS))
NSGraphicsContext.current!.imageInterpolation = .none
let wr = NSRect(x: x0 + iconS + 30, y: H / 2 - word.size.height / 2 + 4, width: word.size.width, height: word.size.height)
word.draw(in: wr)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/images/logo.png"))
print("wrote docs/images/logo.png")
