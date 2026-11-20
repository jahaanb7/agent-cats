import AppKit

/// A small pull cord stays on screen while the room is tucked away.
/// Click or tug it to toggle the room; double-click it to make Agent Cats vanish completely
/// until a cat needs you (or you click the paw in the menu bar).
final class PullCordView: NSView {
    // The panel never becomes key, so without this the first click on an inactive panel can be eaten.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var onPull: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var reduceMotion = false
    var expanded = false {
        didSet {
            needsDisplay = true
            toolTip = expanded ? "Tug to tuck the cats away · double-click to hide completely"
                               : "Tug to reveal Agent Cats · double-click to hide completely"
        }
    }
    var attention = false {
        didSet { if attention && !oldValue { swing(by: 0.22) }; needsDisplay = true }
    }

    private var startY: CGFloat = 0
    // Spring state: how far the cord is pulled down, and how far it leans (radians).
    private var stretch: CGFloat = 0, stretchV: CGFloat = 0
    private var angle: CGFloat = 0, angleV: CGFloat = 0
    private var holding = false
    private var ticker: Timer?
    private var pendingPull: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Toggle Agent Cats room")
        toolTip = "Tug to reveal Agent Cats · double-click to hide completely"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityPerformPress() -> Bool { onPull?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        startY = event.locationInWindow.y
        holding = true
        stretch = 3; stretchV = 0
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        stretch = min(16, max(0, startY - event.locationInWindow.y)); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        holding = false
        let tugged = stretch >= 6
        // Let go: the cord springs back and swings a little.
        stretchV = 0
        swing(by: tugged ? 0.16 : 0.08)
        if event.clickCount >= 2 {
            pendingPull?.cancel(); pendingPull = nil
            onDoubleClick?()
            return
        }
        if tugged {
            // A real tug is never the first half of a double-click.
            onPull?()
            return
        }
        // A plain click waits a moment in case a second click is on its way. The room moves
        // under the cursor when it opens, so the second click would otherwise land elsewhere.
        pendingPull?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pendingPull = nil; self?.onPull?() }
        pendingPull = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(NSEvent.doubleClickInterval, 0.3), execute: work)
    }

    /// Give the cord a nudge; it sways and settles on its own.
    func swing(by kick: CGFloat) {
        guard !reduceMotion else { return }
        angleV += (angle >= 0 ? -1 : 1) * kick * 9
        startTicker()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    /// Damped springs, integrated at 60 fps, only while something is moving.
    private func step() {
        let dt: CGFloat = 1 / 60
        angleV += (-90 * angle - 5 * angleV) * dt
        angle = max(-0.22, min(0.22, angle + angleV * dt))
        if !holding {
            stretchV += (-260 * stretch - 18 * stretchV) * dt
            stretch += stretchV * dt
        }
        needsDisplay = true
        if !holding, abs(angle) < 0.002, abs(angleV) < 0.01, abs(stretch) < 0.1, abs(stretchV) < 0.1 {
            angle = 0; angleV = 0; stretch = 0; stretchV = 0
            ticker?.invalidate(); ticker = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let top = NSPoint(x: bounds.midX, y: bounds.maxY)
        let length = min(bounds.maxY - 11, max(12, bounds.maxY - 23 + stretch))
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: top.x, yBy: top.y)
        t.rotate(byRadians: angle)
        t.concat()
        // Everything below is drawn hanging from (0, 0), pointing down.
        let end = -length
        let cord = NSBezierPath()
        cord.move(to: .zero)
        cord.line(to: NSPoint(x: 0, y: end))
        cord.lineWidth = 3
        cord.lineCapStyle = .round
        NSColor(srgbRed: 0.67, green: 0.50, blue: 0.31, alpha: 1).setStroke(); cord.stroke()
        NSColor(srgbRed: 0.93, green: 0.82, blue: 0.60, alpha: 1).setFill()
        for y in stride(from: end + 3, to: 0, by: 5) {
            NSRect(x: -1.5, y: y, width: 3, height: 2).fill()
        }
        let knobRect = NSRect(x: -8, y: end - 10, width: 16, height: 17)
        if attention {
            NSColor.systemOrange.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: knobRect.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8).fill()
        }
        let knob = NSBezierPath(roundedRect: knobRect, xRadius: 5, yRadius: 5)
        (attention ? NSColor.systemOrange : NSColor(srgbRed: 0.47, green: 0.62, blue: 0.52, alpha: 1)).setFill(); knob.fill()
        NSColor(srgbRed: 0.18, green: 0.27, blue: 0.23, alpha: 1).setStroke(); knob.lineWidth = 1.5; knob.stroke()
        NSColor(srgbRed: 0.95, green: 0.89, blue: 0.73, alpha: 1).setFill()
        NSRect(x: -3, y: end - 3, width: 6, height: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Code-drawn room backdrop: wall, window, bunting, shelf, rug and toys, all in chunky pixels.
/// The pixel cats stay crisp above it.
final class RoomBackdrop: NSView {
    static let headerH: CGFloat = 50, floorH: CGFloat = 39
    /// Left edge of the cat tree, so wall decorations stay clear of the cats.
    var treeMinX: CGFloat = .greatestFiniteMagnitude { didSet { if oldValue != treeMinX { needsDisplay = true } } }

    private func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
    /// One art pixel = 2pt.
    private func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 1, _ h: CGFloat = 1, _ color: NSColor) {
        color.setFill(); NSRect(x: x * 2, y: y * 2, width: w * 2, height: h * 2).fill()
    }
    /// Draws rows of a sprite (top row first) whose bottom-left sits at art pixel (x, y).
    private func sprite(_ x: CGFloat, _ y: CGFloat, _ rows: [String], _ palette: [Character: NSColor]) {
        for (r, line) in rows.enumerated() {
            for (i, ch) in line.enumerated() { if let col = palette[ch] { px(x + CGFloat(i), y + CGFloat(rows.count - 1 - r), 1, 1, col) } }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        let W = bounds.width, H = bounds.height
        let wallTop = H - Self.headerH
        // Wall with soft stripes and a wainscot.
        c(232, 219, 189).setFill(); bounds.fill()
        c(214, 201, 171, 0.45).setFill()
        for x in stride(from: CGFloat(8), to: W, by: 16) { NSRect(x: x, y: Self.floorH, width: 1, height: wallTop - Self.floorH).fill() }
        c(205, 184, 148).setFill(); NSRect(x: 0, y: Self.floorH, width: W, height: 14).fill()
        c(186, 163, 126).setFill(); NSRect(x: 0, y: Self.floorH + 14, width: W, height: 2).fill()
        // Header band.
        c(56, 82, 71).setFill(); NSRect(x: 0, y: wallTop, width: W, height: Self.headerH).fill()
        c(41, 61, 53).setFill(); NSRect(x: 0, y: wallTop, width: W, height: 3).fill()
        // Wood floor and skirting board.
        c(158, 110, 74).setFill(); NSRect(x: 0, y: 0, width: W, height: Self.floorH).fill()
        c(140, 96, 64).setFill()
        for (i, y) in stride(from: CGFloat(7), to: Self.floorH - 4, by: 9).enumerated() {
            NSRect(x: 0, y: y, width: W, height: 1).fill()
            for x in stride(from: CGFloat(i % 2 == 0 ? 0 : 18), to: W, by: 36) { NSRect(x: x, y: y - 8, width: 1, height: 8).fill() }
        }
        c(110, 74, 51).setFill(); NSRect(x: 0, y: 36, width: W, height: 3).fill()

        let room = min(W, treeMinX) / 2   // free width on the left, in art pixels
        let top = wallTop / 2

        // Bunting along the top of the wall.
        let flags = [c(224, 122, 72), c(232, 196, 92), c(120, 160, 134), c(122, 152, 186)]
        c(110, 74, 51).setFill(); NSRect(x: 0, y: wallTop - 6, width: W, height: 1).fill()
        var fi = 0
        for x in stride(from: CGFloat(4), to: W / 2 - 4, by: 9) {
            let col = flags[fi % flags.count]; fi += 1
            for r in 0..<4 { px(x + CGFloat(r) / 2, top - 4 - CGFloat(r), 5 - CGFloat(r), 1, col) }
        }

        // Evening window with a moon and stars.
        if room > 52 {
            let wx: CGFloat = 10, wy = max(30, top - 44), ww: CGFloat = 30, wh: CGFloat = 26
            px(wx - 2, wy - 2, ww + 4, wh + 4, c(110, 76, 56))
            px(wx, wy, ww, wh, c(62, 92, 112))
            px(wx, wy, ww, wh / 2, c(77, 117, 125))
            for (sx, sy) in [(4, 20), (12, 23), (24, 21), (7, 15)] { px(wx + CGFloat(sx), wy + CGFloat(sy), 1, 1, c(252, 236, 180)) }
            px(wx + 19, wy + 15, 5, 5, c(253, 229, 156)); px(wx + 22, wy + 17, 2, 3, c(62, 92, 112))
            px(wx + ww / 2 - 1, wy, 2, wh, c(208, 176, 122)); px(wx, wy + wh / 2 - 1, ww, 2, c(208, 176, 122))
            px(wx - 4, wy - 3, ww + 8, 2, c(208, 176, 122))
            // Little plant on the sill.
            sprite(wx + 2, wy - 1, [".#.#.", "#####", ".###.", ".ooo.", ".ooo."], ["#": c(103, 150, 98), "o": c(196, 104, 70)])
        }

        // Shelf with a pot and a stack of books.
        if room > 96 {
            let sx: CGFloat = 50, sy = max(32, top - 32)
            px(sx, sy, 34, 2, c(126, 88, 60)); px(sx + 2, sy - 3, 2, 3, c(110, 76, 56)); px(sx + 30, sy - 3, 2, 3, c(110, 76, 56))
            for (i, col) in [c(178, 92, 72), c(92, 124, 150), c(222, 186, 96)].enumerated() {
                px(sx + 3 + CGFloat(i) * 3, sy + 2, 3, 10 - CGFloat(i), col)
            }
            sprite(sx + 18, sy + 2, ["..##..", ".#..#.", "######", "#oooo#", "#oooo#", ".####."],
                   ["#": c(120, 160, 134), "o": c(232, 196, 92)])
            // A framed paw print above it.
            let fx = sx + 6, fy = sy + 16
            if fy + 14 < top - 6 {
                px(fx, fy, 14, 12, c(110, 76, 56)); px(fx + 1, fy + 1, 12, 10, c(246, 236, 210))
                sprite(fx + 3, fy + 2, [".#.#.#.", ".......", "..###..", ".#####.", ".#####."], ["#": c(224, 122, 72)])
            }
        }

        // Rug on the floor under the toys.
        // The rug takes the floor left of the Dashboard button.
        let rugW = max(36, min((W - 126) / 2 - 4, 150))
        px(4, 2, rugW, 9, c(196, 104, 70))
        px(5, 3, rugW - 2, 7, c(226, 170, 104))
        for x in stride(from: CGFloat(7), to: rugW, by: 6) { px(x, 6, 3, 1, c(196, 104, 70)) }
        for x in stride(from: CGFloat(5), to: rugW + 3, by: 3) { px(x, 1, 1, 1, c(226, 170, 104)) }

        // Yarn ball with a loose strand.
        let yarn: [Character: NSColor] = ["#": c(214, 96, 110), "+": c(240, 150, 158), "-": c(170, 66, 84)]
        sprite(8, 8, [".###.", "#+#-#", "#-+#+", "+#-#-", ".#+#."], yarn)
        for (i, dy) in [0, 1, 1, 2, 2, 1, 1, 0, 0, 1].enumerated() { px(13 + CGFloat(i), 8 + CGFloat(dy) * 0.5, 1, 0.5, c(214, 96, 110)) }
        // Toy mouse with a tail.
        sprite(26, 8, ["..##...", ".#####.", "#######", ".o..o.."], ["#": c(150, 150, 160), "o": c(90, 90, 100)])
        px(24, 9, 2, 0.5, c(214, 96, 110)); px(33, 11, 1, 1, c(240, 150, 158))
        // Fish toy and a bell ball, if there's room.
        if rugW > 60 {
            sprite(40, 8, ["..#..#", ".####.", "#o####", ".####.", "..#..#"], ["#": c(122, 152, 186), "o": c(40, 48, 60)])
            sprite(52, 8, [".##.", "#..#", "#..#", ".##."], ["#": c(232, 196, 92)])
            px(53, 9, 2, 2, c(250, 226, 150))
        }
        if rugW > 80 {
            // Feather wand lying on the rug.
            for i in 0..<12 { px(62 + CGFloat(i), 8 + CGFloat(i) / 4, 1, 0.5, c(126, 88, 60)) }
            sprite(73, 9, ["##.", "###", ".##"], ["#": c(120, 160, 134)])
        }
        NSGraphicsContext.restoreGraphicsState()
        c(74, 79, 61).setStroke(); card.lineWidth = 2; card.stroke()
    }
}

final class CatRoomView: NSView {
    // The panel never becomes key, so without this the first click on an inactive panel can be eaten.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    let tree: CatTreeView
    let rope = PullCordView(frame: .zero)
    private let backdrop = RoomBackdrop()
    private let title = NSImageView()
    private let subtitle = NSTextField(labelWithString: "")
    private let review = NSButton(title: "Dashboard ↗", target: nil, action: nil)
    private let tuck = NSButton(title: "×", target: nil, action: nil)
    var onDashboard: (() -> Void)?
    var onHide: (() -> Void)?
    var onHideCompletely: (() -> Void)?
    private var pendingHide: DispatchWorkItem?
    private var treeSize = NSSize.zero
    private var expanded = false

    init(tree: CatTreeView) {
        self.tree = tree
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.wantsLayer = true
        addSubview(backdrop)
        backdrop.addSubview(tree)
        let cream = NSColor(srgbRed: 0.96, green: 0.91, blue: 0.79, alpha: 1)
        title.image = PixelFont.image("@ AGENT CATS", px: 2, fill: cream,
                                      shadow: NSColor(srgbRed: 0.14, green: 0.22, blue: 0.19, alpha: 1),
                                      accent: NSColor(srgbRed: 0.92, green: 0.55, blue: 0.33, alpha: 1))
        title.imageScaling = .scaleNone
        title.setAccessibilityLabel("Agent Cats")
        backdrop.addSubview(title)
        subtitle.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        subtitle.textColor = cream.withAlphaComponent(0.7)
        subtitle.lineBreakMode = .byTruncatingTail
        backdrop.addSubview(subtitle)
        review.bezelStyle = .rounded; review.controlSize = .small
        review.target = self; review.action = #selector(openDashboard)
        backdrop.addSubview(review)
        tuck.bezelStyle = .inline; tuck.font = .systemFont(ofSize: 20)
        tuck.contentTintColor = cream
        tuck.attributedTitle = NSAttributedString(string: "×", attributes: [
            .foregroundColor: cream, .font: NSFont.systemFont(ofSize: 20)
        ])
        tuck.target = self; tuck.action = #selector(hideRoom)
        tuck.toolTip = "Tuck away · double-click to hide completely"
        tuck.setAccessibilityLabel("Hide Agent Cats room")
        backdrop.addSubview(tuck)
        addSubview(rope)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(expanded: Bool, treeSize: NSSize, count: Int, attention: Int) -> NSSize {
        self.expanded = expanded; self.treeSize = treeSize
        backdrop.isHidden = !expanded
        rope.expanded = expanded; rope.attention = attention > 0
        subtitle.stringValue = count == 0 ? "YOUR CATS ARE RESTING" : "\(count) SESSION\(count == 1 ? "" : "S")"
        review.title = attention > 0 ? "Review ↗" : "Dashboard ↗"
        // The room hugs its cats: room on the left for the toys, the tree on the right.
        let size = expanded ? NSSize(width: max(264, treeSize.width + 120), height: max(190, treeSize.height + 134)) : NSSize(width: 36, height: 55)
        setFrameSize(size)
        needsLayout = true
        return size
    }

    override func layout() {
        super.layout()
        rope.frame = NSRect(x: bounds.width - 36, y: 0, width: 36, height: expanded ? 42 : bounds.height)
        backdrop.frame = NSRect(x: 0, y: 42, width: bounds.width, height: max(0, bounds.height - 42))
        let h = backdrop.bounds.height
        let titleSize = title.image?.size ?? .zero
        title.frame = NSRect(x: 14, y: h - 10 - titleSize.height, width: titleSize.width, height: titleSize.height)
        subtitle.frame = NSRect(x: 15, y: h - 44, width: bounds.width - 44, height: 14)
        tuck.frame = NSRect(x: bounds.width - 31, y: h - 29, width: 22, height: 22)
        tree.frame = NSRect(x: bounds.width - treeSize.width - 16, y: 40, width: treeSize.width, height: treeSize.height)
        backdrop.treeMinX = tree.frame.minX - 8
        review.frame = NSRect(x: bounds.width - 116, y: 9, width: 102, height: 23)
    }
    // MARK: motion

    /// The room drops down from the menu bar like a blind, with a soft spring at the bottom.
    func animateIn() {
        guard let l = backdrop.layer else { return }
        l.removeAllAnimations()
        let drop = CASpringAnimation(keyPath: "transform.translation.y")
        drop.fromValue = 26; drop.toValue = 0
        drop.mass = 1; drop.stiffness = 260; drop.damping = 22; drop.initialVelocity = 0
        drop.duration = drop.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(drop, forKey: "drop"); l.add(fade, forKey: "fade")
        tree.popInCats()
    }

    /// Slides the room back up under the menu bar, then calls `done`.
    func animateOut(_ done: @escaping () -> Void) {
        guard let l = backdrop.layer, !backdrop.isHidden else { done(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeAllAnimations(); done() }
        let lift = CABasicAnimation(keyPath: "transform.translation.y")
        lift.fromValue = 0; lift.toValue = 22
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        for a in [lift, fade] {
            a.duration = 0.2
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            a.fillMode = .forwards; a.isRemovedOnCompletion = false
            l.add(a, forKey: a.keyPath)
        }
        CATransaction.commit()
    }

    @objc private func openDashboard() { onDashboard?() }
    /// × tucks the room away; a double-click on it hides Agent Cats completely. The single-click
    /// action waits a moment, since the × is gone from under the cursor once the room tucks away.
    @objc private func hideRoom() {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            pendingHide?.cancel(); pendingHide = nil
            onHideCompletely?()
            return
        }
        guard NSApp.currentEvent?.type == .leftMouseUp else { onHide?(); return }   // keyboard / accessibility
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pendingHide = nil; self?.onHide?() }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(NSEvent.doubleClickInterval, 0.3), execute: work)
    }
}
