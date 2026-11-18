import AppKit
import SwiftUI

// Renders the dashboard with sample sessions to dist/dashboard-preview.png for a visual check.
let app = NSApplication.shared
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let book = SpriteBook(url: root.appendingPathComponent("Art/cats.json"))
let now = Date()
func session(_ id: String, _ state: CatState, _ project: String, _ configure: (inout Session) -> Void = { _ in }) -> Session {
    var s = Session(id: id, agent: .claude, at: now.addingTimeInterval(-3600))
    s.state = state; s.cwd = "/Users/me/Projects/" + project; s.stateSince = now.addingTimeInterval(-40)
    s.model = "claude-opus-5-5"; s.tty = "ttys001"; s.hookSeen = true; s.entrypoint = "cli"
    configure(&s)
    return s
}
let sessions = [
    session("a", .permission, "agent-cats") {
        $0.title = "Pop-up cats and a calmer dashboard"; $0.activity = "Bash npm run build"
        $0.usage = TokenUsage(); $0.usage.input = 12_400; $0.usage.output = 48_200; $0.usage.cacheRead = 3_810_000; $0.usage.cacheWrite = 92_000
        $0.contextTokens = 61_000; $0.contextWindow = 200_000; $0.costUSD = 4.12
        $0.rateLimits = [RateLimit(name: "5h", usedPercent: 38, resetsAt: nil), RateLimit(name: "weekly", usedPercent: 71, resetsAt: nil)]
        $0.recent = ["20:41:02 prompt “make the dashboard better”", "20:41:09 toolStart Read Dashboard.swift", "20:41:10 toolEnd",
                     "20:41:31 toolStart Edit Dashboard.swift", "20:41:33 toolEnd", "20:41:40 permission Bash npm run build"]
    },
    session("b", .working, "reel-claude") { $0.activity = "Bash swift test"; $0.entrypoint = "sdk-cli"; $0.tty = nil },
    session("c", .done, "scamtest") { $0.lastMessage = "All green. Want me to open a PR?"; $0.entrypoint = "remote" },
    session("d", .thinking, "stream") { $0.agent = .codex; $0.model = "gpt-5-codex"; $0.entrypoint = "codex_vscode"; $0.tty = nil },
    session("e", .idle, "notes"),
]
let model = DashboardModel()
model.book = book
model.reduceMotion = true
model.hooksReady = CommandLine.arguments.contains("--no-hooks") ? false : true
model.entries = zip(sessions, ["Miso", "Mochi", "Pepper", "Sumi", "Oreo"]).map { CatTreeView.Entry(session: $0.0, cat: $0.1) }
if !CommandLine.arguments.contains("--empty") {
    model.approvals = [PendingApproval(sessionID: "a", tool: "Bash", input: "{\n  \"command\": \"npm run build\",\n  \"description\": \"Build the web app\"\n}", reply: HookReply())]
} else { model.entries = [] }
let size = NSSize(width: 880, height: 640)
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
window.titlebarAppearsTransparent = true
window.appearance = NSAppearance(named: .aqua)
let host = NSHostingView(rootView: DashboardView(model: model))
host.frame = NSRect(origin: .zero, size: size)
window.contentView = host
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
host.layoutSubtreeIfNeeded()
let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
host.cacheDisplay(in: host.bounds, to: rep)
let out = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "dist/dashboard-preview.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Rendered \(out)")
