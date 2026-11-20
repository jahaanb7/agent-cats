import Foundation

/// Sizes the cat tree to the number of live sessions and the space available under the menu bar.
///
/// Units are art pixels (the sprite grid) times a scale in points. Scales are chosen so every
/// art pixel lands on whole device pixels on Retina screens (1.5pt = 3px, 1pt = 2px, 0.5pt = 1px).
public struct TreeLayout: Equatable {
    public struct Slot: Equatable {
        public var sessionId: String
        public var x: Double          // points from the tree's left edge
        public var highPerch: Bool    // perches alternate high/low so the tree reads as a tree
        public var front: Bool        // needs attention: hops forward
    }

    public var scale: Double                 // points per art pixel
    public var width: Double                 // points
    public var height: Double                // points
    public var slots: [Slot]
    public var basket: [String]              // calm sessions that did not fit, shown as a "+N" basket
    public var basketX: Double?
    public var postX: Double
    public var empty: Bool

    // Geometry in art pixels.
    public static let slotW = 30.0, postW = 10.0, basketW = 26.0, pad = 4.0
    public static let treeH = 44.0, emptyH = 30.0
    public static let scales: [Double] = [3.0, 2.5, 2.0, 1.5, 1.0, 0.5]

    /// A lone cat is shown big; the room zooms out as more cats arrive.
    static func zoom(for n: Int) -> Double {
        switch n {
        case 1: return 4.0 / 3.0   // 2pt at the default size
        default: return 1.0
        }
    }

    /// - Parameters:
    ///   - ordered: sessions in display order (attention first), e.g. `SessionStore.ordered`.
    ///   - maxWidth: points available for the whole tree (e.g. 45% of the screen's visible width).
    ///   - preferredScale: user's size setting; the layout only ever shrinks from it.
    public static func compute(ordered: [Session], maxWidth: Double, preferredScale: Double = 1.5) -> TreeLayout {
        let n = ordered.count
        let cap = preferredScale * zoom(for: n)
        let scales = Self.scales.filter { $0 <= cap + 0.001 }
        let largest = scales.first ?? 1.5
        if n == 0 {
            // Just the post and an empty cushion, so you can still find and click the app.
            let w = (postW + 16 + pad * 2) * largest
            return TreeLayout(scale: largest, width: w, height: emptyH * largest, slots: [], basket: [],
                              basketX: nil, postX: w - (postW + pad) * largest, empty: true)
        }
        func need(_ visible: Int, basket: Bool) -> Double {
            Double(visible) * slotW + postW + pad * 2 + (basket ? basketW : 0)
        }
        // 1. Largest scale that fits everyone.
        //    Below 1pt cats stop being readable, so that size is reserved for step 3.
        for s in scales where s >= 1.0 && need(n, basket: false) * s <= maxWidth {
            return build(ordered, visible: n, scale: s)
        }
        // 2. Smallest scale still readable (1pt); overflow calm cats into the basket.
        //    Cats that need you are never hidden; if even they do not fit, drop to 0.5pt.
        let attention = ordered.filter { $0.wantsYou }.count
        for s in scales.filter({ $0 >= 1.0 }).reversed() + scales.filter({ $0 < 1.0 }) {
            let fit = Int(floor((maxWidth / s - postW - pad * 2 - basketW) / slotW))
            if fit >= max(1, attention) { return build(ordered, visible: min(fit, n), scale: s) }
        }
        return build(ordered, visible: max(1, attention), scale: scales.last ?? 0.5)
    }

    private static func build(_ ordered: [Session], visible: Int, scale s: Double) -> TreeLayout {
        let shown = Array(ordered.prefix(visible))
        let rest = ordered.dropFirst(visible).map(\.id)
        var x = pad
        var basketX: Double?
        if !rest.isEmpty { basketX = x * s; x += basketW }
        var slots: [Slot] = []
        for (i, sess) in shown.enumerated() {
            // Alternate perch heights counting from the post, so adding a cat never flips existing ones.
            let fromPost = shown.count - 1 - i
            slots.append(Slot(sessionId: sess.id, x: x * s, highPerch: fromPost % 2 == 0, front: sess.wantsYou))
            x += slotW
        }
        let postX = x * s
        x += postW + pad
        return TreeLayout(scale: s, width: x * s, height: treeH * s, slots: slots, basket: Array(rest),
                          basketX: basketX, postX: postX, empty: false)
    }
}
