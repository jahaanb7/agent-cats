import AppKit
import SwiftUI

// Renders the speech bubble in its main moods to dist/bubble-preview.png.
func session(_ state: CatState, _ configure: (inout Session) -> Void = { _ in }) -> Session {
    var s = Session(id: "S\(state)", agent: .claude, at: Date())
    s.state = state; s.tty = "ttys001"
    configure(&s)
    return s
}
let cases: [(String, Speech)] = [
    ("Mochi", Speech.make(session(.question) { $0.question = AgentQuestion(text: "Which database should we use for the sessions table?", options: ["Postgres", "SQLite", "Keep JSON files"]) }, hookPending: false)),
    ("Biscuit", Speech.make(session(.permission) { $0.activity = "Bash rm -rf build && make" }, hookPending: true)),
    ("Pepper", Speech.make(session(.done) { $0.lastMessage = "All 113 checks pass and the bubble builds. Want me to open a PR?" }, hookPending: false)),
    ("Tofu", Speech.make(session(.error) { $0.activity = "usage limit reached" }, hookPending: false)),
]
var images: [NSImage] = []
for (i, (cat, sp)) in cases.enumerated() {
    let m = BubbleModel()
    m.cat = cat; m.speech = sp; m.reduceMotion = true; m.anim.popped = true; m.anim.shown = sp.text.count
    m.tailOnTop = i % 2 == 0; m.tailX = 90
    if i == 1 { m.status = .failed("I can only type into Terminal or iTerm. Double-click me to answer in Cursor.") }
    if i == 2 { m.status = .sent }
    if i == 0 { m.waiting = 2 }
    let host = NSHostingView(rootView: BubbleView(model: m))
    host.frame.size = NSSize(width: 300, height: host.fittingSize.height)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
    host.cacheDisplay(in: host.bounds, to: rep)
    let img = NSImage(size: host.bounds.size); img.addRepresentation(rep); images.append(img)
}
let W: CGFloat = 640, gap: CGFloat = 16
let colH = [images.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.size.height).reduce(0) { $0 + $1 + gap },
            images.enumerated().filter { $0.offset % 2 == 1 }.map(\.element.size.height).reduce(0) { $0 + $1 + gap }]
let H = (colH.max() ?? 0) + gap
let out = NSImage(size: NSSize(width: W, height: H))
out.lockFocus()
NSColor(srgbRed: 0.91, green: 0.86, blue: 0.74, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
var y: [CGFloat] = [H - gap, H - gap]
for (i, img) in images.enumerated() {
    let c = i % 2
    y[c] -= img.size.height
    img.draw(in: NSRect(x: gap + CGFloat(c) * (300 + gap), y: y[c], width: 300, height: img.size.height))
    y[c] -= gap
}
out.unlockFocus()
let png = NSBitmapImageRep(data: out.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "dist/bubble-preview.png"))
print("Rendered dist/bubble-preview.png")
