import AppKit

let app = NSApplication.shared
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard let book = SpriteBook(url: root.appendingPathComponent("Art/cats.json")) else { fatalError("Missing sprite book") }
let tree = CatTreeView(book: book)
let previewCount = Int(ProcessInfo.processInfo.environment["CATS"] ?? "") ?? 4
var sessions = (0..<previewCount).map { i -> Session in
    var s = Session(id: "preview-\(i)", agent: i == 3 ? .codex : .claude, at: Date())
    s.cwd = "/Preview/Project \(i + 1)"
    s.state = [.working, .thinking, .permission, .idle][i]
    return s
}
let layout = TreeLayout.compute(ordered: sessions, maxWidth: 480)
let size = tree.update(entries: zip(sessions, ["Mochi", "Pepper", "Biscuit", "Sumi"]).map { .init(session: $0.0, cat: $0.1) }, layout: layout)
let room = CatRoomView(tree: tree)
var pulls = 0
room.rope.onPull = { pulls += 1 }
_ = room.rope.accessibilityPerformPress()
assert(pulls == 1, "Accessible rope activates")
let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 18, y: 30), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 18, y: 15), modifierFlags: [], timestamp: 0.1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 18, y: 15), modifierFlags: [], timestamp: 0.2, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
room.rope.mouseDown(with: down); room.rope.mouseDragged(with: drag); room.rope.mouseUp(with: up)
assert(pulls == 2, "Tug fires once on release")
var vanished = 0
room.rope.onDoubleClick = { vanished += 1 }
func click(_ n: Int) -> (NSEvent, NSEvent) {
    (NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 18, y: 30), modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 10 + n, clickCount: n, pressure: 1)!,
     NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 18, y: 30), modifierFlags: [], timestamp: 1.05, windowNumber: 0, context: nil, eventNumber: 20 + n, clickCount: n, pressure: 0)!)
}
for n in 1...2 { let (d, u) = click(n); room.rope.mouseDown(with: d); room.rope.mouseUp(with: u) }
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
assert(vanished == 1 && pulls == 2, "Double-clicking the rope hides everything without also toggling the room")
let (d1, u1) = click(1); room.rope.mouseDown(with: d1); room.rope.mouseUp(with: u1)
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
assert(pulls == 3, "A single click still toggles the room")
let collapsed = room.update(expanded: false, treeSize: size, count: sessions.count, attention: 0)
room.layoutSubtreeIfNeeded()
assert(collapsed == NSSize(width: 36, height: 55), "Collapsed window occupies only the cord")
assert(tree.isHiddenOrHasHiddenAncestor, "Hidden room cannot display cats")
let expanded = room.update(expanded: true, treeSize: size, count: sessions.count, attention: 1)
room.layoutSubtreeIfNeeded()
assert(expanded.width >= 264 && !tree.isHiddenOrHasHiddenAncestor, "Pull reveals the room")
assert(tree.frame.minY >= 0 && tree.frame.maxY < tree.superview!.bounds.height - RoomBackdrop.headerH, "Cats stay below header")
let window = NSWindow(contentRect: NSRect(origin: .zero, size: expanded), styleMask: .borderless, backing: .buffered, defer: false)
window.contentView = room
room.layoutSubtreeIfNeeded()
var clickedSession: String?
tree.onCatClick = { clickedSession = $0.id }
let slot = layout.slots[0]
let catPoint = NSPoint(x: slot.x + 14 * layout.scale,
                      y: (3 + (slot.highPerch ? TreeArt.highPost : TreeArt.lowPost) + 10) * layout.scale)
let windowPoint = tree.convert(catPoint, to: nil)
let catClick = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
tree.mouseDown(with: catClick)
assert(clickedSession == sessions[0].id, "Clicking a cat selects its actual session")
func buttons(_ view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
}
var openedDashboard = false, hidRoom = false
room.onDashboard = { openedDashboard = true }
room.onHide = { hidRoom = true }
for button in buttons(room) {
    if let action = button.action { _ = app.sendAction(action, to: button.target, from: button) }
}
assert(openedDashboard && hidRoom, "Review and tuck controls reach their actions")
if let bitmap = room.bitmapImageRepForCachingDisplay(in: room.bounds) {
    room.cacheDisplay(in: room.bounds, to: bitmap)
    if let data = bitmap.representation(using: .png, properties: [:]) {
        try data.write(to: root.appendingPathComponent("dist/room-preview.png"))
        print("Rendered dist/room-preview.png")
    }
}
_ = room.update(expanded: false, treeSize: size, count: sessions.count, attention: 0)
window.setContentSize(NSSize(width: 36, height: 55))
room.layoutSubtreeIfNeeded()
assert(room.hitTest(NSPoint(x: 18, y: 20)) === room.rope, "Visible cord receives clicks while collapsed")
if let bitmap = room.bitmapImageRepForCachingDisplay(in: room.bounds) {
    room.cacheDisplay(in: room.bounds, to: bitmap)
    if let data = bitmap.representation(using: .png, properties: [:]) {
        try data.write(to: root.appendingPathComponent("dist/rope-preview.png"))
    }
}
print("Room checks passed: accessibility, tug, hidden footprint, reveal, and layout")
