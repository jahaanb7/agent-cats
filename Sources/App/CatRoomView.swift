import AppKit

/// A small pull cord stays on screen while the room is tucked away.
final class PullCordView: NSView {
    var onPull: (() -> Void)?
    var expanded = false { didSet { needsDisplay = true; toolTip = expanded ? "Tug to tuck the cats away" : "Tug to reveal Agent Cats" } }
    var attention = false { didSet { needsDisplay = true } }
    private var startY: CGFloat = 0
    private var stretch: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Toggle Agent Cats room")
        toolTip = "Click or tug to reveal Agent Cats"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityPerformPress() -> Bool { onPull?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { startY = event.locationInWindow.y; stretch = 3; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        stretch = min(14, max(0, startY - event.locationInWindow.y)); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { stretch = 0; needsDisplay = true; onPull?() }
    override func draw(_ dirtyRect: NSRect) {
        let x = bounds.midX
        let end = max(10, 23 - stretch)
        let cord = NSBezierPath()
        cord.move(to: NSPoint(x: x, y: bounds.maxY))
        cord.line(to: NSPoint(x: x, y: end))
        cord.lineWidth = 3
        NSColor(srgbRed: 0.67, green: 0.50, blue: 0.31, alpha: 1).setStroke(); cord.stroke()
        for y in stride(from: end + 3, to: bounds.maxY, by: 5) {
            NSColor(srgbRed: 0.93, green: 0.82, blue: 0.60, alpha: 1).setFill()
            NSRect(x: x - 1.5, y: y, width: 3, height: 2).fill()
        }
        let knob = NSBezierPath(roundedRect: NSRect(x: x - 8, y: end - 10, width: 16, height: 17), xRadius: 5, yRadius: 5)
        (attention ? NSColor.systemOrange : NSColor(srgbRed: 0.47, green: 0.62, blue: 0.52, alpha: 1)).setFill(); knob.fill()
        NSColor(srgbRed: 0.18, green: 0.27, blue: 0.23, alpha: 1).setStroke(); knob.lineWidth = 1.5; knob.stroke()
        NSColor(srgbRed: 0.95, green: 0.89, blue: 0.73, alpha: 1).setFill()
        NSRect(x: x - 3, y: end - 3, width: 6, height: 2).fill()
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
    @objc private func openDashboard() { onDashboard?() }
    @objc private func hideRoom() { onHide?() }
}
