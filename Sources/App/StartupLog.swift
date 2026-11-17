import Foundation

/// Small local startup log, useful when a menu-bar app fails before it can show a window.
enum StartupLog {
    static let directory = NSHomeDirectory() + "/Library/Logs/AgentCats"
    static func write(_ message: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/startup.log"
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 131072 {
            try? fm.removeItem(atPath: path)
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let file = FileHandle(forWritingAtPath: path) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8))
    }
}
