import Foundation

/// Which coding agent a session belongs to. New agents add a case and a provider.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex
    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}

/// What the cat shows. Ordered roughly by how much it needs the user.
public enum CatState: String, Codable, Sendable {
    case permission   // blocked on an approval
    case question     // waiting for typed input
    case error        // tool/API failure or usage limit
    case working      // running a tool
    case thinking     // model is generating
    case done         // turn finished recently
    case idle         // nothing happening
    case gone         // process exited

    /// Needs the user right now (drives fade, ordering, urgent alerts).
    public var needsAttention: Bool { self == .permission || self == .question || self == .error }

    public var displayLabel: String {
        switch self {
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

    var sortRank: Int {
        switch self {
        case .permission: return 0
        case .question: return 1
        case .error: return 2
        case .working: return 3
        case .thinking: return 4
        case .done: return 5
        case .idle: return 6
        case .gone: return 7
        }
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, reasoning = 0
    public var total: Int { input + output + cacheRead + cacheWrite }
    /// Share of prompt tokens served from cache, nil when there were none.
    public var cacheHitRate: Double? {
        let prompt = input + cacheRead + cacheWrite
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }
    public init() {}
}

public struct RateLimit: Codable, Equatable, Sendable {
    public var name: String          // "5h", "weekly"
    public var usedPercent: Double
    public var resetsAt: Date?
}

/// A multiple-choice question the agent asked (Claude's AskUserQuestion). Only the first question is kept.
public struct AgentQuestion: Equatable, Sendable {
    public var text: String
    public var options: [String]
    /// How many further questions follow in the same prompt (answered in the terminal).
    public var more: Int
    /// Multi-select questions toggle options with digits instead of submitting.
    public var multiSelect: Bool
    public init(text: String, options: [String], more: Int = 0, multiSelect: Bool = false) {
        self.text = text; self.options = options; self.more = more; self.multiSelect = multiSelect
    }
}

/// One normalized event from any source (hook, transcript, rollout, process watcher).
public struct AgentEvent: Sendable {
    public enum Kind: String, Sendable {
        case sessionStart, prompt, toolStart, toolEnd, toolFailed, permission, question,
             turnEnd, sessionEnd, error, usage, meta, processExit
    }
    public enum Source: String, Sendable { case hook, log, process }

    public var agent: AgentKind
    public var sessionId: String
    public var kind: Kind
    public var source: Source
    public var time: Date
    public var cwd: String?
    /// How the agent was started: Claude's "cli" / "sdk-cli", Codex's originator, or "remote".
    public var entrypoint: String?
    public var detail: String?          // tool name + short input, prompt excerpt, error text
    public var question: AgentQuestion? // full question + options (AskUserQuestion)
    public var message: String?         // the agent's latest reply text, for the speech bubble
    public var model: String?
    public var pid: Int32?
    public var tty: String?
    public var transcriptPath: String?
    public var title: String?
    // usage payloads (only on .usage / .meta)
    public var usage: TokenUsage?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var rateLimits: [RateLimit]?
    public var costUSD: Double?
    public var plan: String?

    public init(agent: AgentKind, sessionId: String, kind: Kind, source: Source, time: Date = Date()) {
        self.agent = agent; self.sessionId = sessionId; self.kind = kind; self.source = source; self.time = time
    }
}

/// Live view of one agent session.
public struct Session: Sendable {
    public var id: String
    public var agent: AgentKind
    public var cwd: String = ""
    /// Folder the agent was launched in, used to match it to its process (the transcript cwd follows `cd`).
    public var launchKey: String?
    public var project: String { cwd.isEmpty ? "?" : (cwd as NSString).lastPathComponent }
    public var title: String?
    public var model: String?
    public var pid: Int32?
    public var tty: String?
    public var transcriptPath: String?
    public var startedAt: Date
    public var lastEventAt: Date
    public var stateSince: Date
    public var state: CatState = .idle
    public var activity: String?        // what it is doing right now
    public var question: AgentQuestion? // set while an AskUserQuestion prompt is open
    public var lastMessage: String?     // the agent's latest reply text (cleared by a new prompt)
    public var usage = TokenUsage()
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var rateLimits: [RateLimit] = []
    public var costUSD: Double?         // the agent's own API-equivalent estimate, when it reports one
    public var plan: String?
    public var hookSeen = false         // true once any hook event arrived (accurate states)
    public var entrypoint: String?      // how it was started (see AgentEvent.entrypoint)
    public var recent: [String] = []    // short activity log, newest last

    public var contextPercent: Double? {
        guard let t = contextTokens, let w = contextWindow, w > 0 else { return nil }
        return Double(t) / Double(w) * 100
    }

    public init(id: String, agent: AgentKind, at: Date) {
        self.id = id; self.agent = agent; startedAt = at; lastEventAt = at; stateSince = at
    }

    /// The turn finished on a question to you ("Want me to open a PR?"). Without hooks this is
    /// the most common way an agent asks for something, so it counts as needing you.
    public var asksForReply: Bool { state == .done && Session.endsWithQuestion(lastMessage) }

    /// Anything the cat should speak up about and bring the room back for.
    public var wantsYou: Bool { state.needsAttention || asksForReply }

    /// Where this session is running, from what the Mac can see. Cloud sessions started on a
    /// phone or in a browser never reach this Mac; "remote" means a local session driven from one.
    public func origin(hostBundleID: String?, hostName: String?) -> SessionOrigin? {
        SessionOrigin.classify(entrypoint: entrypoint, hasTTY: tty != nil, hostBundleID: hostBundleID, hostName: hostName)
    }

    public static func endsWithQuestion(_ text: String?) -> Bool {
        guard let text else { return false }
        let trailing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_`)\"'\u{201D}"))
        return text.trimmingCharacters(in: trailing).hasSuffix("?")
    }
}

/// Where a session runs, as far as this Mac can tell.
public enum SessionOrigin: Equatable, Sendable {
    case terminal(String?)   // Terminal, iTerm, Ghostty, Warp…
    case editor(String)      // VS Code, Cursor, JetBrains, Zed, Xcode…
    case desktop             // the Claude desktop app
    case background          // claude -p, the Agent SDK, scripts, codex exec: no window
    case remote              // a local session being driven from a phone or a browser

    public var label: String {
        switch self {
        case .terminal(let app): return app.map { "Terminal · \($0)" } ?? "Terminal"
        case .editor(let app): return app
        case .desktop: return "Claude app"
        case .background: return "Background"
        case .remote: return "Phone or browser"
        }
    }

    /// SF Symbol for the origin.
    public var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .desktop: return "macwindow"
        case .background: return "gearshape.2"
        case .remote: return "iphone"
        }
    }

    static let terminals: [String: String] = [
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm", "com.mitchellh.ghostty": "Ghostty",
        "dev.warp.Warp-Stable": "Warp", "com.github.wez.wezterm": "WezTerm", "net.kovidgoyal.kitty": "kitty",
        "org.alacritty": "Alacritty", "co.zeit.hyper": "Hyper", "org.tabby": "Tabby",
    ]
    static let editors: [String: String] = [
        "com.microsoft.VSCode": "VS Code", "com.microsoft.VSCodeInsiders": "VS Code", "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf", "dev.zed.Zed": "Zed", "com.apple.dt.Xcode": "Xcode",
    ]

    /// Words that only show up when a session is being driven from outside this Mac.
    public static func looksRemote(_ value: String) -> Bool {
        let v = value.lowercased()
        return ["remote", "mobile", "phone", "ios", "android", "web", "bridge"].contains { v.contains($0) }
    }

    public static func classify(entrypoint: String?, hasTTY: Bool, hostBundleID: String?, hostName: String?) -> SessionOrigin? {
        let ep = entrypoint?.lowercased() ?? ""
        if ep == "remote" || looksRemote(ep) { return .remote }
        // Scripted runs count as background even when a terminal started them.
        if ep.hasPrefix("sdk") || ep.contains("exec") { return .background }
        if let id = hostBundleID {
            if let name = terminals[id] { return .terminal(name) }
            if let name = editors[id] { return .editor(name) }
            if id.hasPrefix("com.jetbrains.") { return .editor(hostName ?? "JetBrains") }
            if id.hasPrefix("com.anthropic.") { return .desktop }
        }
        if ep.contains("vscode") { return .editor("VS Code") }
        if hasTTY { return .terminal(hostName) }
        if hostBundleID == nil && !ep.isEmpty { return .background }   // known agent, no window anywhere
        return hostName.map { .editor($0) }
    }
}
