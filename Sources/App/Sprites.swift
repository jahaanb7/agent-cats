import AppKit
import CoreGraphics

/// Renders cats from Art/cats.json into tiny CGImages (1 image pixel = 1 art pixel).
/// Layers scale them up with nearest-neighbour filtering, so they stay crisp at any size.
final class SpriteBook {
    struct Prop { let at: (Int, Int); let grid: [String] }
    static let canvasW = 28, canvasH = 21

    private var poses: [String: [String]] = [:]
    private var faces: [String: [String]] = [:]
    private var props: [String: Prop] = [:]
    private var common: [Character: String] = [:]
    private var coats: [String: [Character: String]] = [:]
    private var agents: [String: String] = [:]
    private var cache: [String: CGImage] = [:]

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        poses = o["poses"] as? [String: [String]] ?? [:]
        for (k, v) in o["faces"] as? [String: Any] ?? [:] where !k.hasPrefix("_") { faces[k] = v as? [String] }
        for (k, v) in o["props"] as? [String: Any] ?? [:] where !k.hasPrefix("_") {
            guard let p = v as? [String: Any], let at = p["at"] as? [Int], let g = p["grid"] as? [String] else { continue }
            props[k] = Prop(at: (at[0], at[1]), grid: g)
        }
        common = Self.keyed(o["palette_common"] as? [String: String] ?? [:])
        agents = o["agents"] as? [String: String] ?? [:]
        for (name, v) in o["coats"] as? [String: [String: String]] ?? [:] { coats[name] = Self.keyed(v) }
    }

    private static func keyed(_ d: [String: String]) -> [Character: String] {
        var out: [Character: String] = [:]
        for (k, v) in d where k.count == 1 { out[Character(k)] = v }
        return out
    }

    struct Look: Hashable {
        var coat: String
        var agent: String
        var pose = "sit"
        var face: String? = nil
        var props: [String] = []
        var propDY: Int = 0            // bob a prop up/down (zzz, ?, sign)
        var overrides: [String] = []   // "S=#7FD0BC" style palette tweaks (screen flicker)
        var grey = false
        var accessory: String? = nil
    }

    func image(_ l: Look) -> CGImage? {
        let key = "\(l.coat)|\(l.agent)|\(l.pose)|\(l.face ?? "")|\(l.props.joined(separator: ","))|\(l.propDY)|\(l.overrides.joined(separator: ","))|\(l.grey)|\(l.accessory ?? "")"
        if let c = cache[key] { return c }
        guard let pose = poses[l.pose] else { return nil }
        var pal = common
        for (k, v) in coats[l.coat] ?? coats.values.first ?? [:] { pal[k] = v }
        pal["c"] = agents[l.agent] ?? "#E06B3B"
        for o in l.overrides { let parts = o.split(separator: "="); if parts.count == 2, let ch = parts[0].first { pal[ch] = String(parts[1]) } }

        let W = Self.canvasW, H = Self.canvasH
        var px = [UInt32?](repeating: nil, count: W * H)
        func put(_ grid: [String], _ x0: Int, _ y0: Int) {
            for (r, row) in grid.enumerated() {
                for (c, ch) in row.enumerated() where ch != "." && ch != " " {
                    let x = x0 + c, y = y0 + r
                    guard x >= 0, x < W, y >= 0, y < H, let hex = pal[ch] else { continue }
                    px[y * W + x] = Self.rgba(hex)
                }
            }
        }
        put(pose, 2, 0)
        if let fname = l.face, let f = faces[fname], l.pose == "sit" {
            for r in 0..<2 where 4 + r < pose.count {
                for (c, ch) in pose[4 + r].enumerated() where ch == "k" {
                    px[(4 + r) * W + 2 + c] = Self.rgba(pal[c < 11 ? "p" : "w"] ?? "#FFFFFF")
                }
                put([f[r]], 2, 4 + r)
            }
        }
        if let a = l.accessory, let art = Self.accessoryArt[a]?[l.pose] { put(art.grid, 2 + art.at.0, art.at.1) }
        for name in l.props {
            guard let p = props[name] else { continue }
            let bob = ["zzz", "ask", "alert"].contains(name) ? l.propDY : 0
            put(p.grid, 2 + p.at.0, p.at.1 + bob)
        }
        if l.grey {
            px = px.map { v in
                guard let v else { return nil }
                let r = Double(v >> 24 & 0xFF), g = Double(v >> 16 & 0xFF), b = Double(v >> 8 & 0xFF), a = v & 0xFF
                let y = UInt32(0.3 * r + 0.59 * g + 0.11 * b)
                return y << 24 | y << 16 | y << 8 | a
            }
        }
        let img = Self.makeImage(px, W, H)
        if cache.count > 600 { cache.removeAll() }
        cache[key] = img
        return img
    }

    /// Accessories, drawn in pose coordinates over the head or neck. Palette letters as in cats.json.
    static let accessoryArt: [String: [String: Prop]] = [
        "crown": ["sit": Prop(at: (9, 0), grid: ["Y.Y.Y", "YYYYY", "EYhYE"]), "loaf": Prop(at: (5, 8), grid: ["Y.Y", "YYY"])],
        "bow": ["sit": Prop(at: (15, 2), grid: ["E.E", "EYE", "E.E"]), "loaf": Prop(at: (10, 8), grid: ["E.E", "EYE", "E.E"])],
        "flower": ["sit": Prop(at: (15, 1), grid: [".n.", "nYn", ".n."]), "loaf": Prop(at: (10, 8), grid: [".n.", "nYn", ".n."])],
        "glasses": ["sit": Prop(at: (7, 3), grid: ["ZZZ...ZZZ", "Z.ZZZZZ.Z", "Z.Z...Z.Z", "ZZZ...ZZZ"]),
                    "loaf": Prop(at: (2, 11), grid: ["ZZZZZZZZZ", "Z..ZZZ..Z", "ZZZZ.ZZZZ"])],
        "shades": ["sit": Prop(at: (7, 4), grid: ["MMMMMMMMM", ".MM...MM."]), "loaf": Prop(at: (2, 12), grid: ["MMMMMMMMM", ".MM...MM."])],
        "scarf": ["sit": Prop(at: (7, 10), grid: ["EEhEEhEEhEE", "..EE......."])],
    ]

    // MARK: pixel helpers

    static func rgba(_ s: String) -> UInt32 {
        if s.hasPrefix("#"), s.count == 7, let v = UInt32(s.dropFirst(), radix: 16) { return v << 8 | 0xFF }
        if s.hasPrefix("rgba(") {
            let parts = s.dropFirst(5).dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 4, let r = UInt32(parts[0]), let g = UInt32(parts[1]), let b = UInt32(parts[2]), let a = Double(parts[3]) {
                return r << 24 | g << 16 | b << 8 | UInt32(a * 255)
            }
        }
        return 0xFF00FFFF
    }

    /// Premultiplied RGBA image from optional pixels (nil = transparent).
    static func makeImage(_ px: [UInt32?], _ w: Int, _ h: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            guard let v = px[i] else { continue }
            let a = Double(v & 0xFF) / 255
            bytes[i * 4] = UInt8(Double(v >> 24 & 0xFF) * a)
            bytes[i * 4 + 1] = UInt8(Double(v >> 16 & 0xFF) * a)
            bytes[i * 4 + 2] = UInt8(Double(v >> 8 & 0xFF) * a)
            bytes[i * 4 + 3] = UInt8(v & 0xFF)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// What a cat looks like for a state at animation frame `f` (6 fps ticks).
/// Returns the look and a vertical body offset in art pixels (hops and bobs).
func catLook(coat: String, agent: String, state: CatState, frame f: Int, sinceState: TimeInterval, still: Bool) -> (SpriteBook.Look, Int) {
    var l = SpriteBook.Look(coat: coat, agent: agent)
    l.accessory = CatStyle.shared.accessory(for: coat)
    let f = still ? 0 : f
    let blink = f % 23 == 0 && f > 0
    var dy = 0
    switch state {
    case .idle:
        l.pose = "loaf"; l.props = ["zzz"]; l.propDY = (f / 4) % 2 == 0 ? 0 : -1
    case .thinking:
        l.face = f % 30 < 2 && f > 0 ? "open" : "closed"; l.props = ["book"]
        if (f / 9) % 2 == 1 { l.overrides = ["g=#E8DDCB"] }   // turning pages
    case .working:
        l.face = blink ? "closed" : "open"; l.props = ["laptop"]
        if f % 2 == 1 { l.overrides = ["S=#7FD0BC"] }          // screen flicker per tick
    case .permission:
        l.face = "wide"; l.props = ["sign"]; dy = (f / 2) % 2      // waving the sign
    case .question:
        l.face = blink ? "closed" : "wide"; l.props = ["ask"]; l.propDY = (f / 3) % 2 == 0 ? 0 : -1
    case .done:
        l.face = "happy"; l.props = (f / 2) % 2 == 0 ? ["sparkle"] : []
        if !still, sinceState < 0.9 { dy = [0, 2, 3, 2, 0][min(4, Int(sinceState * 6))] }   // little hop
    case .error:
        l.face = "dizzy"; l.props = (f / 2) % 2 == 0 ? ["alert"] : []
    case .gone:
        l.pose = "loaf"; l.grey = true
    }
    return (l, dy)
}
