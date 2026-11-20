import AppKit
import QuartzCore

/// The cat tree: one pixel-art tree image plus a layer per visible cat.
/// Everything is drawn in art pixels and scaled with nearest-neighbour filtering.
final class CatTreeView: NSView {
    // The panel never becomes key, so without this the first click on an inactive panel can be eaten.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    struct Entry { let session: Session; let cat: String }

    var onTreeClick: (() -> Void)?
    private var tips: [Tip] = []
    var onCatClick: ((Session) -> Void)?
    var onCatDoubleClick: ((Session) -> Void)?
    var onCatRightClick: ((Session, NSEvent) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var reduceMotion = false

    private let book: SpriteBook
    private let treeLayer = CALayer()
    private var catLayers: [String: CALayer] = [:]
    private let basketLabel = CATextLayer()
    private(set) var layout = TreeLayout.compute(ordered: [], maxWidth: 600)
    private var entries: [String: Entry] = [:]
    private var frameNo = 0

    init(book: SpriteBook) {
        self.book = book
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
        treeLayer.magnificationFilter = .nearest
        layer?.addSublayer(treeLayer)
        basketLabel.fontSize = 9
        basketLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .heavy)
        basketLabel.foregroundColor = NSColor(srgbRed: 1, green: 0.96, blue: 0.89, alpha: 1).cgColor
        basketLabel.alignmentMode = .center
        basketLabel.isHidden = true
        layer?.addSublayer(basketLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// Applies a new snapshot. Returns the size the window should take.
    func update(entries list: [Entry], layout: TreeLayout) -> NSSize {
        let scaleChanged = layout.scale != self.layout.scale
        self.layout = layout
        entries = Dictionary(uniqueKeysWithValues: list.map { ($0.session.id, $0) })
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let s = window?.backingScaleFactor ?? 2
        treeLayer.contentsScale = s
        treeLayer.frame = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        treeLayer.contents = TreeArt.image(for: layout)
        // Drop cats that left; add new ones.
        let visible = Set(layout.slots.map(\.sessionId))
        for (id, l) in catLayers where !visible.contains(id) || scaleChanged { l.removeFromSuperlayer(); catLayers[id] = nil }
        var arrived: [CALayer] = []
        for slot in layout.slots where catLayers[slot.sessionId] == nil {
            let l = CALayer()
            l.magnificationFilter = .nearest
            l.contentsScale = s
            // Sprite frames swap instantly (no cross-fade); position changes are tweened in `animate`.
            l.actions = ["contents": NSNull(), "opacity": NSNull()]
            l.frame = catRect(slot)
            layer?.addSublayer(l)
            catLayers[slot.sessionId] = l
            if !scaleChanged { arrived.append(l) }
        }
        if let bx = layout.basketX, !layout.basket.isEmpty {
            basketLabel.isHidden = false
            basketLabel.contentsScale = s
            basketLabel.string = "+\(layout.basket.count)"
            basketLabel.frame = CGRect(x: bx, y: (3 + 2) * layout.scale, width: TreeArt.basketW * layout.scale, height: 11)
        } else { basketLabel.isHidden = true }
        CATransaction.commit()
        removeAllToolTips()
        tips.removeAll()
        for slot in layout.slots {
            if let e = entries[slot.sessionId] {
                let tip = Tip(e)
                tips.append(tip)
                addToolTip(catRect(slot), owner: tip, userData: nil)
            }
        }
        animate(force: true)
        if !reduceMotion { arrived.forEach { Self.popIn($0) } }
        window?.invalidateCursorRects(for: self)
        return NSSize(width: layout.width, height: layout.height)
    }

    /// A cat lands on its perch: a small drop and a squash-and-settle.
    private static func popIn(_ l: CALayer, delay: CFTimeInterval = 0) {
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4; scale.toValue = 1
        scale.stiffness = 320; scale.damping = 16; scale.mass = 0.9
        scale.duration = scale.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = l.opacity; fade.duration = 0.16
        for a in [scale, fade] as [CAAnimation] {
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
            l.add(a, forKey: "pop-" + ((a as? CAPropertyAnimation)?.keyPath ?? ""))
        }
    }

    /// Every cat pops in, left to right, as the room drops down.
    func popInCats() {
        guard !reduceMotion else { return }
        for (i, slot) in layout.slots.enumerated() {
            if let l = catLayers[slot.sessionId] { Self.popIn(l, delay: 0.08 + Double(i) * 0.045) }
        }
    }

    /// Art-pixel geometry of a cat sitting on its perch.
    private func catRect(_ slot: TreeLayout.Slot, dy: Int = 0) -> CGRect {
        let s = layout.scale
        let perch = Double(slot.highPerch ? TreeArt.highPost : TreeArt.lowPost)
        // beam (3) + perch post + cushion (3) - 1 so the ground shadow sits on the cushion
        var bottom = 3 + perch + 3 - 1 + Double(dy)
        if slot.front { bottom = max(bottom, 3 + TreeArt.lowPost + 2) }
        return CGRect(x: slot.x + 1 * s, y: bottom * s,
                      width: Double(SpriteBook.canvasW) * s, height: Double(SpriteBook.canvasH) * s)
    }

    /// Seconds between animation ticks, so bobbing glides across the whole gap instead of jumping.
    var tickInterval: CFTimeInterval = 1 / 6

    /// Called by the animation timer. Only touches layers whose image changed.
    /// Positions glide: a bob eases between ticks, and a layout change slides cats to their new perch.
    func animate(force: Bool = false) {
        if !force { frameNo &+= 1 }
        CATransaction.begin()
        if reduceMotion || window == nil {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(force ? 0.38 : min(0.2, tickInterval * 0.9))
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        }
        let now = Date()
        for slot in layout.slots {
            guard let e = entries[slot.sessionId], let l = catLayers[slot.sessionId] else { continue }
            let (look, dy) = catLook(coat: e.cat, agent: e.session.agent.rawValue, state: e.session.state,
                                     frame: frameNo + abs(slot.sessionId.hashValue % 7),
                                     sinceState: now.timeIntervalSince(e.session.stateSince), still: reduceMotion)
            let img = book.image(look)
            if force || (l.contents as! CGImage?) !== img { l.contents = img }
            l.frame = catRect(slot, dy: dy)
            l.opacity = e.session.state == .gone ? 0.5 : 1
        }
        CATransaction.commit()
    }

    /// True when anything on screen moves at the moment (lets the timer slow down).
    var hasLivelyCats: Bool {
        layout.slots.contains { entries[$0.sessionId].map { $0.session.state != .idle && $0.session.state != .gone } ?? false }
    }

    // MARK: input

    private func cat(at event: NSEvent) -> Session? {
        let p = convert(event.locationInWindow, from: nil)
        return layout.slots.first { catRect($0).contains(p) }.flatMap { entries[$0.sessionId]?.session }
    }

    /// One click: the cat talks (bubble toggles right away). Second click of a double-click: go to its terminal.
    override func mouseDown(with event: NSEvent) {
        guard let s = cat(at: event) else { onTreeClick?(); return }
        if event.clickCount >= 2 { onCatDoubleClick?(s) } else { onCatClick?(s) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let s = cat(at: event) { onCatRightClick?(s, event) } else { onRightClick?(event) }
    }

    override func resetCursorRects() {
        for slot in layout.slots { addCursorRect(catRect(slot), cursor: .pointingHand) }
    }

    /// Where a visible cat is on screen, for anchoring its speech bubble.
    func screenRect(for sessionId: String) -> NSRect? {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
              let slot = layout.slots.first(where: { $0.sessionId == sessionId }) else { return nil }
        return window.convertToScreen(convert(catRect(slot), to: nil))
    }

    /// A little hop when a cat starts talking. Additive, so it rides on top of the idle animation.
    func hop(_ sessionId: String) {
        guard !reduceMotion, let l = catLayers[sessionId] else { return }
        let a = CAKeyframeAnimation(keyPath: "position.y")
        let h = 5 * layout.scale
        a.values = [0, h, 0, h * 0.35, 0]
        a.keyTimes = [0, 0.3, 0.6, 0.8, 1]
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
                             CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        a.isAdditive = true
        a.duration = 0.45
        l.add(a, forKey: "hop")
    }

    // MARK: tooltips

    private final class Tip: NSObject {
        let text: String
        init(_ e: Entry) {
            let s = e.session
            var t = "\(e.cat) · \(s.project) · \(s.agent.displayName)"
            if let origin = Origins.of(s) { t += " · \(origin.label)" }
            t += "\n\(Self.label(s.state))"
            if let a = s.activity { t += ": \(a)" }
            if let m = s.model { t += "\n\(m)" }
            text = t
        }
        static func label(_ s: CatState) -> String {
            switch s {
            case .permission: return "Needs your OK"
            case .question: return "Waiting for your answer"
            case .error: return "Hit an error"
            case .working: return "Working"
            case .thinking: return "Thinking"
            case .done: return "Done"
            case .idle: return "Idle"
            case .gone: return "Session ended"
            }
        }
        @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String { text }
    }
}

/// Draws the wooden/sisal tree for a layout, in art pixels.
enum TreeArt {
    static let highPost = 11.0, lowPost = 3.0, basketW = 22.0
    private static var cache: [String: CGImage] = [:]

    static func image(for l: TreeLayout) -> CGImage? {
        let s = l.scale
        let W = Int((l.width / s).rounded()), H = Int((l.height / s).rounded())
        let key = "\(W)x\(H)|" + l.slots.map { "\(Int(($0.x / s).rounded()))\($0.highPerch ? "h" : "l")" }.joined(separator: ",") + "|\(l.basketX ?? -1)"
        if let c = cache[key] { return c }
        var px = [UInt32?](repeating: nil, count: W * H)
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: String) {   // y counted from the top
            let v = SpriteBook.rgba(c)
            for yy in max(0, y)..<min(H, y + h) { for xx in max(0, x)..<min(W, x + w) { px[yy * W + xx] = v } }
        }
        func sisal(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            for yy in max(0, y)..<min(H, y + h) {
                rect(x, yy, w, 1, (yy / 2) % 2 == 0 ? "#D9BF8C" : "#C4A673")
            }
            rect(x + w - 1, y, 1, h, "#B89A68")   // shade on the right side
        }
        let postX = Int((l.postX / s).rounded())
        let beamY = H - 3
        if l.empty {
            sisal(postX + 2, 2, 6, H - 2)
            rect(postX, 0, 10, 2, "#6B4329")
            rect(postX - 18, H - 8, 22, 1, "#E07A5F"); rect(postX - 18, H - 7, 22, 1, "#C8553D"); rect(postX - 18, H - 6, 22, 1, "#9E3F2C")
            rect(postX, H - 2, 10, 2, "#6B4329")
        } else {
            // Beam from the leftmost perch to the post.
            let left = l.basketX.map { Int(($0 / s).rounded()) } ?? Int(((l.slots.first?.x ?? l.postX) / s).rounded())
            rect(left, beamY, postX + 10 - left, 1, "#A87650")
            rect(left, beamY + 1, postX + 10 - left, 1, "#8B5E3C")
            rect(left, beamY + 2, postX + 10 - left, 1, "#6B4329")
            // Main post, mounted under the menu bar.
            sisal(postX + 2, 2, 6, beamY - 2)
            rect(postX, 0, 10, 2, "#6B4329")
            for slot in l.slots {
                let x = Int((slot.x / s).rounded())
                let h = Int(slot.highPerch ? highPost : lowPost)
                sisal(x + 13, beamY - h, 4, h)
                let cy = beamY - h - 3
                rect(x + 3, cy, 24, 1, "#E07A5F"); rect(x + 3, cy + 1, 24, 1, "#C8553D"); rect(x + 3, cy + 2, 24, 1, "#9E3F2C")
            }
            if let bx = l.basketX {
                let x = Int((bx / s).rounded())
                // Woven basket of sleeping cats.
                for yy in 0..<8 { for xx in 0..<Int(basketW) {
                    rect(x + xx, beamY - 8 + yy, 1, 1, (xx + yy) % 2 == 0 ? "#B07A45" : "#8A5A30")
                } }
                rect(x, beamY - 9, Int(basketW), 1, "#C99560")
                rect(x + 3, beamY - 11, 6, 2, "#F5934A"); rect(x + 10, beamY - 11, 6, 2, "#C9C6C2")   // two curled backs
            }
        }
        let img = SpriteBook.makeImage(px, W, H)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = img
        return img
    }
}
