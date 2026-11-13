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
    public var detail: String?          // tool name + short input, prompt excerpt, error text
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
    public var usage = TokenUsage()
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var rateLimits: [RateLimit] = []
    public var costUSD: Double?         // the agent's own API-equivalent estimate, when it reports one
    public var plan: String?
    public var hookSeen = false         // true once any hook event arrived (accurate states)
    public var recent: [String] = []    // short activity log, newest last

    public var contextPercent: Double? {
        guard let t = contextTokens, let w = contextWindow, w > 0 else { return nil }
        return Double(t) / Double(w) * 100
    }

    public init(id: String, agent: AgentKind, at: Date) {
        self.id = id; self.agent = agent; startedAt = at; lastEventAt = at; stateSince = at
    }
}
