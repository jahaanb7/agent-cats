import AppKit

/// In-app header brand: the winking terminal cat tile next to the orange pixel wordmark.
enum BrandMark {
    static let wordFill = NSColor(srgbRed: 0.92, green: 0.55, blue: 0.33, alpha: 1)
    static let wordShadow = NSColor(srgbRed: 0.66, green: 0.33, blue: 0.17, alpha: 1)

    static func lockup(tileSize: CGFloat, wordPx: CGFloat, gap: CGFloat = 6) -> NSImage {
        let word = PixelFont.image("AGENT CATS", px: wordPx, fill: wordFill, shadow: wordShadow)
        let icon = LogoArt.tile(size: tileSize)
        let h = max(tileSize, word.size.height)
        return NSImage(size: NSSize(width: tileSize + gap + word.size.width, height: h), flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: (h - tileSize) / 2, width: tileSize, height: tileSize))
            NSGraphicsContext.current?.imageInterpolation = .none
            word.draw(in: NSRect(x: tileSize + gap, y: (h - word.size.height) / 2, width: word.size.width, height: word.size.height))
            return true
        }
    }
}
