import AppKit

/// The Agent Cats mark: an orange beckoning cat (maneki-neko) with a red ribbon and a gold bell on
/// the tip of its curled tail. Built from pixel shapes so the paw and tail can animate.
enum LogoArt {
    static let w = 34, h = 34

    // Palette (shared with the reel: night, cream, orange, red, gold).
    static let colors: [Character: UInt32] = [
        "O": 0xEB8C54, "H": 0xF7B37E, "D": 0xC4683A, "S": 0xD97A45,   // orange, highlight, shade, stripe
        "W": 0xF8EBD0, "w": 0xE6D3AE,                                   // cream belly, cream shade
        "K": 0x231713, "L": 0x2A1712,                                   // ink, outline
        "R": 0xD9443F, "r": 0xA9302C,                                   // red ribbon
        "G": 0xF5C451, "g": 0xC8922B, "Y": 0xFFF1B8,                    // gold bell, shade, shine
        "P": 0xF29AA4,                                                  // pink
    ]

    /// - paw: how high the beckoning paw is raised, 0…1.
    /// - tail: tail sway, -1…1. - bell: bell swing, -1…1.
    static func grid(paw: Double = 1, tail: Double = 0, bell: Double = 0) -> [[Character]] {
        var g = [[Character]](repeating: [Character](repeating: ".", count: w), count: h)
        func put(_ x: Int, _ y: Int, _ c: Character) { if x >= 0, y >= 0, x < w, y < h { g[y][x] = c } }
        func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ c: Character, only: Set<Character>? = nil) {
            for y in 0..<h { for x in 0..<w {
                let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                if dx * dx + dy * dy <= 1, only == nil || only!.contains(g[y][x]) { g[y][x] = c }
            } }
        }
        func disc(_ cx: Double, _ cy: Double, _ r: Double, _ c: Character) { ellipse(cx, cy, r, r, c) }

        // Tail: a thick curl up the right side, swaying a little; the bell is tied near its tip.
        var tip = (x: 0.0, y: 0.0)
        for k in 0...44 {
            let u = Double(k) / 44
            let x = 22.5 + 5.2 * sin(u * .pi * 0.55) + tail * 1.6 * u * u
            let y = 30.5 - 14.5 * u
            disc(x, y, 1.75 - 0.35 * u, "O")
            tip = (x, y)
        }
        // Body and belly.
        ellipse(16.5, 24.5, 8.6, 8.2, "O")
        ellipse(16.5, 25.6, 5.2, 6.0, "W")
        // Shoulders join head and body; then the head.
        ellipse(16.5, 20.0, 9.6, 3.2, "O")
        ellipse(16.5, 12.6, 9.3, 7.4, "O")
        // Ears: triangles, narrow at the tip; pink inside.
        for tipX in [10.5, 22.5] {
            for r in 0..<5 {
                let hw = 0.6 + Double(r) * 0.8
                for x in 0..<w where abs(Double(x) + 0.5 - tipX) <= hw { put(x, 2 + r, "O") }
                if r >= 2 {
                    for x in 0..<w where abs(Double(x) + 0.5 - tipX) <= hw - 1.4 { put(x, 2 + r, "P") }
                }
            }
        }
        // Tabby stripes on the forehead.
        for x in [14, 16, 18] { put(x, 7, "S"); put(x, 8, "S") }
        // Muzzle, eyes (with a cream shine), nose, mouth, cheeks.
        ellipse(16.5, 16.0, 4.3, 2.4, "W")
        for ex in [11, 20] {
            for dx in 0...1 { for dy in 0...2 { put(ex + dx, 12 + dy, "K") } }
            put(ex, 12, "W")
        }
        put(16, 15, "P"); put(17, 15, "P")
        put(15, 16, "K"); put(16, 17, "K"); put(17, 17, "K"); put(18, 16, "K")
        put(9, 16, "P"); put(24, 16, "P")
        // Red collar with a little knot.
        for x in 8...24 { if g[20][x] == "O" || g[20][x] == "W" { put(x, 20, "R") }; if g[21][x] == "O" || g[21][x] == "W" { put(x, 21, "r") } }
        put(16, 22, "R"); put(17, 22, "R"); put(15, 23, "r"); put(18, 23, "r")
        // Resting front paw.
        ellipse(19.5, 31.4, 2.6, 1.6, "W")
        put(18, 31, "w"); put(20, 31, "w")
        // Beckoning paw: an arm beside the head, raised by `paw`, outlined apart from the head.
        let lift = Int((paw * 3).rounded())
        let top = 8 - lift
        for y in top...20 { for x in 2...5 { put(x, y, "O") } }
        ellipse(3.9, Double(top) + 0.8, 2.5, 2.1, "W")
        put(3, top, "P"); put(4, top, "P")
        for y in (top + 3)...18 where y % 3 == 0 { put(2, y, "S") }
        for y in (top + 1)...19 where g[y][6] != "." || g[y][7] != "." { put(6, y, "L") }

        // Shading: right/bottom edges of orange go darker, top/left edges lighter.
        let filled: (Int, Int) -> Bool = { x, y in x >= 0 && y >= 0 && x < w && y < h && g[y][x] != "." }
        var shaded = g
        for y in 0..<h { for x in 0..<w where g[y][x] == "O" {
            if !filled(x + 1, y) || !filled(x, y + 1) { shaded[y][x] = "D" }
            else if !filled(x - 1, y) { shaded[y][x] = "H" }
        } }
        g = shaded
        // Ribbon + bell just below the tail tip, hanging outward.
        let bx = Int(tip.x.rounded()), by = Int(tip.y.rounded()) + 2
        put(bx - 1, by, "R"); put(bx, by, "r"); put(bx + 1, by, "R"); put(bx + 2, by + 1, "R")
        let swing = bell * 1.2
        let cx = Double(bx) + 3.2 + swing, cy = Double(by) + 3.4
        ellipse(cx, cy, 2.3, 2.2, "G")
        put(Int(cx - 1.2), Int(cy - 1.2), "Y")
        put(Int(cx), Int(cy) + 1, "g"); put(Int(cx) - 1, Int(cy) + 1, "g"); put(Int(cx) + 1, Int(cy) + 1, "g")
        put(Int(cx), Int(cy), "K")
        // Fill pockets enclosed by the cat (between arm, head and tail) so no background shows through.
        var outside = Set<Int>()
        var stack = [Int]()
        for x in 0..<w { stack += [x, (h - 1) * w + x] }
        for y in 0..<h { stack += [y * w, y * w + w - 1] }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            guard g[y][x] == ".", !outside.contains(i) else { continue }
            outside.insert(i)
            if x > 0 { stack.append(i - 1) }; if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }; if y < h - 1 { stack.append(i + w) }
        }
        for y in 0..<h { for x in 0..<w where g[y][x] == "." && !outside.contains(y * w + x) { g[y][x] = "L" } }
        // Outline every empty cell touching the cat.
        var out = g
        for y in 0..<h { for x in 0..<w where g[y][x] == "." {
            if filled(x + 1, y) || filled(x - 1, y) || filled(x, y + 1) || filled(x, y - 1) { out[y][x] = "L" }
        } }
        return out
    }

    /// The cat as a pixel image (1 point per pixel). Draw it with interpolation off.
    static func image(paw: Double = 1, tail: Double = 0, bell: Double = 0) -> NSImage {
        let g = grid(paw: paw, tail: tail, bell: bell)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<h { for x in 0..<w {
            guard let hex = colors[g[y][x]] else { continue }
            rep.setColor(NSColor(deviceRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                                 blue: CGFloat(hex & 255) / 255, alpha: 1), atX: x, y: y)
        } }
        let img = NSImage(size: NSSize(width: w, height: h)); img.addRepresentation(rep)
        return img
    }
}
