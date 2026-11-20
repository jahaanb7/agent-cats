import Foundation

/// Per-cat looks chosen by the user (accessories), saved between launches.
public final class CatStyle {
    public static let shared = CatStyle()
    public static let accessories: [(id: String, name: String)] = [
        ("none", "None"), ("crown", "Crown"), ("bow", "Bow"), ("flower", "Flower"),
        ("glasses", "Glasses"), ("shades", "Shades"), ("scarf", "Scarf"),
    ]
    /// Called after any change, so the room can redraw.
    public var onChange: (() -> Void)?
    private var byCat: [String: String]
    private let file: String

    public init(file: String = NSHomeDirectory() + "/Library/Application Support/AgentCats/styles.json") {
        self.file = file
        if let d = FileManager.default.contents(atPath: file),
           let m = try? JSONDecoder().decode([String: String].self, from: d) { byCat = m } else { byCat = [:] }
    }

    public func accessory(for cat: String) -> String? { byCat[cat] }

    public func set(_ accessory: String?, for cat: String) {
        if let a = accessory, a != "none", Self.accessories.contains(where: { $0.id == a }) { byCat[cat] = a } else { byCat[cat] = nil }
        if let d = try? JSONEncoder().encode(byCat) {
            try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: file))
        }
        onChange?()
    }
}
