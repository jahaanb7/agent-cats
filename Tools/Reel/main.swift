import AppKit
import SwiftUI

// Renders the 1080×1920 promo reel from the app's own views (room, cats, bubbles, dashboard).
// Driven by Tools/make-reel.sh, which records the voiceover first and passes its timing here:
//   reel <timeline.json> <frames-dir>
// Streams raw 1080×1920 RGBA frames to stdout and writes sfx.json (sound-effect cues) into the folder.

let W: CGFloat = 1080, H: CGFloat = 1920, FPS = 30.0
let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("usage: reel <timeline.json> <frames-dir>") }
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let app = NSApplication.shared
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard let book = SpriteBook(url: root.appendingPathComponent("Art/cats.json")) else { fatalError("missing sprites") }

struct Line: Decodable { let caption: String; let start: Double; let end: Double }
struct Timeline: Decodable { let lines: [Line]; let duration: Double }
let timeline = try! JSONDecoder().decode(Timeline.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let L = timeline.lines
precondition(L.count == 8, "the storyboard expects 8 voiceover lines")
func S(_ i: Int) -> Double { i < L.count ? L[i].start : timeline.duration }
func E(_ i: Int) -> Double { L[i].end }

// MARK: palette and helpers

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let forest = rgb(46, 66, 58), forestDark = rgb(33, 48, 42), cream = rgb(246, 233, 203), orange = rgb(235, 140, 84)
let night = rgb(18, 20, 26), red = rgb(232, 76, 72)
let confettiColors = [orange, cream, rgb(127, 208, 188), rgb(240, 196, 92), rgb(214, 120, 160)]

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOutBack(_ x: Double) -> Double { let c1 = 1.9, c3 = c1 + 1; return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2) }
/// Deterministic noise in 0..<1 (particles, shake) so every render is identical.
func rnd(_ a: Int, _ b: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
    x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9; x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
    return Double((x ^ (x >> 31)) % 10_000) / 10_000
}

func snapshot(_ v: NSView) -> NSImage {
    v.layoutSubtreeIfNeeded()
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    let img = NSImage(size: v.bounds.size); img.addRepresentation(rep)
    return img
}

func draw(_ img: NSImage, _ rect: NSRect, alpha: CGFloat = 1, crisp: Bool = false) {
    NSGraphicsContext.current!.imageInterpolation = crisp ? .none : .high
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
}

/// Runs `body` with the canvas scaled by `s` around `p` (and optionally shifted / rotated).
func withTransform(scale s: CGFloat, around p: CGPoint, shift: CGPoint = .zero, rotate: CGFloat = 0, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: p.x + shift.x, yBy: p.y + shift.y); t.rotate(byDegrees: rotate); t.scale(by: max(0.001, s))
    t.translateX(by: -p.x, yBy: -p.y); t.concat()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func pixelText(_ s: String, px: CGFloat, color: NSColor = cream) -> NSImage {
    PixelFont.image(s, px: px, fill: color, shadow: forestDark, accent: orange)
}

func drawPixelCentered(_ s: String, px: CGFloat, y: CGFloat, scale: CGFloat = 1, alpha: CGFloat = 1, color: NSColor = cream) {
    let img = pixelText(s, px: px, color: color)
    let w = img.size.width * scale, h = img.size.height * scale
    draw(img, NSRect(x: (W - w) / 2, y: y - h / 2, width: w, height: h), alpha: alpha, crisp: true)
}

// MARK: sound-effect cues (mixed by make-reel.sh)

var cues: [[String: Any]] = []
var cued = Set<String>()
/// Records a sound effect once, on the first frame that reaches `at`.
func cue(_ name: String, at: Double, _ t: Double, gain: Double = 1) {
    let key = "\(name)@\(at)"
    guard t >= at, !cued.contains(key) else { return }
    cued.insert(key); cues.append(["name": name, "t": max(0, at), "gain": gain])
}

// MARK: karaoke captions (pixel font, like the hook)

let captionPx: CGFloat = 9
var wordCache: [String: NSImage] = [:]
func wordImage(_ w: String, _ hot: Bool) -> NSImage {
    let key = "\(w)|\(hot)"
    if let img = wordCache[key] { return img }
    let img = PixelFont.image(w, px: captionPx, fill: hot ? orange : cream, shadow: NSColor.black, accent: orange)
    wordCache[key] = img
    return img
}

/// Words appear as they're spoken; the word being said is orange and pops a little.
func caption(_ i: Int, t: Double, y: CGFloat) {
    let line = L[i]
    let until = S(i + 1) - 0.05
    guard t >= line.start - 0.05, t < until else { return }
    let words = line.caption.uppercased().split(separator: " ").map(String.init)
    let total = Double(words.reduce(0) { $0 + $1.count + 2 })
    var starts: [Double] = []; var acc = 0.0
    for w in words { starts.append(line.start + (line.end - line.start - 0.15) * acc / total); acc += Double(w.count + 2) }
    let space = captionPx * 5
    var rows: [[Int]] = [[]]; var rowW: CGFloat = 0
    for (k, w) in words.enumerated() {
        let ww = wordImage(w, false).size.width
        if rowW > 0 && rowW + space + ww > 940 { rows.append([]); rowW = 0 }
        rows[rows.count - 1].append(k); rowW += (rowW > 0 ? space : 0) + ww
    }
    let lineH = captionPx * 11
    let fade = CGFloat(1 - progress(t, until - 0.12, until))
    for (r, row) in rows.enumerated() {
        let widths = row.map { wordImage(words[$0], false).size.width }
        var x = (W - (widths.reduce(0, +) + space * CGFloat(row.count - 1))) / 2
        let yy = y + CGFloat(r) * lineH
        for (j, k) in row.enumerated() {
            let p = progress(t, starts[k], starts[k] + 0.12)
            if p > 0 {
                let speaking = t < (k + 1 < starts.count ? starts[k + 1] : line.end)
                let img = wordImage(words[k], speaking)
                let sc = CGFloat(0.5 + 0.5 * easeOutBack(p)) * (speaking ? 1.06 : 1)
                withTransform(scale: sc, around: CGPoint(x: x + widths[j] / 2, y: yy + img.size.height / 2)) {
                    draw(img, NSRect(x: x, y: yy, width: img.size.width, height: img.size.height), alpha: fade, crisp: true)
                }
            }
            x += widths[j] + space
        }
    }
}

// MARK: cats, room and bubbles

func drawCat(_ coat: String, _ state: CatState, center: CGPoint, px: CGFloat, frame: Int, since: Double = 5, alpha: CGFloat = 1) {
    let (look, dy) = catLook(coat: coat, agent: "claude", state: state, frame: frame, sinceState: since, still: false)
    guard let cg = book.image(look) else { return }
    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    let w = img.size.width * px, h = img.size.height * px
    draw(img, NSRect(x: center.x - w / 2, y: center.y - h / 2 - CGFloat(dy) * px, width: w, height: h), alpha: alpha, crisp: true)
}

func session(_ id: String, _ project: String, _ state: CatState, _ configure: (inout Session) -> Void = { _ in }) -> Session {
    var s = Session(id: id, agent: .claude, at: Date(timeIntervalSince1970: 1_700_000_000))
    s.state = state; s.cwd = "/Users/me/Projects/" + project; s.tty = "ttys00\(id.count)"; s.stateSince = Date()
    configure(&s)
    return s
}
var cast: [Session] = [
    session("a", "web-app", .working) { $0.activity = "Bash npm run deploy" },
    session("b", "api", .thinking),
    session("c", "docs", .working),
    session("d", "mobile", .idle),
]
let names = ["Miso", "Mochi", "Pepper", "Sumi"]

let tree = CatTreeView(book: book)
tree.reduceMotion = false
let room = CatRoomView(tree: tree)
var currentLayout = TreeLayout.compute(ordered: cast, maxWidth: 480)

func renderRoom() -> NSImage {
    currentLayout = TreeLayout.compute(ordered: cast, maxWidth: 480)
    let entries = zip(cast, names).map { CatTreeView.Entry(session: $0.0, cat: $0.1) }
    let treeSize = tree.update(entries: entries, layout: currentLayout)
    let size = room.update(expanded: true, treeSize: treeSize, count: cast.count, attention: cast.filter(\.wantsYou).count)
    room.frame = NSRect(origin: .zero, size: size)
    tree.animate()
    return snapshot(room)
}

/// The cat's bottom-centre in room points (bottom-left origin).
func catAnchor(_ id: String) -> CGPoint {
    guard let slot = currentLayout.slots.first(where: { $0.sessionId == id }) else { return .zero }
    let s = currentLayout.scale
    let treeX = room.bounds.width - currentLayout.width - 16
    let perch = Double(slot.highPerch ? TreeArt.highPost : TreeArt.lowPost)
    return CGPoint(x: treeX + slot.x + (1 + Double(SpriteBook.canvasW) / 2) * s, y: 40 + (3 + perch + 2) * s)
}

var bubbleCache: [String: NSImage] = [:]
func bubbleImage(cat: String, speech: Speech, sent: Bool) -> NSImage {
    let key = "\(cat)|\(speech.token)|\(sent)"
    if let img = bubbleCache[key] { return img }
    let m = BubbleModel()
    m.cat = cat; m.speech = speech; m.reduceMotion = true; m.anim.popped = true; m.anim.shown = speech.text.count
    m.tailOnTop = true; m.tailX = 150; m.showHint = false; m.status = sent ? .sent : .idle
    let host = NSHostingView(rootView: BubbleView(model: m))
    host.frame.size = NSSize(width: 300, height: host.fittingSize.height)
    let img = snapshot(host)
    bubbleCache[key] = img
    return img
}

func dashboardImage() -> NSImage {
    var s = session("a", "web-app", .working) {
        $0.title = "Ship the new checkout page"; $0.model = "claude-opus-5-5"; $0.hookSeen = true; $0.entrypoint = "cli"
        $0.ask = "I want to run the test suite."; $0.activity = "Bash npm test"
        $0.usage.input = 18_000; $0.usage.output = 52_000; $0.usage.cacheRead = 2_900_000; $0.usage.cacheWrite = 80_000
        $0.contextTokens = 58_000; $0.contextWindow = 200_000; $0.costUSD = 3.40
    }
    var earlier = WorkTask(prompt: "fix the flaky login test", startedAt: Date().addingTimeInterval(-1900))
    earlier.files = ["auth.ts"]; earlier.commands = 4; earlier.endedAt = Date().addingTimeInterval(-1500)
    earlier.reply = "Fixed it: the test now waits for the session token. All 212 tests pass."
    var task = WorkTask(prompt: "build the new checkout page", startedAt: Date().addingTimeInterval(-420))
    task.files = ["Checkout.tsx", "cart.ts", "styles.css"]; task.commands = 5; task.reads = 9
    task.steps = ["install dependencies", "run the dev server", "run the test suite"]
    s.tasks = [earlier, task]
    let model = DashboardModel()
    model.book = book; model.reduceMotion = true; model.hooksReady = true
    model.entries = [CatTreeView.Entry(session: s, cat: "Miso")] + zip(cast.dropFirst(), names.dropFirst()).map { CatTreeView.Entry(session: $0.0, cat: $0.1) }
    let host = NSHostingView(rootView: DashboardView(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 880, height: 760)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    return snapshot(host)
}

let askDeploy = Speech(mood: .permission, headline: "Can I do this?", text: "I want to deploy the site.",
                       choices: [.init(label: "Allow", reply: .hook(allow: true), primary: true),
                                 .init(label: "Deny", reply: .hook(allow: false)),
                                 .init(label: "In terminal", reply: .handoff)],
                       textReply: .hookDeny, placeholder: "Or say what to do instead…", token: "1", detail: "Bash npm run deploy")
let askPR = Speech(mood: .question, headline: "Question for you", text: "Tests pass. Want me to open a PR?",
                   choices: [.init(label: "Yes", reply: .keys([]), primary: true), .init(label: "No", reply: .keys([]))],
                   textReply: .keys(prefix: []), placeholder: "Reply to keep going…", token: "2")

// MARK: scene pieces

let mono = NSFont.monospacedSystemFont(ofSize: 25, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 25, weight: .bold)

/// A Claude Code terminal stuck on "Do you want to proceed?", with a red waiting badge.
func drawTerminal(_ r: NSRect, project: String, waited: String, blink: Bool, typed: Int = .max) {
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -14)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    rgb(30, 31, 36).setFill(); NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).fill()
    NSGraphicsContext.restoreGraphicsState()
    rgb(48, 49, 56).setFill()
    NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: 46), xRadius: 18, yRadius: 18).fill()
    NSRect(x: r.minX, y: r.minY + 26, width: r.width, height: 20).fill()
    for (k, c) in [rgb(255, 95, 87), rgb(254, 188, 46), rgb(40, 200, 64)].enumerated() {
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 20 + CGFloat(k) * 28, y: r.minY + 15, width: 16, height: 16)).fill()
    }
    let dim: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: rgb(150, 152, 160)]
    let bright: [NSAttributedString.Key: Any] = [.font: monoBold, .foregroundColor: rgb(235, 236, 240)]
    let accent: [NSAttributedString.Key: Any] = [.font: monoBold, .foregroundColor: orange]
    NSAttributedString(string: "claude — \(project)", attributes: dim).draw(at: NSPoint(x: r.minX + 120, y: r.minY + 9))
    let lines: [(String, [NSAttributedString.Key: Any])] = [
        ("Bash command", dim), ("  npm run deploy", bright), ("", dim),
        ("Do you want to proceed?", bright), ("❯ 1. Yes", accent), ("  2. No", dim),
    ]
    var left = typed
    for (k, l) in lines.enumerated() where left > 0 {
        let shown = String(l.0.prefix(left)); left -= max(1, l.0.count)
        let at = NSPoint(x: r.minX + 28, y: r.minY + 66 + CGFloat(k) * 36)
        let str = NSAttributedString(string: shown, attributes: l.1)
        str.draw(at: at)
        if left <= 0 && blink { orange.setFill(); NSRect(x: at.x + str.size().width + 2, y: at.y + 4, width: 13, height: 24).fill() }
    }
    guard typed == .max || left > 0 else { return }
    let badge = NSRect(x: r.maxX - 250, y: r.maxY - 66, width: 226, height: 46)
    red.withAlphaComponent(blink ? 1 : 0.7).setFill()
    NSBezierPath(roundedRect: badge, xRadius: 23, yRadius: 23).fill()
    let bt = NSAttributedString(string: "WAITING \(waited)", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .heavy), .foregroundColor: NSColor.white])
    bt.draw(at: NSPoint(x: badge.midX - bt.size().width / 2, y: badge.minY + 10))
}

/// A burst of pixel squares from `c`, `age` seconds after it started (y grows downward).
func burst(_ c: CGPoint, age: Double, seed: Int, count: Int = 18, speed: Double = 620, size: CGFloat = 14, gravity: Double = 900, lift: Double = 0) {
    guard age >= 0, age < 1.1 else { return }
    for k in 0..<count {
        let a = rnd(seed, k) * 2 * .pi, v = speed * (0.45 + rnd(seed, k + 99))
        let x = c.x + CGFloat(cos(a) * v * age)
        let y = c.y + CGFloat((sin(a) * v - lift) * age + 0.5 * gravity * age * age)
        let s = size * CGFloat(1 - age / 1.1)
        confettiColors[k % confettiColors.count].withAlphaComponent(CGFloat(1 - age / 1.1)).setFill()
        NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s).fill()
    }
}

func background(_ color: NSColor, floor: Bool) {
    color.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    NSColor.white.withAlphaComponent(0.045).setFill()
    for gx in stride(from: CGFloat(0), to: W, by: 40) { for gy in stride(from: CGFloat(0), to: H, by: 40) where (Int(gx + gy) / 40) % 2 == 0 {
        NSRect(x: gx + 18, y: gy + 18, width: 4, height: 4).fill() } }
    guard floor else { return }
    rgb(158, 110, 74).setFill(); NSRect(x: 0, y: H - 150, width: W, height: 150).fill()
    rgb(110, 74, 51).setFill(); NSRect(x: 0, y: H - 156, width: W, height: 6).fill()
}

// MARK: motion-design helpers

let mint = rgb(127, 208, 188), gold = rgb(245, 196, 81)

/// Scales x and y separately around `p` (squash & stretch).
func withSquash(_ sx: CGFloat, _ sy: CGFloat, around p: CGPoint, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: p.x, yBy: p.y); t.scaleX(by: sx, yBy: sy); t.translateX(by: -p.x, yBy: -p.y); t.concat()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

/// Pixel dust drifting up through the dark, the same in every scene.
func dust(_ t: Double) {
    for k in 0..<40 {
        let speed = 25 + 55 * rnd(k, 3)
        let y = H + 20 - CGFloat((rnd(k, 2) * Double(H + 40) + t * speed).truncatingRemainder(dividingBy: Double(H + 40)))
        let x = CGFloat(rnd(k, 1)) * W + CGFloat(sin(t * 0.7 + Double(k))) * 18
        let s: CGFloat = rnd(k, 4) > 0.7 ? 8 : 5
        (k % 3 == 0 ? orange : cream).withAlphaComponent(CGFloat(0.08 + 0.16 * rnd(k, 5))).setFill()
        NSRect(x: x.rounded(), y: y.rounded(), width: s, height: s).fill()
    }
}

func nightScene(_ t: Double) { background(night, floor: false); dust(t) }

/// CRT scanlines and a vignette over everything.
func crt() {
    NSColor.black.withAlphaComponent(0.13).setFill()
    for y in stride(from: CGFloat(0), to: H, by: 4) { NSRect(x: 0, y: y, width: W, height: 1.5).fill() }
    NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.55)])!
        .draw(fromCenter: NSPoint(x: W / 2, y: H / 2), radius: H * 0.32, toCenter: NSPoint(x: W / 2, y: H / 2), radius: H * 0.72, options: [])
}

func flash(_ color: NSColor, _ amount: Double) {
    guard amount > 0 else { return }
    color.withAlphaComponent(CGFloat(amount)).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
}

/// A shockwave ring.
func ring(_ c: CGPoint, age: Double, color: NSColor = cream, maxR: CGFloat = 260) {
    guard age >= 0, age < 0.45 else { return }
    let k = age / 0.45, r = CGFloat(easeOut(k)) * maxR
    color.withAlphaComponent(CGFloat(1 - k) * 0.9).setStroke()
    let p = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)); p.lineWidth = CGFloat(10 * (1 - k)) + 2; p.stroke()
}

/// Little 4-point pixel stars twinkling around a point.
func sparkles(_ c: CGPoint, age: Double, spread: CGFloat = 180, seed: Int = 1, color: NSColor = gold) {
    guard age >= 0, age < 0.7 else { return }
    for k in 0..<5 {
        let a = rnd(seed, k) * 2 * .pi, d = spread * CGFloat(0.5 + 0.5 * rnd(seed, k + 9))
        let p = CGPoint(x: c.x + cos(a) * d * CGFloat(easeOut(age / 0.7)), y: c.y + sin(a) * d * CGFloat(easeOut(age / 0.7)))
        let s: CGFloat = 7 * CGFloat(1 - age / 0.7) + 2
        color.withAlphaComponent(CGFloat(1 - age / 0.7)).setFill()
        NSRect(x: p.x - s / 2, y: p.y - s * 1.5, width: s, height: s * 3).fill()
        NSRect(x: p.x - s * 1.5, y: p.y - s / 2, width: s * 3, height: s).fill()
    }
}

/// A macOS-style notification card.
func toast(_ r: NSRect, _ title: String, _ body: String) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.5); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
    rgb(44, 46, 54, 0.97).setFill(); NSBezierPath(roundedRect: r, xRadius: 24, yRadius: 24).fill()
    NSGraphicsContext.restoreGraphicsState()
    orange.setFill(); NSBezierPath(roundedRect: NSRect(x: r.minX + 20, y: r.minY + 22, width: 62, height: 62), xRadius: 14, yRadius: 14).fill()
    let paw = pixelText("@", px: 5, color: night)
    draw(paw, NSRect(x: r.minX + 51 - paw.size.width / 2, y: r.minY + 53 - paw.size.height / 2, width: paw.size.width, height: paw.size.height), crisp: true)
    NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: NSColor.white])
        .draw(at: NSPoint(x: r.minX + 100, y: r.minY + 18))
    NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .regular), .foregroundColor: rgb(200, 202, 210)])
        .draw(at: NSPoint(x: r.minX + 100, y: r.minY + 54))
    NSAttributedString(string: "now", attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: rgb(150, 152, 160)])
        .draw(at: NSPoint(x: r.maxX - 66, y: r.minY + 20))
}

/// A pixel-font callout chip.
func chip(_ text: String, center: CGPoint, color: NSColor, alpha: CGFloat = 1) {
    let img = PixelFont.image(text, px: 5, fill: night, shadow: color.withAlphaComponent(0), accent: night)
    let r = NSRect(x: center.x - img.size.width / 2 - 26, y: center.y - img.size.height / 2 - 18, width: img.size.width + 52, height: img.size.height + 32)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.6); sh.shadowBlurRadius = 0; sh.shadowOffset = NSSize(width: 6, height: -6); sh.set()
    color.withAlphaComponent(alpha).setFill(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
    NSGraphicsContext.restoreGraphicsState()
    draw(img, NSRect(x: r.minX + 26, y: r.minY + 18, width: img.size.width, height: img.size.height), alpha: alpha, crisp: true)
}

/// Mm:ss for a number of seconds.
func clock(_ secs: Int) -> String { String(format: "%02d:%02d", secs / 60, secs % 60) }

/// Glitch: horizontal slices of the finished frame jump sideways, with colour bars.
func glitch(_ rep: NSBitmapImageRep, amount: Double, seed: Int) {
    guard amount > 0, let snap = rep.cgImage?.copy() else { return }
    let img = NSImage(cgImage: snap, size: NSSize(width: W, height: H))
    var y: CGFloat = 0, k = 0
    while y < H {
        let hh = CGFloat(20 + 140 * rnd(seed, k))
        let dx = CGFloat(rnd(seed, k + 50) - 0.5) * 160 * CGFloat(amount)
        if rnd(seed, k + 80) < 0.55 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: y, width: W, height: hh)).addClip()
            img.draw(in: NSRect(x: dx, y: 0, width: W, height: H), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        y += hh; k += 1
    }
    for j in 0..<3 {
        [orange, mint, red][j].withAlphaComponent(CGFloat(0.35 * amount)).setFill()
        NSRect(x: 0, y: CGFloat(rnd(seed, j + 200)) * H, width: W, height: CGFloat(6 + 30 * rnd(seed, j + 300))).fill()
    }
}

// MARK: render

let cursor = NSCursor.arrow.image
let dash = dashboardImage()
var roomImg = renderRoom()
var lastRoomTick = -1
var phase = -1
let captionY: CGFloat = 270
let coats = ["Miso", "Mochi", "Pepper", "Sumi", "Oreo"]
let poofStates: [CatState] = [.permission, .working, .thinking, .done, .question]
let terminals: [(CGPoint, CGFloat, String, String)] = [   // centre, tilt, project, waited
    (CGPoint(x: 400, y: 760), -4, "web-app", "47:12"), (CGPoint(x: 680, y: 920), 3, "api", "22:40"),
    (CGPoint(x: 420, y: 1090), 2, "docs", "31:05"), (CGPoint(x: 670, y: 1260), -3, "mobile", "12:58"),
    (CGPoint(x: 450, y: 1420), 1, "infra", "08:33"),
]
let toasts = [("web-app", "is waiting for your approval"), ("api", "needs your input"),
              ("docs", "Do you want to proceed?"), ("mobile", "is waiting for your approval")]
let hookSeconds = 47 * 60 + 12
var trail: [CGPoint] = []
let glitches: [(Double, Double)] = [(S(1) + 0.22, 0.2), (S(2) - 0.12, 0.22), (S(6) - 0.12, 0.2), (S(7) - 0.12, 0.22), (timeline.duration - 0.22, 0.22)]

let frameCount = Int(timeline.duration * FPS)
for f in 0..<frameCount {
    let t = Double(f) / FPS
    let fr = Int(t * 6)   // sprites animate at 6 fps, like the app

    // Story beats drive the cats in the room.
    let wanted = t < S(3) ? 0 : t < S(4) + 0.2 ? 1 : t < S(5) ? 2 : t < S(6) - 0.2 ? 3 : 4
    if wanted != phase {
        phase = wanted
        switch phase {
        case 0: break
        case 1: cast[0].state = .permission; cast[0].stateSince = Date()
        case 2: cast[0].state = .done; cast[0].stateSince = Date()
        case 3: cast[0].state = .working; cast[2].state = .done; cast[2].lastMessage = "Tests pass. Want me to open a PR?"; cast[2].stateSince = Date()
        default: cast[2].state = .working
        }
        roomImg = renderRoom(); lastRoomTick = f
    } else if f - lastRoomTick >= 5 {
        roomImg = renderRoom(); lastRoomTick = f
    }

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(cgContext: NSGraphicsContext(bitmapImageRep: rep)!.cgContext, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let flip = NSAffineTransform(); flip.translateX(by: 0, yBy: H); flip.scaleX(by: 1, yBy: -1); flip.concat()

    // ── Scenes 0–1: the hook. Terminals type, notifications pile up, the timer climbs… POOF: cats.
    if t < S(2) + 0.35 {
        nightScene(t)
        let tension = progress(t, 0.2, S(1))
        let maxedAt = E(0) - 0.2
        let slam = t >= maxedAt && t < maxedAt + 0.35 ? CGFloat(1 - progress(t, maxedAt, maxedAt + 0.35)) * 26 : 0
        let shake = t < S(1) + 0.25 ? CGFloat(tension * 8) + slam : 0
        let leave = easeInOut(progress(t, S(2) - 0.05, S(2) + 0.35))
        let shift = CGPoint(x: CGFloat(rnd(f, 1) - 0.5) * shake, y: CGFloat(rnd(f, 2) - 0.5) * shake - CGFloat(leave) * 1500)
        cue("whoosh", at: 0.0, t, gain: 0.5)
        withTransform(scale: 1 + CGFloat(tension) * 0.06, around: CGPoint(x: W / 2, y: 1080), shift: shift) {
            for (k, term) in terminals.enumerated().reversed() {   // the 47:12 one on top
                let appearAt = Double(k) * 0.09
                cue("pop", at: appearAt + 0.05, t, gain: 0.35)
                let appear = easeOutBack(progress(t, appearAt, appearAt + 0.35))
                let poofAt = S(1) + 0.3 + Double(k) * 0.13
                let gone = progress(t, poofAt - 0.12, poofAt)
                if gone < 1 && appear > 0 {
                    let secs = k == 0 ? Int(easeOut(progress(t, 0.2, maxedAt)) * Double(hookSeconds)) : 0
                    let typed = Int(max(0, t - appearAt - 0.1) * 95)
                    withTransform(scale: CGFloat(appear * (1 - gone)), around: term.0, rotate: term.1) {
                        drawTerminal(NSRect(x: term.0.x - 330, y: term.0.y - 160, width: 660, height: 320), project: term.2,
                                     waited: k == 0 ? clock(secs) : term.3, blink: (f / 8) % 2 == 0, typed: typed)
                    }
                }
                cue("poof", at: poofAt, t, gain: 0.7)
                ring(term.0, age: t - poofAt, color: k % 2 == 0 ? cream : orange)
                burst(term.0, age: t - poofAt, seed: k * 7 + 1, count: 22, speed: 700, size: 18, gravity: 500)
                let catIn = progress(t, poofAt, poofAt + 0.4)
                if catIn > 0 {
                    // Squash and stretch as each cat pops out.
                    let b = CGFloat(easeOutBack(catIn))
                    let wob = CGFloat(sin(catIn * .pi * 3) * (1 - catIn)) * 0.25
                    let bob = CGFloat(sin((t - poofAt) * 5 + Double(k))) * 8
                    withSquash(b * (1 + wob), b * (1 - wob), around: term.0) {
                        drawCat(coats[k], poofStates[k], center: CGPoint(x: term.0.x, y: term.0.y + bob), px: 10, frame: fr + k, since: t - poofAt)
                    }
                }
            }
            // Notifications pile up on the right.
            for (k, n) in toasts.enumerated() {
                let at = 0.75 + Double(k) * 0.42
                let inP = easeOutBack(progress(t, at, at + 0.3))
                let out = progress(t, S(1) + 0.2, S(1) + 0.32)
                guard inP > 0, out < 1 else { continue }
                cue("notify", at: at, t, gain: 0.55)
                let r = NSRect(x: W - 640 + CGFloat(1 - inP) * 700, y: 590 + CGFloat(k) * 132, width: 600, height: 106)
                withTransform(scale: CGFloat(1 - out), around: CGPoint(x: r.midX, y: r.midY)) { toast(r, "Claude Code", "\(n.0) \(n.1)") }
            }
        }
        cue("meow", at: S(1) + 0.3 + 4 * 0.13 + 0.2, t, gain: 0.9)
        cue("thud", at: maxedAt, t, gain: 0.8)
        // Big red timer that slams when it hits 47:12.
        let timerA = CGFloat(progress(t, 0.15, 0.4) * (1 - progress(t, S(1) + 0.1, S(1) + 0.3)))
        if timerA > 0 {
            let secs = Int(easeOut(progress(t, 0.2, maxedAt)) * Double(hookSeconds))
            let pop = t >= maxedAt ? 1 + 0.25 * CGFloat(1 - easeOut(progress(t, maxedAt, maxedAt + 0.3))) : 1 + 0.04 * CGFloat(sin(t * 18))
            drawPixelCentered(clock(secs), px: 22, y: 1660, scale: pop, alpha: timerA, color: red)
        }
        flash(red, t >= maxedAt ? 0.28 * (1 - progress(t, maxedAt, maxedAt + 0.35)) : 0)
        flash(.white, t >= S(1) + 0.3 ? 0.5 * (1 - progress(t, S(1) + 0.3, S(1) + 0.42)) : 0)
    }

    // ── Scenes 2–5: the room under the menu bar, with bubbles.
    if t >= S(2) - 0.1 && t < S(6) + 0.3 {
        let enter = progress(t, S(2) - 0.1, S(2) + 0.5)
        let leave = easeInOut(progress(t, S(6) - 0.15, S(6) + 0.3))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: H * CGFloat(1 - easeOut(progress(t, S(2) - 0.1, S(2) + 0.2))), width: W, height: H)).addClip()
        nightScene(t)
        NSGraphicsContext.restoreGraphicsState()
        cue("whoosh", at: S(2) - 0.05, t, gain: 0.7)
        let Sc: CGFloat = 960 / roomImg.size.width
        let rw = roomImg.size.width * Sc, rh = roomImg.size.height * Sc
        let rx = (W - rw) / 2
        let ry = 620 - (1 - CGFloat(easeOutBack(enter))) * 900 - CGFloat(leave) * 1700
        let a0 = catAnchor("a"), a2 = catAnchor("c")
        let focusA = CGPoint(x: rx + a0.x * Sc, y: ry + (roomImg.size.height - a0.y) * Sc + 120)
        let focusC = CGPoint(x: rx + a2.x * Sc, y: ry + (roomImg.size.height - a2.y) * Sc + 120)
        var focus = CGPoint(x: W / 2, y: ry + rh)
        var zoom = 1.0
        if t >= S(3) {
            zoom = 1 + 0.12 * easeInOut(progress(t, S(3), S(3) + 0.8))
            let toC = CGFloat(easeInOut(progress(t, S(5) - 0.2, S(5) + 0.4)))
            focus = CGPoint(x: focusA.x + (focusC.x - focusA.x) * toC, y: focusA.y + (focusC.y - focusA.y) * toC)
        }
        let punch = t >= S(4) + 0.2 && t < S(4) + 0.45 ? 0.03 * sin(progress(t, S(4) + 0.2, S(4) + 0.45) * .pi) : 0
        let kick = t >= S(4) + 0.2 && t < S(4) + 0.5 ? CGFloat(1 - progress(t, S(4) + 0.2, S(4) + 0.5)) * 12 : 0
        let kickShift = CGPoint(x: CGFloat(rnd(f, 5) - 0.5) * kick, y: CGFloat(rnd(f, 6) - 0.5) * kick)
        // Soft orange glow behind the room.
        NSGradient(colors: [orange.withAlphaComponent(0.20), orange.withAlphaComponent(0)])!
            .draw(fromCenter: NSPoint(x: W / 2, y: ry + rh / 2), radius: 0, toCenter: NSPoint(x: W / 2, y: ry + rh / 2), radius: 700, options: [])
        withTransform(scale: CGFloat(zoom + punch), around: focus, shift: kickShift) {
            rgb(20, 20, 22, 0.92).setFill(); NSRect(x: -200, y: ry - 70, width: W + 400, height: 54).fill()
            let paw = pixelText("@", px: 4)
            draw(paw, NSRect(x: rx + rw - 140, y: ry - 58, width: paw.size.width, height: paw.size.height), crisp: true)
            NSAttributedString(string: "9:41", attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.white])
                .draw(at: NSPoint(x: rx + rw - 70, y: ry - 58))
            // Motion-blur ghosts while the room drops in.
            if enter < 1 {
                for g in 1...3 { draw(roomImg, NSRect(x: rx, y: ry - CGFloat(g) * 60 * CGFloat(1 - enter), width: rw, height: rh), alpha: 0.18, crisp: true) }
            }
            draw(roomImg, NSRect(x: rx, y: ry, width: rw, height: rh), crisp: true)

            func showBubble(_ id: String, _ cat: String, _ speech: Speech, from: Double, until: Double, clickAt: Double,
                            click: (x: CGFloat, y: CGFloat), confetti: Bool) {
                guard t >= from && t < until else { return }
                cue("pop", at: from, t, gain: 0.8)
                let a = catAnchor(id)
                let img = bubbleImage(cat: cat, speech: speech, sent: t >= clickAt && confetti)
                let bw = img.size.width * Sc, bh = img.size.height * Sc
                let ax = rx + a.x * Sc, ay = ry + (roomImg.size.height - a.y) * Sc
                let bx = min(max(ax - bw / 2, 40), W - bw - 40), by = ay - 8
                let p = progress(t, from, from + 0.35)
                let pop = CGFloat(easeOutBack(p)), wob = CGFloat(sin(p * .pi * 2) * (1 - p)) * 0.12
                let fade = CGFloat(1 - progress(t, until - 0.2, until))
                withSquash(pop * (1 - wob), pop * (1 + wob), around: CGPoint(x: ax, y: by)) {
                    draw(img, NSRect(x: bx, y: by, width: bw, height: bh), alpha: fade)
                }
                sparkles(CGPoint(x: bx + bw - 20, y: by + 30), age: t - from, spread: 120, seed: id.count + 3)
                sparkles(CGPoint(x: bx + 20, y: by + bh - 20), age: t - from - 0.1, spread: 100, seed: id.count + 7, color: cream)
                let target = CGPoint(x: bx + click.x * Sc, y: by + click.y * Sc)
                if confetti { burst(target, age: t - clickAt, seed: 42, count: 36, speed: 650, size: 16, gravity: 1500, lift: 600) }
                ring(target, age: t - clickAt, color: orange, maxR: 110)
                guard t >= clickAt - 1.2 else { return }
                cue("click", at: clickAt, t)
                if confetti { cue("chime", at: clickAt + 0.05, t, gain: 0.8) }
                func pos(_ tt: Double) -> CGPoint {
                    let m = CGFloat(easeInOut(progress(tt, clickAt - 1.2, clickAt - 0.12)))
                    let start = CGPoint(x: W - 100, y: H - 260)
                    let arc = sin(Double(m) * .pi) * 120   // swoop in on a curve
                    return CGPoint(x: start.x + (target.x - start.x) * m - CGFloat(arc), y: start.y + (target.y - start.y) * m)
                }
                let press: CGFloat = t >= clickAt - 0.1 && t < clickAt + 0.06 ? 0.82 : 1
                for g in stride(from: 4, through: 1, by: -1) {   // motion trail
                    let gp = pos(t - Double(g) * 0.035)
                    draw(cursor, NSRect(x: gp.x - 4, y: gp.y - 4, width: cursor.size.width * 2.6, height: cursor.size.height * 2.6), alpha: fade * 0.12 * CGFloat(5 - g))
                }
                let cp = pos(t)
                draw(cursor, NSRect(x: cp.x - 4, y: cp.y - 4, width: cursor.size.width * 2.6 * press, height: cursor.size.height * 2.6 * press), alpha: fade)
            }
            let prClick = max(S(5) + 1.5, E(5) - 0.25)
            showBubble("a", "Miso", askDeploy, from: S(3) + 0.35, until: S(5) - 0.15, clickAt: S(4) + 0.2, click: (32, 112), confetti: true)
            showBubble("c", "Pepper", askPR, from: S(5) + 0.2, until: S(6) - 0.1, clickAt: prClick, click: (32, 64), confetti: false)
            // Payoff for the question: the PR opens.
            let prIn = progress(t, prClick + 0.12, prClick + 0.4) * (1 - progress(t, S(6) - 0.25, S(6) - 0.1))
            if prIn > 0 {
                cue("pop", at: prClick + 0.12, t, gain: 0.7)
                withTransform(scale: CGFloat(easeOutBack(prIn)), around: CGPoint(x: focusC.x, y: focusC.y + 330)) {
                    chip("PR OPENED!", center: CGPoint(x: focusC.x, y: focusC.y + 330), color: mint)
                }
            }
        }
        cue("alert", at: S(3), t, gain: 0.5)
        // Callback to the hook: the timer rolls from 47:12 down to 00:01.
        let rollAt = S(4) + 0.3
        let timerIn = progress(t, rollAt, rollAt + 0.15) * (1 - progress(t, S(5) - 0.3, S(5) - 0.05))
        if timerIn > 0 {
            cue("roll", at: rollAt, t, gain: 0.6)
            let k = easeOut(progress(t, rollAt, rollAt + 0.7))
            let secs = max(1, Int(Double(hookSeconds) * (1 - k)))
            let col = k >= 1 ? mint : red.blended(withFraction: CGFloat(k), of: mint) ?? mint
            let land = t >= rollAt + 0.7 ? 1 + 0.2 * CGFloat(1 - easeOut(progress(t, rollAt + 0.7, rollAt + 1.0))) : 1
            drawPixelCentered("WAITED", px: 6, y: 1520, alpha: CGFloat(timerIn), color: col)
            drawPixelCentered(clock(secs), px: 22, y: 1640, scale: land, alpha: CGFloat(timerIn), color: col)
            sparkles(CGPoint(x: W / 2, y: 1640), age: t - rollAt - 0.7, spread: 300, seed: 77, color: mint)
            cue("chime", at: rollAt + 0.7, t, gain: 0.6)
        }
    }

    // ── Scene 6: the dashboard, scanned and called out.
    if t >= S(6) - 0.1 && t < S(7) + 0.3 {
        if t >= S(6) + 0.3 { nightScene(t) }
        cue("whoosh", at: S(6) - 0.1, t, gain: 0.6)
        let rise = easeOutBack(progress(t, S(6) - 0.1, S(6) + 0.45))
        let leave = easeInOut(progress(t, S(7) - 0.1, S(7) + 0.3))
        let src = NSRect(x: 260, y: 760 - 535, width: 620, height: 535)
        let scale: CGFloat = 1000 / src.width
        let dw = src.width * scale, dh = src.height * scale
        let dx = (W - dw) / 2
        let dy = 600 + (1 - CGFloat(rise)) * 1200 - CGFloat(leave) * 1600
        let push = 1 + 0.05 * CGFloat(progress(t, S(6), S(7)))
        withTransform(scale: push, around: CGPoint(x: W / 2, y: dy + 260)) {
            let card = NSRect(x: dx, y: dy, width: dw, height: dh)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = orange.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 60; shadow.shadowOffset = .zero; shadow.set()
            cream.setFill(); NSBezierPath(roundedRect: card, xRadius: 28, yRadius: 28).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: card, xRadius: 28, yRadius: 28).addClip()
            dash.draw(in: card, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            // A scan light sweeps down the card.
            let sweep = progress(t, S(6) + 0.3, S(6) + 1.3)
            if sweep > 0 && sweep < 1 {
                let sy = dy + CGFloat(sweep) * dh
                NSGradient(colors: [mint.withAlphaComponent(0), mint.withAlphaComponent(0.45), mint.withAlphaComponent(0)])!
                    .draw(in: NSRect(x: dx, y: sy - 60, width: dw, height: 120), angle: 90)
            }
            NSGraphicsContext.restoreGraphicsState()
            let glow = progress(t, S(6) + 0.6, S(6) + 1.0) * (1 - progress(t, S(7) - 0.3, S(7)))
            if glow > 0 {
                orange.withAlphaComponent(CGFloat(glow)).setStroke()
                let box = NSBezierPath(roundedRect: NSRect(x: dx + 12, y: dy + 345, width: dw - 24, height: 215), xRadius: 14, yRadius: 14)
                box.lineWidth = 6; box.stroke()
            }
            // Callouts fly in from the sides.
            let callouts: [(String, CGFloat, CGFloat, NSColor)] = [("3 FILES CHANGED", 300, dy + 110, orange), ("5 COMMANDS RUN", W - 300, dy + 300, gold), ("212 TESTS PASS", 300, dy + 640, mint)]
            for (k, c) in callouts.enumerated() {
                let at = S(6) + 0.7 + Double(k) * 0.28
                let p = easeOutBack(progress(t, at, at + 0.35))
                guard p > 0 else { continue }
                cue("pop", at: at, t, gain: 0.6)
                let from: CGFloat = c.1 < W / 2 ? -500 : W + 500
                let x = from + (c.1 - from) * CGFloat(p)
                chip(c.0, center: CGPoint(x: x, y: c.2), color: c.3)
            }
        }
    }

    // ── Scene 7: the lucky cat beckons, the bell rings, the name types itself.
    if t >= S(7) - 0.1 {
        let enter = easeOut(progress(t, S(7) - 0.1, S(7) + 0.2))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: H * CGFloat(1 - enter), width: W, height: H)).addClip()
        nightScene(t)
        let catC = CGPoint(x: W / 2, y: 800)
        NSGradient(colors: [orange.withAlphaComponent(0.38), orange.withAlphaComponent(0.08), orange.withAlphaComponent(0)])!
            .draw(fromCenter: catC, radius: 0, toCenter: catC, radius: 520, options: [])
        let landAt = S(7) + 0.35
        let fall = easeInOut(progress(t, S(7) + 0.05, landAt))
        let px: CGFloat = 15
        let cw = CGFloat(LogoArt.w) * px, ch = CGFloat(LogoArt.h) * px
        let baseY = catC.y + ch / 2   // feet
        // Squash on landing, then settle.
        let since = t - landAt
        var sx: CGFloat = 1, sy: CGFloat = 1
        if since >= 0 && since < 0.45 {
            let k = since / 0.45
            let s = CGFloat(sin(k * .pi * 2.5) * (1 - k)) * 0.18
            sx = 1 + s; sy = 1 - s
        } else if since < 0 { sx = 0.9; sy = 1.12 }
        cue("thud", at: landAt, t, gain: 0.8)
        cue("bell", at: landAt + 0.25, t, gain: 0.9)
        cue("bell", at: landAt + 1.6, t, gain: 0.6)
        let floorShadow = CGFloat(fall)
        NSColor.black.withAlphaComponent(0.45 * floorShadow).setFill()
        NSBezierPath(ovalIn: NSRect(x: W / 2 - 230 * floorShadow, y: baseY - 18, width: 460 * floorShadow, height: 40)).fill()
        burst(CGPoint(x: W / 2 - 200, y: baseY), age: since, seed: 91, count: 10, speed: 300, size: 12, gravity: 200)
        burst(CGPoint(x: W / 2 + 200, y: baseY), age: since, seed: 92, count: 10, speed: 300, size: 12, gravity: 200)
        if fall > 0 {
            let y = (baseY - ch) - CGFloat(1 - fall) * 1100
            let paw = since > 0.3 ? (sin((since - 0.3) * 9) > 0 ? 1.0 : 0.35) : 1.0
            let img = LogoArt.image(paw: paw, tail: sin(t * 3), bell: since > 0 ? sin(since * 11) * exp(-since * 0.8) + 0.3 * sin(t * 6) : 0)
            withSquash(sx, sy, around: CGPoint(x: W / 2, y: baseY)) {
                draw(img, NSRect(x: W / 2 - cw / 2, y: y, width: cw, height: ch), crisp: true)
            }
        }
        // The bell glints.
        let bellAt = CGPoint(x: W / 2 + cw * 0.36, y: baseY - ch * 0.38)
        sparkles(bellAt, age: since - 0.25, spread: 150, seed: 5)
        sparkles(bellAt, age: since - 1.6, spread: 130, seed: 6)
        // The name types itself, terminal style.
        let title = "AGENT CATS"
        let typed = min(title.count, Int(max(0, t - (S(7) + 0.55)) * 16))
        if t >= S(7) + 0.5 {
            let full = pixelText(title, px: 13)
            let part = pixelText(String(title.prefix(typed)), px: 13)
            let x0 = (W - full.size.width) / 2, ty: CGFloat = 1170
            if typed > 0 { draw(part, NSRect(x: x0, y: ty, width: part.size.width, height: part.size.height), crisp: true) }
            if (f / 8) % 2 == 0 || typed < title.count {
                orange.setFill(); NSRect(x: x0 + (typed > 0 ? part.size.width + 8 : 0), y: ty, width: 13 * 5, height: 13 * 7).fill()
            }
        }
        drawPixelCentered("FOR CLAUDE CODE & CODEX", px: 6, y: 1330, alpha: CGFloat(progress(t, S(7) + 1.25, S(7) + 1.5)))
        let cta = progress(t, S(7) + 1.5, S(7) + 1.8)
        if cta > 0 {
            cue("pop", at: S(7) + 1.5, t, gain: 0.7)
            let bounce = CGFloat(abs(sin(t * 5))) * 16
            drawPixelCentered("LINK IN BIO", px: 9, y: 1450, scale: CGFloat(easeOutBack(cta)), color: orange)
            drawPixelCentered("V", px: 7, y: 1540 + bounce, alpha: CGFloat(cta), color: orange)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    crt()
    for i in 0..<L.count { caption(i, t: t, y: captionY) }
    for (k, gl) in glitches.enumerated() where t >= gl.0 && t < gl.0 + gl.1 {
        cue("glitch", at: gl.0, t, gain: 0.6)
        glitch(rep, amount: sin(progress(t, gl.0, gl.0 + gl.1) * .pi), seed: f * 13 + k)
    }

    NSGraphicsContext.restoreGraphicsState()
    // Stream raw RGBA rows to stdout; ffmpeg encodes on the fly, so no frames touch the disk.
    let rowBytes = Int(W) * 4
    let data = rep.bitmapData!
    for y in 0..<Int(H) { FileHandle.standardOutput.write(Data(bytes: data + y * rep.bytesPerRow, count: rowBytes)) }
    if f % 90 == 0 { FileHandle.standardError.write("frame \(f)/\(frameCount)\n".data(using: .utf8)!) }
}
let sfx = try! JSONSerialization.data(withJSONObject: cues, options: [.prettyPrinted])
try! sfx.write(to: outDir.appendingPathComponent("sfx.json"))
FileHandle.standardError.write("rendered \(frameCount) frames, \(cues.count) sound cues\n".data(using: .utf8)!)
