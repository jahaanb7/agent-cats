import AppKit
import SwiftUI

// Renders the 1080×1920 promo reel from the app's own views (room, cats, bubbles, dashboard).
// Driven by Tools/make-reel.sh, which records the voiceover first and passes its timing here:
//   reel <timeline.json> <frames-dir>
// Writes f0000.png… plus sfx.json (sound-effect cues) into the frames folder.

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
func drawTerminal(_ r: NSRect, project: String, waited: String, blink: Bool) {
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
    for (k, l) in lines.enumerated() {
        NSAttributedString(string: l.0, attributes: l.1).draw(at: NSPoint(x: r.minX + 28, y: r.minY + 66 + CGFloat(k) * 36))
    }
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
let hookSeconds = 47 * 60 + 12

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

    // ── Scenes 0–1: the hook. Stuck terminals, a climbing timer, then POOF: cats.
    if t < S(2) + 0.35 {
        background(night, floor: false)
        let wipe = easeInOut(progress(t, S(1) + 0.15, S(1) + 0.75))
        if wipe > 0 {
            rgb(28, 36, 40).setFill()
            let r = CGFloat(wipe) * 1250
            NSBezierPath(ovalIn: NSRect(x: W / 2 - r, y: 1080 - r, width: r * 2, height: r * 2)).fill()
        }
        let tension = progress(t, 0.2, S(1))
        let shake = t < S(1) + 0.25 ? CGFloat(tension * 8) : 0
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
                    var waited = term.3
                    if k == 0 {
                        let secs = Int(easeOut(progress(t, 0.2, E(0) - 0.2)) * Double(hookSeconds))
                        waited = String(format: "%02d:%02d", secs / 60, secs % 60)
                    }
                    withTransform(scale: CGFloat(appear * (1 - gone)), around: term.0, rotate: term.1) {
                        drawTerminal(NSRect(x: term.0.x - 330, y: term.0.y - 160, width: 660, height: 320), project: term.2, waited: waited, blink: (f / 8) % 2 == 0)
                    }
                }
                cue("poof", at: poofAt, t, gain: 0.7)
                burst(term.0, age: t - poofAt, seed: k * 7 + 1, count: 22, speed: 700, size: 18, gravity: 500)
                let catIn = easeOutBack(progress(t, poofAt, poofAt + 0.4))
                if catIn > 0 {
                    let bob = CGFloat(sin((t - poofAt) * 5 + Double(k))) * 8
                    withTransform(scale: CGFloat(catIn), around: term.0) {
                        drawCat(coats[k], poofStates[k], center: CGPoint(x: term.0.x, y: term.0.y + bob), px: 10, frame: fr + k, since: t - poofAt)
                    }
                }
            }
        }
        cue("meow", at: S(1) + 0.3 + 4 * 0.13 + 0.2, t, gain: 0.9)
        // Big red timer under the stack while the hook plays.
        let timerA = CGFloat(progress(t, 0.15, 0.4) * (1 - progress(t, S(1) + 0.1, S(1) + 0.3)))
        if timerA > 0 {
            let secs = Int(easeOut(progress(t, 0.2, E(0) - 0.2)) * Double(hookSeconds))
            let pulse = 1 + 0.05 * CGFloat(sin(t * 18))
            drawPixelCentered(String(format: "%02d:%02d", secs / 60, secs % 60), px: 22, y: 1660, scale: pulse, alpha: timerA, color: red)
        }
    }

    // ── Scenes 2–5: the room under the menu bar, with bubbles.
    if t >= S(2) - 0.1 && t < S(6) + 0.3 {
        let enter = progress(t, S(2) - 0.1, S(2) + 0.5)
        let leave = easeInOut(progress(t, S(6) - 0.15, S(6) + 0.3))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: H * CGFloat(1 - easeOut(progress(t, S(2) - 0.1, S(2) + 0.2))), width: W, height: H)).addClip()
        background(night, floor: false)
        NSGraphicsContext.restoreGraphicsState()
        cue("whoosh", at: S(2) - 0.05, t, gain: 0.7)
        let Sc: CGFloat = 960 / roomImg.size.width
        let rw = roomImg.size.width * Sc, rh = roomImg.size.height * Sc
        let rx = (W - rw) / 2
        let ry = 620 - (1 - CGFloat(easeOutBack(enter))) * 900 - CGFloat(leave) * 1700
        // Camera pushes in on whichever bubble is talking.
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
        withTransform(scale: CGFloat(zoom + punch), around: focus, shift: kickShift) {
            rgb(20, 20, 22, 0.92).setFill(); NSRect(x: -200, y: ry - 70, width: W + 400, height: 54).fill()
            let paw = pixelText("@", px: 4)
            draw(paw, NSRect(x: rx + rw - 140, y: ry - 58, width: paw.size.width, height: paw.size.height), crisp: true)
            NSAttributedString(string: "9:41", attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.white])
                .draw(at: NSPoint(x: rx + rw - 70, y: ry - 58))
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
                let pop = CGFloat(easeOutBack(progress(t, from, from + 0.35)))
                let fade = CGFloat(1 - progress(t, until - 0.2, until))
                withTransform(scale: pop, around: CGPoint(x: ax, y: by)) {
                    draw(img, NSRect(x: bx, y: by, width: bw, height: bh), alpha: fade)
                }
                let target = CGPoint(x: bx + click.x * Sc, y: by + click.y * Sc)
                if confetti { burst(target, age: t - clickAt, seed: 42, count: 36, speed: 650, size: 16, gravity: 1500, lift: 600) }
                guard t >= clickAt - 1.2 else { return }
                cue("click", at: clickAt, t)
                if confetti { cue("chime", at: clickAt + 0.05, t, gain: 0.8) }
                let move = easeInOut(progress(t, clickAt - 1.2, clickAt - 0.12))
                let start = CGPoint(x: W - 100, y: H - 260)
                let cx = start.x + (target.x - start.x) * CGFloat(move), cy = start.y + (target.y - start.y) * CGFloat(move)
                let press: CGFloat = t >= clickAt - 0.1 && t < clickAt + 0.06 ? 0.82 : 1
                if t >= clickAt - 0.05 && t < clickAt + 0.5 {
                    let k = progress(t, clickAt - 0.05, clickAt + 0.5)
                    orange.withAlphaComponent(CGFloat(1 - k) * 0.9).setStroke()
                    let r = CGFloat(k) * 80
                    let ring = NSBezierPath(ovalIn: NSRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2))
                    ring.lineWidth = 7; ring.stroke()
                }
                draw(cursor, NSRect(x: cx - 4, y: cy - 4, width: cursor.size.width * 2.6 * press, height: cursor.size.height * 2.6 * press), alpha: fade)
            }
            showBubble("a", "Miso", askDeploy, from: S(3) + 0.35, until: S(5) - 0.15, clickAt: S(4) + 0.2, click: (32, 112), confetti: true)
            showBubble("c", "Pepper", askPR, from: S(5) + 0.2, until: S(6) - 0.1, clickAt: max(S(5) + 1.5, E(5) - 0.25), click: (32, 64), confetti: false)
        }
        cue("alert", at: S(3), t, gain: 0.5)
        // Callback to the hook: the wait is now one second.
        let timerIn = progress(t, S(4) + 0.35, S(4) + 0.6) * (1 - progress(t, S(5) - 0.3, S(5) - 0.05))
        if timerIn > 0 {
            let mint = rgb(127, 208, 188)
            drawPixelCentered("WAITED", px: 6, y: 1520, alpha: CGFloat(timerIn), color: mint)
            drawPixelCentered("00:01", px: 22, y: 1640, scale: CGFloat(easeOutBack(progress(t, S(4) + 0.35, S(4) + 0.7))), alpha: CGFloat(timerIn), color: mint)
        }
    }

    // ── Scene 6: the dashboard's recent-work card.
    if t >= S(6) - 0.1 && t < S(7) + 0.3 {
        if t >= S(6) + 0.3 { background(night, floor: false) }
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
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -20); shadow.set()
            cream.setFill(); NSBezierPath(roundedRect: card, xRadius: 28, yRadius: 28).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: card, xRadius: 28, yRadius: 28).addClip()
            dash.draw(in: card, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            // Highlight the "working on" summary as it's mentioned.
            let glow = progress(t, S(6) + 0.6, S(6) + 1.0) * (1 - progress(t, S(7) - 0.3, S(7)))
            if glow > 0 {
                orange.withAlphaComponent(CGFloat(glow)).setStroke()
                let box = NSBezierPath(roundedRect: NSRect(x: dx + 12, y: dy + 345, width: dw - 24, height: 215), xRadius: 14, yRadius: 14)
                box.lineWidth = 6; box.stroke()
            }
        }
    }

    // ── Scene 7: end card with the gang.
    if t >= S(7) - 0.1 {
        let enter = easeOut(progress(t, S(7) - 0.1, S(7) + 0.25))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: H * CGFloat(1 - enter), width: W, height: H)).addClip()
        background(night, floor: false)
        cue("pop", at: S(7) + 0.05, t, gain: 0.9)
        drawPixelCentered("@ AGENT CATS", px: 13, y: 700, scale: CGFloat(easeOutBack(progress(t, S(7) + 0.05, S(7) + 0.55))))
        drawPixelCentered("FOR CLAUDE CODE & CODEX", px: 6, y: 830, alpha: CGFloat(progress(t, S(7) + 0.5, S(7) + 0.8)))
        let gang: [CatState] = [.working, .thinking, .done, .idle, .question]
        for k in 0..<5 {
            let at = S(7) + 0.4 + Double(k) * 0.12
            let hop = easeOutBack(progress(t, at, at + 0.35))
            guard hop > 0 else { continue }
            let x = W / 2 + CGFloat(k - 2) * 190
            let y = 1120 + (1 - CGFloat(hop)) * 400 - CGFloat(max(0, sin((t - at) * 6 + Double(k)))) * 14
            drawCat(coats[k], gang[k], center: CGPoint(x: x, y: y), px: 6, frame: fr + k, since: t - at)
        }
        let cta = progress(t, S(7) + 0.9, S(7) + 1.2)
        if cta > 0 {
            cue("chime", at: S(7) + 0.9, t, gain: 0.5)
            let bounce = CGFloat(abs(sin(t * 5))) * 16
            drawPixelCentered("LINK IN BIO", px: 9, y: 1370, scale: CGFloat(easeOutBack(cta)), color: orange)
            drawPixelCentered("V", px: 7, y: 1460 + bounce, alpha: CGFloat(cta), color: orange)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    for i in 0..<L.count { caption(i, t: t, y: captionY) }

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outDir.appendingPathComponent(String(format: "f%04d.png", f)))
    if f % 90 == 0 { print("frame \(f)/\(frameCount)") }
}
let sfx = try! JSONSerialization.data(withJSONObject: cues, options: [.prettyPrinted])
try! sfx.write(to: outDir.appendingPathComponent("sfx.json"))
print("rendered \(frameCount) frames, \(cues.count) sound cues")
