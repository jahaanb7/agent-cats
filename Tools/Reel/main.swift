import AppKit
import SwiftUI

// Renders a 1080×1920 vertical promo reel from the app's own views (room, cats, bubble, dashboard).
// Usage: Tools/make-reel.sh   → dist/agent-cats-reel.mp4
// Frames are written to the folder given as the first argument.

let W: CGFloat = 1080, H: CGFloat = 1920, FPS = 30.0, DURATION = 22.5
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dist/reel-frames")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let app = NSApplication.shared
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard let book = SpriteBook(url: root.appendingPathComponent("Art/cats.json")) else { fatalError("missing sprites") }

// MARK: palette and helpers

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let forest = rgb(46, 66, 58), forestDark = rgb(33, 48, 42), cream = rgb(246, 233, 203), orange = rgb(235, 140, 84)
let ink = rgb(36, 56, 48)

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOutBack(_ x: Double) -> Double { let c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2) }

func snapshot(_ v: NSView) -> NSImage {
    v.layoutSubtreeIfNeeded()
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    let img = NSImage(size: v.bounds.size); img.addRepresentation(rep)
    return img
}

/// Draws `img` (point size) at `rect` in the flipped canvas, optionally pixel-crisp.
func draw(_ img: NSImage, _ rect: NSRect, alpha: CGFloat = 1, crisp: Bool = false) {
    let ctx = NSGraphicsContext.current!
    ctx.imageInterpolation = crisp ? .none : .high
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
}

func pixelText(_ s: String, px: CGFloat, color: NSColor = cream) -> NSImage {
    PixelFont.image(s, px: px, fill: color, shadow: forestDark, accent: orange)
}

/// Centered lines of pixel text, sliding up as they appear.
func caption(_ lines: [String], y: CGFloat, px: CGFloat, t: Double, start: Double, end: Double, color: NSColor = cream) {
    let inP = easeOut(progress(t, start, start + 0.45))
    let outP = progress(t, end - 0.3, end)
    let alpha = CGFloat(inP * (1 - outP))
    guard alpha > 0 else { return }
    var yy = y + CGFloat(1 - inP) * 40
    for line in lines {
        let img = pixelText(line, px: px, color: color)
        draw(img, NSRect(x: (W - img.size.width) / 2, y: yy, width: img.size.width, height: img.size.height), alpha: alpha, crisp: true)
        yy += img.size.height + px * 3
    }
}

// MARK: the cast

func session(_ id: String, _ project: String, _ state: CatState, _ configure: (inout Session) -> Void = { _ in }) -> Session {
    var s = Session(id: id, agent: .claude, at: Date(timeIntervalSince1970: 1_700_000_000 + Double(id.hashValue % 100)))
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

/// The cat's bottom-centre in room points (bottom-left origin), for the bubble's tail.
func catAnchor(_ id: String) -> CGPoint {
    guard let slot = currentLayout.slots.first(where: { $0.sessionId == id }) else { return .zero }
    let s = currentLayout.scale
    let treeX = room.bounds.width - currentLayout.width - 16
    let perch = Double(slot.highPerch ? TreeArt.highPost : TreeArt.lowPost)
    let x = treeX + slot.x + (1 + Double(SpriteBook.canvasW) / 2) * s
    let y = 40 + (3 + perch + 2) * s
    return CGPoint(x: x, y: y)
}

func bubbleImage(cat: String, speech: Speech, status: BubbleModel.Status = .idle, tailX: CGFloat) -> NSImage {
    let m = BubbleModel()
    m.cat = cat; m.speech = speech; m.reduceMotion = true; m.anim.popped = true; m.anim.shown = speech.text.count
    m.tailOnTop = true; m.tailX = tailX; m.showHint = false; m.status = status
    let host = NSHostingView(rootView: BubbleView(model: m))
    host.frame.size = NSSize(width: 300, height: host.fittingSize.height)
    return snapshot(host)
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

// MARK: speeches

let askDeploy = Speech(mood: .permission, headline: "Can I do this?", text: "I want to deploy the site.",
                       choices: [.init(label: "Allow", reply: .hook(allow: true), primary: true),
                                 .init(label: "Deny", reply: .hook(allow: false)),
                                 .init(label: "In terminal", reply: .handoff)],
                       textReply: .hookDeny, placeholder: "Or say what to do instead…", token: "1", detail: "Bash npm run deploy")
let askPR = Speech(mood: .question, headline: "Question for you", text: "Tests pass. Want me to open a PR?",
                   choices: [.init(label: "Yes", reply: .keys([]), primary: true), .init(label: "No", reply: .keys([]))],
                   textReply: .keys(prefix: []), placeholder: "Reply to keep going…", token: "2")

// MARK: render

let cursor = NSCursor.arrow.image
let dash = dashboardImage()
var roomImg = renderRoom()
var lastRoomTick = -1
var phase = 0   // which cast state the room currently shows

let frameCount = Int(DURATION * FPS)
for f in 0..<frameCount {
    let t = Double(f) / FPS
    // Story beats change the cats.
    let wanted = t < 6.4 ? 0 : t < 10.6 ? 1 : t < 11.8 ? 2 : t < 14.6 ? 3 : 4
    if wanted != phase {
        phase = wanted
        switch phase {
        case 1: cast[0].state = .permission; cast[0].stateSince = Date()
        case 2: cast[0].state = .working
        case 3: cast[2].state = .done; cast[2].lastMessage = "Tests pass. Want me to open a PR?"; cast[2].stateSince = Date()
        default: cast[2].state = .working
        }
        roomImg = renderRoom(); lastRoomTick = f
    } else if f - lastRoomTick >= 5 {   // cats animate at 6 fps, like the app
        roomImg = renderRoom(); lastRoomTick = f
    }

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(cgContext: NSGraphicsContext(bitmapImageRep: rep)!.cgContext, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    // Flip so y grows downward, like a video frame.
    let flip = NSAffineTransform(); flip.translateX(by: 0, yBy: H); flip.scaleX(by: 1, yBy: -1); flip.concat()

    // Background: forest green with a faint pixel grid and a floor.
    forest.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    forestDark.withAlphaComponent(0.35).setFill()
    for gx in stride(from: CGFloat(0), to: W, by: 40) { for gy in stride(from: CGFloat(0), to: H, by: 40) where (Int(gx + gy) / 40) % 2 == 0 {
        NSRect(x: gx + 18, y: gy + 18, width: 4, height: 4).fill() } }
    rgb(158, 110, 74).setFill(); NSRect(x: 0, y: H - 150, width: W, height: 150).fill()
    rgb(110, 74, 51).setFill(); NSRect(x: 0, y: H - 156, width: W, height: 6).fill()

    // Scene 1: the hook.
    if t < 2.7 {
        let pop = easeOutBack(progress(t, 0.1, 0.7))
        let head = pixelText("@", px: 40)
        let hs = CGFloat(pop)
        let hw = head.size.width * hs, hh = head.size.height * hs
        draw(head, NSRect(x: (W - hw) / 2, y: 520 - hh / 2, width: hw, height: hh), alpha: CGFloat(1 - progress(t, 2.3, 2.7)), crisp: true)
        caption(["YOUR AI AGENTS"], y: 780, px: 13, t: t, start: 0.5, end: 2.7)
        caption(["ARE NOW CATS"], y: 920, px: 13, t: t, start: 1.0, end: 2.7, color: orange)
    }

    // Scenes 2–4: the room under a fake menu bar, with bubbles.
    if t >= 2.4 && t < 15.6 {
        let S: CGFloat = 960 / roomImg.size.width
        let drop = easeOutBack(progress(t, 2.5, 3.2))
        let leave = easeInOut(progress(t, 15.1, 15.6))
        let rw = roomImg.size.width * S, rh = roomImg.size.height * S
        let rx = (W - rw) / 2
        let ry = 560 - (1 - CGFloat(drop)) * 200 - CGFloat(leave) * 1400
        let alpha = CGFloat(progress(t, 2.4, 2.7))
        // A strip of menu bar the room hangs from.
        rgb(20, 20, 22, alpha * 0.9).setFill(); NSRect(x: 0, y: ry - 70, width: W, height: 54).fill()
        let paw = pixelText("@", px: 4)
        draw(paw, NSRect(x: rx + rw - 120, y: ry - 58, width: paw.size.width, height: paw.size.height), alpha: alpha, crisp: true)
        draw(roomImg, NSRect(x: rx, y: ry, width: rw, height: rh), alpha: alpha, crisp: true)

        caption(["EVERY CLAUDE CODE", "SESSION GETS A CAT"], y: 230, px: 9, t: t, start: 2.7, end: 6.3)
        caption(["IT ASKS IN", "PLAIN ENGLISH"], y: 230, px: 9, t: t, start: 6.5, end: 11.4)
        caption(["ANSWER WITHOUT", "SWITCHING WINDOWS"], y: 230, px: 9, t: t, start: 11.6, end: 15.4)

        func showBubble(_ id: String, _ cat: String, _ speech: Speech, from: Double, until: Double, sentAt: Double,
                        click: (x: CGFloat, y: CGFloat)) {
            guard t >= from && t < until else { return }
            let a = catAnchor(id)
            let tail = a.x - (a.x - 150)   // bubble centred on the cat → tail in the middle
            let status: BubbleModel.Status = t >= sentAt ? .sent : .idle
            let img = bubbleImage(cat: cat, speech: speech, status: status, tailX: tail)
            let bw = img.size.width * S, bh = img.size.height * S
            let ax = rx + a.x * S, ay = ry + (roomImg.size.height - a.y) * S
            let bx = min(max(ax - bw / 2, 40), W - bw - 40)
            let by = ay - 8
            let pop = CGFloat(easeOutBack(progress(t, from, from + 0.35)))
            let fade = CGFloat(1 - progress(t, until - 0.25, until))
            NSGraphicsContext.saveGraphicsState()
            let tr = NSAffineTransform()
            tr.translateX(by: ax, yBy: by); tr.scale(by: max(0.01, pop)); tr.translateX(by: -ax, yBy: -by); tr.concat()
            draw(img, NSRect(x: bx, y: by, width: bw, height: bh), alpha: fade)
            NSGraphicsContext.restoreGraphicsState()
            // The cursor glides in and clicks.
            let target = CGPoint(x: bx + click.x * S, y: by + click.y * S)
            let move = easeInOut(progress(t, sentAt - 1.4, sentAt - 0.25))
            if t >= sentAt - 1.4 && t < until {
                let start = CGPoint(x: W - 120, y: H - 300)
                let cx = start.x + (target.x - start.x) * CGFloat(move), cy = start.y + (target.y - start.y) * CGFloat(move)
                let press = t >= sentAt - 0.15 && t < sentAt + 0.05 ? 0.85 : 1.0
                let cw = cursor.size.width * 3 * press, ch = cursor.size.height * 3 * press
                if t >= sentAt - 0.1 && t < sentAt + 0.5 {
                    let r = CGFloat(progress(t, sentAt - 0.1, sentAt + 0.5)) * 90
                    orange.withAlphaComponent(CGFloat(1 - progress(t, sentAt - 0.1, sentAt + 0.5)) * 0.8).setStroke()
                    let ring = NSBezierPath(ovalIn: NSRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2))
                    ring.lineWidth = 8; ring.stroke()
                }
                draw(cursor, NSRect(x: cx - 4, y: cy - 4, width: cw, height: ch), alpha: fade)
            }
        }
        showBubble("a", "Miso", askDeploy, from: 6.8, until: 10.7, sentAt: 9.4, click: (40, 112))
        showBubble("c", "Pepper", askPR, from: 12.1, until: 15.1, sentAt: 13.9, click: (32, 64))
    }

    // Scene 5: the dashboard's recent-work card.
    if t >= 15.3 && t < 19.8 {
        let rise = easeOut(progress(t, 15.3, 15.9))
        let leave = progress(t, 19.4, 19.8)
        // The detail pane only (right of the sidebar), from the top.
        let src = NSRect(x: 260, y: 760 - 535, width: 620, height: 535)   // bottom-left origin in points
        let scale: CGFloat = 1000 / src.width
        let dw = src.width * scale, dh = src.height * scale
        let dy = 560 + (1 - CGFloat(rise)) * 600
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: NSRect(x: (W - dw) / 2, y: dy, width: dw, height: dh), xRadius: 28, yRadius: 28)
        clip.addClip()
        dash.draw(in: NSRect(x: (W - dw) / 2, y: dy, width: dw, height: dh), from: src, operation: .sourceOver,
                  fraction: CGFloat(1 - leave), respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        caption(["SEE WHAT IT", "ACTUALLY GOT DONE"], y: 230, px: 9, t: t, start: 15.5, end: 19.8)
    }

    // Scene 6: end card.
    if t >= 19.6 {
        let pop = easeOutBack(progress(t, 19.7, 20.3))
        let logo = pixelText("@ AGENT CATS", px: 13)
        let lw = logo.size.width * CGFloat(pop), lh = logo.size.height * CGFloat(pop)
        draw(logo, NSRect(x: (W - lw) / 2, y: 700 - lh / 2, width: lw, height: lh), crisp: true)
        caption(["FOR CLAUDE CODE", "AND CODEX ON MAC"], y: 860, px: 7, t: t, start: 20.2, end: 30)
        caption(["LINK IN BIO"], y: 1180, px: 8, t: t, start: 20.8, end: 30, color: orange)
    }

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outDir.appendingPathComponent(String(format: "f%04d.png", f)))
    if f % 60 == 0 { print("frame \(f)/\(frameCount)") }
}
print("rendered \(frameCount) frames to \(outDir.path)")
