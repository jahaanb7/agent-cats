import AppKit

/// A small pull cord stays on screen while the room is tucked away.
/// Click or tug it to toggle the room; double-click it to make Agent Cats vanish completely
/// until a cat needs you (or you click the paw in the menu bar).
final class PullCordView: NSView {
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

/// Code-drawn room backdrop; the existing pixel cats remain crisp above it.
final class RoomBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        NSColor(srgbRed: 0.91, green: 0.86, blue: 0.74, alpha: 1).setFill(); bounds.fill()
        NSColor(srgbRed: 0.84, green: 0.79, blue: 0.67, alpha: 0.45).setFill()
        for x in stride(from: CGFloat(8), to: bounds.width, by: 16) {
            NSRect(x: x, y: 34, width: 1, height: bounds.height - 75).fill()
        }
        NSColor(srgbRed: 0.22, green: 0.32, blue: 0.28, alpha: 1).setFill()
        NSRect(x: 0, y: bounds.height - 45, width: bounds.width, height: 45).fill()
        // Wood floor and skirting board.
        NSColor(srgbRed: 0.62, green: 0.43, blue: 0.29, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 39).fill()
        NSColor(srgbRed: 0.43, green: 0.29, blue: 0.20, alpha: 1).setFill()
        NSRect(x: 0, y: 36, width: bounds.width, height: 3).fill()
        for x in stride(from: CGFloat(0), to: bounds.width, by: 36) {
            NSRect(x: x, y: 0, width: 1, height: 35).fill()
        }
        // A little evening window behind the perches.
        let window = NSRect(x: 24, y: 62, width: 58, height: 51)
        NSColor(srgbRed: 0.43, green: 0.30, blue: 0.22, alpha: 1).setFill(); window.insetBy(dx: -4, dy: -4).fill()
        NSColor(srgbRed: 0.30, green: 0.46, blue: 0.49, alpha: 1).setFill(); window.fill()
        NSColor(srgbRed: 0.99, green: 0.90, blue: 0.61, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 60, y: 93, width: 10, height: 10)).fill()
        NSColor(srgbRed: 0.82, green: 0.69, blue: 0.48, alpha: 1).setFill()
        NSRect(x: 51, y: 62, width: 3, height: 51).fill()
        NSRect(x: 24, y: 85, width: 58, height: 3).fill()
        NSRect(x: 17, y: 56, width: 72, height: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(srgbRed: 0.29, green: 0.31, blue: 0.24, alpha: 1).setStroke(); card.lineWidth = 2; card.stroke()
    }
}

final class CatRoomView: NSView {
    let tree: CatTreeView
    let rope = PullCordView(frame: .zero)
    private let backdrop = RoomBackdrop()
    private let title = NSTextField(labelWithString: "AGENT CATS")
    private let subtitle = NSTextField(labelWithString: "")
    private let review = NSButton(title: "Dashboard ↗", target: nil, action: nil)
    private let tuck = NSButton(title: "×", target: nil, action: nil)
    var onDashboard: (() -> Void)?
    var onHide: (() -> Void)?
    private var treeSize = NSSize.zero
    private var expanded = false

    init(tree: CatTreeView) {
        self.tree = tree
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.wantsLayer = true
        addSubview(backdrop)
        backdrop.addSubview(tree)
        title.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        title.textColor = NSColor(srgbRed: 0.96, green: 0.91, blue: 0.79, alpha: 1)
        backdrop.addSubview(title)
        subtitle.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.textColor = NSColor(srgbRed: 0.96, green: 0.91, blue: 0.79, alpha: 1)
        subtitle.lineBreakMode = .byTruncatingTail
        backdrop.addSubview(subtitle)
        review.bezelStyle = .rounded; review.controlSize = .small
        review.target = self; review.action = #selector(openDashboard)
        backdrop.addSubview(review)
        tuck.bezelStyle = .inline; tuck.font = .systemFont(ofSize: 20)
        tuck.contentTintColor = title.textColor
        tuck.attributedTitle = NSAttributedString(string: "×", attributes: [
            .foregroundColor: title.textColor!, .font: NSFont.systemFont(ofSize: 20)
        ])
        tuck.target = self; tuck.action = #selector(hideRoom)
        tuck.toolTip = "Tuck away until the next notification"
        tuck.setAccessibilityLabel("Hide Agent Cats room")
        backdrop.addSubview(tuck)
        addSubview(rope)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(expanded: Bool, treeSize: NSSize, count: Int, attention: Int) -> NSSize {
        self.expanded = expanded; self.treeSize = treeSize
        backdrop.isHidden = !expanded
        rope.expanded = expanded; rope.attention = attention > 0
        subtitle.stringValue = attention > 0 ? "\(attention) need you · click a cat to answer" : count == 0 ? "No active sessions · your cats are resting" : "\(count) sessions · click a cat to chat"
        review.title = attention > 0 ? "Review ↗" : "Dashboard ↗"
        let size = expanded ? NSSize(width: max(330, treeSize.width + 36), height: max(206, treeSize.height + 128)) : NSSize(width: 36, height: 55)
        setFrameSize(size)
        needsLayout = true
        return size
    }

    override func layout() {
        super.layout()
        rope.frame = NSRect(x: bounds.width - 36, y: 0, width: 36, height: expanded ? 42 : bounds.height)
        backdrop.frame = NSRect(x: 0, y: 42, width: bounds.width, height: max(0, bounds.height - 42))
        let h = backdrop.bounds.height
        title.frame = NSRect(x: 16, y: h - 23, width: 150, height: 16)
        subtitle.frame = NSRect(x: 16, y: h - 40, width: bounds.width - 44, height: 15)
        tuck.frame = NSRect(x: bounds.width - 31, y: h - 27, width: 22, height: 22)
        tree.frame = NSRect(x: bounds.width - treeSize.width - 16, y: 40, width: treeSize.width, height: treeSize.height)
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
    @objc private func hideRoom() { onHide?() }
}
