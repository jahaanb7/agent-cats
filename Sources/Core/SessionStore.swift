import Foundation

/// Applies normalized events to sessions. Not thread-safe: the Monitor calls it on one serial queue.
public final class SessionStore {
    public private(set) var sessions: [String: Session] = [:]

    public struct Timing {
        public var doneToIdle: TimeInterval = 45
        public var errorToIdle: TimeInterval = 300
        public var stalledToIdle: TimeInterval = 600     // busy with no events (e.g. interrupted, no Stop hook)
        public var goneRemoval: TimeInterval = 120
        public var unverifiedExpiry: TimeInterval = 900  // no process match and no events for this long
        public init() {}
    }
    public var timing = Timing()

    public init() {}

    @discardableResult
    public func apply(_ e: AgentEvent) -> (old: CatState?, new: CatState)? {
        var s = sessions[e.sessionId] ?? Session(id: e.sessionId, agent: e.agent, at: e.time)
        let isNew = sessions[e.sessionId] == nil
        let old = isNew ? nil : s.state

        // Metadata always applies.
        if let c = e.cwd, !c.isEmpty { s.cwd = c }
        if let ep = e.entrypoint, !ep.isEmpty { s.entrypoint = ep }
        if let m = e.model, !m.isEmpty { s.model = m }
        if let p = e.pid { s.pid = p }
        if let t = e.tty { s.tty = t }
        if let tp = e.transcriptPath { s.transcriptPath = tp }
        if let t = e.title, !t.isEmpty { s.title = t }
        if let c = e.costUSD { s.costUSD = c }
        if let p = e.plan { s.plan = p }
        if let w = e.contextWindow { s.contextWindow = w }
        if let rl = e.rateLimits, !rl.isEmpty { s.rateLimits = rl }
        if let u = e.usage {
            // Codex reports running totals; Claude reports per message, so add those up.
            if e.agent == .codex { s.usage = u } else {
                s.usage.input += u.input; s.usage.output += u.output
                s.usage.cacheRead += u.cacheRead; s.usage.cacheWrite += u.cacheWrite; s.usage.reasoning += u.reasoning
            }
        }
        if let c = e.contextTokens { s.contextTokens = c }
        if let m = e.message, !m.isEmpty { s.lastMessage = m }
        if e.source == .hook { s.hookSeen = true }
        if e.time > s.lastEventAt || isNew { s.lastEventAt = max(s.lastEventAt, e.time) }

        // With hooks installed, log lines only add metadata; hooks drive state (they are earlier and exact).
        let drivesState = e.source != .log || !s.hookSeen || e.kind == .error
        recordWork(e, drivesState: drivesState, in: &s)
        // While Agent Cats holds a permission request, other tool traffic in the same session (parallel
        // tool calls, subagents) must not knock the cat out of "asking": that would drop your Allow.
        let pinned = s.awaitingApproval && s.state == .permission &&
            [.toolStart, .toolEnd, .toolFailed, .question, .permission].contains(e.kind)
        var next = s.state
        if drivesState && !pinned {
            switch e.kind {
            case .sessionStart: if s.state == .gone || isNew { next = .idle }
            case .prompt: next = .thinking; s.question = nil; s.lastMessage = nil; s.activity = e.detail.map { "\u{201C}\($0)\u{201D}" } ?? s.activity
            case .toolStart: next = .working; s.question = nil; if let d = e.detail { s.activity = d }; if let a = e.ask { s.ask = a }
            case .toolEnd, .toolFailed: s.question = nil; if s.state == .working || s.state == .permission || s.state == .question { next = .thinking }
            case .permission:
                next = .permission; s.question = nil; if let d = e.detail { s.activity = d }
                // A tool-based request knows exactly what it wants; a bare notification only says "permission".
                if e.toolName != nil || s.ask == nil || s.state != .working { s.ask = e.ask ?? s.ask }
            case .question:
                // A bare "waiting for input" notification keeps an open multiple-choice question.
                if let q = e.question { s.question = q } else if s.state != .question { s.question = nil }
                next = .question; if let d = e.detail { s.activity = d }
            case .turnEnd: next = .done; s.question = nil
            case .error: next = .error; if let d = e.detail { s.activity = d }
            case .sessionEnd, .processExit: next = .gone
            case .usage, .meta: break
            }
        }
        if next != s.state { s.state = next; s.stateSince = e.time }
        if s.state != .permission && !s.awaitingApproval { s.ask = s.state == .working ? s.ask : nil }
        if let line = logLine(e) {
            s.recent.append(line); if s.recent.count > 30 { s.recent.removeFirst(s.recent.count - 30) }
        }
        sessions[e.sessionId] = s
        return (old, s.state)
    }

    /// Keeps a short history of what you asked for and what the agent did about it.
    private func recordWork(_ e: AgentEvent, drivesState: Bool, in s: inout Session) {
        func current() -> Int {
            if s.tasks.isEmpty { s.tasks.append(WorkTask(prompt: "", startedAt: e.time)) }
            return s.tasks.count - 1
        }
        switch e.kind {
        case .prompt where drivesState:
            if let i = s.tasks.indices.last, s.tasks[i].endedAt == nil { s.tasks[i].endedAt = e.time }
            let text = e.prompt ?? e.detail ?? ""
            // The same request seen twice (hook, then transcript before hooks were known) is one task.
            if let last = s.tasks.last, !text.isEmpty, last.prompt == text, abs(last.startedAt.timeIntervalSince(e.time)) < 120 { break }
            s.tasks.append(WorkTask(prompt: text, startedAt: e.time))
            if s.tasks.count > 8 { s.tasks.removeFirst(s.tasks.count - 8) }
        case .toolStart:
            if let id = e.toolUseId {
                guard !s.seenToolUses.contains(id) else { break }
                s.seenToolUses.append(id)
                if s.seenToolUses.count > 400 { s.seenToolUses.removeFirst(100) }
            } else if !drivesState { break }
            guard let tool = e.toolName else { break }
            s.tasks[current()].record(tool: tool, files: e.toolFiles, ask: e.ask)
        case .toolFailed where drivesState:
            s.tasks[current()].failures += 1
        case .turnEnd where drivesState:
            if let i = s.tasks.indices.last { s.tasks[i].endedAt = e.time }
        default: break
        }
        if let p = e.prompt, e.kind != .prompt, let i = s.tasks.indices.last, s.tasks[i].prompt.isEmpty { s.tasks[i].prompt = p }
        if let m = e.message, !m.isEmpty, !s.tasks.isEmpty { s.tasks[s.tasks.count - 1].reply = m }
    }

    /// Mirrors Agent Cats' own waiting approvals onto the session. `ask`/`detail` describe the first
    /// waiting request; when none is left, `answered` says how the last one went.
    func setApproval(_ id: String, waiting: (ask: String, detail: String, key: String)?,
                            answered: ApprovalProtocol.Decision? = nil, now: Date = Date()) {
        guard var s = sessions[id], s.state != .gone else { return }
        if let w = waiting {
            // A new request (or the next of several) is a new moment for the bubble.
            let changed = s.state != .permission || s.approvalKey != w.key
            s.awaitingApproval = true
            s.ask = w.ask; s.activity = w.detail; s.question = nil
            s.approvalKey = w.key
            if changed { s.state = .permission; s.stateSince = now }
        } else if s.awaitingApproval {
            s.awaitingApproval = false
            s.approvalKey = nil
            if s.state == .permission {
                // Allowed: it runs now. Denied: it thinks again. Handed off or timed out: the
                // terminal is showing its own prompt, so it is still asking.
                switch answered {
                case .allow?: s.state = .working; s.stateSince = now
                case .deny?: s.state = .thinking; s.stateSince = now
                default: break
                }
            }
        }
        sessions[id] = s
    }

    private static let hhmm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    private func logLine(_ e: AgentEvent) -> String? {
        switch e.kind {
        case .usage, .meta: return nil
        default:
            return "\(Self.hhmm.string(from: e.time)) \(e.kind.rawValue)\(e.detail.map { " " + $0 } ?? "")"
        }
    }

    /// Time-based transitions. Returns ids whose state changed.
    @discardableResult
    public func tick(now: Date = Date(), isAlive: (Session) -> Bool?) -> [String] {
        var changed: [String] = []
        for (id, var s) in sessions {
            let since = now.timeIntervalSince(s.stateSince)
            let quiet = now.timeIntervalSince(s.lastEventAt)
            var next = s.state
            switch s.state {
            // A turn that ended on a question keeps waiting for your answer.
            case .done where since > timing.doneToIdle && !s.asksForReply: next = .idle
            case .error where since > timing.errorToIdle: next = .idle
            case .working, .thinking:
                if quiet > timing.stalledToIdle { next = .idle }
            case .gone where since > timing.goneRemoval:
                sessions[id] = nil; changed.append(id); continue
            default: break
            }
            if s.state != .gone {
                switch isAlive(s) {
                case .some(false): next = .gone
                case .none where quiet > timing.unverifiedExpiry:
                    sessions[id] = nil; changed.append(id); continue
                default: break
                }
            }
            if next != s.state { s.state = next; s.stateSince = now; sessions[id] = s; changed.append(id) }
        }
        return changed
    }

    public func remove(_ id: String) { sessions[id] = nil }

    public func setLaunchKey(_ id: String, _ key: String) {
        guard var s = sessions[id], s.launchKey == nil else { return }
        s.launchKey = key; sessions[id] = s
    }

    public func setProcess(_ id: String, pid: Int32, tty: String?) {
        guard var s = sessions[id] else { return }
        s.pid = pid; if let t = tty { s.tty = t }
        sessions[id] = s
    }

    /// Moves a placeholder (process seen before any transcript) onto the real session id.
    public func merge(placeholder: String, into real: String) {
        guard let p = sessions[placeholder] else { return }
        sessions[placeholder] = nil
        if var r = sessions[real] {
            if r.pid == nil { r.pid = p.pid }; if r.tty == nil { r.tty = p.tty }
            r.startedAt = min(r.startedAt, p.startedAt)
            sessions[real] = r
        }
    }

    /// Stable display order: sessions needing you first, then by start time (so cats don't shuffle).
    public var ordered: [Session] {
        sessions.values.sorted {
            if $0.wantsYou != $1.wantsYou { return $0.wantsYou }
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id < $1.id
        }
    }
}

// MARK: - cat assignment

/// One cat per project, stable across runs; collisions among live sessions get the next free cat.
public final class CatRoster {
    public static let names = ["Mochi", "Pepper", "Biscuit", "Sumi", "Miso", "Pebble", "Clementine", "Oreo"]
    private var byProject: [String: String]
    private let file: String?

    public init(file: String? = Paths.supportDir + "/cats.json") {
        self.file = file
        if let f = file, let d = FileManager.default.contents(atPath: f),
           let m = try? JSONDecoder().decode([String: String].self, from: d) { byProject = m } else { byProject = [:] }
    }

    public func cat(for session: Session, taken: Set<String>) -> String {
        let key = session.cwd.isEmpty ? session.id : session.cwd
        if let c = byProject[key], !taken.contains(c) { return c }
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let start = Int(h % UInt64(Self.names.count))
        for i in 0..<Self.names.count {
            let c = Self.names[(start + i) % Self.names.count]
            if !taken.contains(c) {
                if byProject[key] == nil { byProject[key] = c; save() }
                return c
            }
        }
        return Self.names[start]   // more sessions than cats: share
    }

    /// Lets the user pick which cat a project gets (kept across runs).
    public func setCat(_ cat: String, for session: Session) {
        guard Self.names.contains(cat) else { return }
        byProject[session.cwd.isEmpty ? session.id : session.cwd] = cat
        save()
    }

    private func save() {
        guard let f = file, let d = try? JSONEncoder().encode(byProject) else { return }
        try? FileManager.default.createDirectory(atPath: (f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: f))
    }
}
