import Foundation

/// A message you left for a busy agent.
public struct QueuedMessage: Equatable, Sendable, Identifiable {
    public let id: Int
    public var text: String
}

/// Messages queued for agents that are busy, delivered one per finished turn.
///
/// Typing into a terminal mid-turn can land on a permission prompt and answer it by accident, so
/// nothing is typed while the agent works. When its turn ends (done or idle, and not asking you
/// something) the first message goes out; the next waits for the turn that message starts to end.
/// Pure: the app owns one and does the typing.
public struct MessageQueue: Sendable {
    public static let limit = 20

    public private(set) var items: [String: [QueuedMessage]] = [:]
    /// Per session, the turn end (its Speech token) that already got a delivery attempt.
    /// One attempt per turn end: a success starts a new turn, a failure waits for you or the next one.
    public private(set) var used: [String: String] = [:]
    private var nextID = 1

    public init() {}

    public func list(_ session: String) -> [QueuedMessage] { items[session] ?? [] }

    public var counts: [String: Int] { items.mapValues(\.count).filter { $0.value > 0 } }

    /// Adds a message to the end of a session's line. Returns nil for empty text or a full queue.
    @discardableResult
    public mutating func add(_ raw: String, to session: String) -> QueuedMessage? {
        let text = Speech.typeable(raw)
        guard !text.isEmpty, list(session).count < Self.limit else { return nil }
        let m = QueuedMessage(id: nextID, text: text)
        nextID += 1
        items[session, default: []].append(m)
        return m
    }

    public mutating func remove(_ id: Int, from session: String) {
        items[session]?.removeAll { $0.id == id }
        if items[session]?.isEmpty == true { items[session] = nil }
    }

    /// Forget sessions that are gone.
    public mutating func prune(keeping live: Set<String>) {
        items = items.filter { live.contains($0.key) }
        used = used.filter { live.contains($0.key) }
    }

    /// The turn is over and the agent isn't waiting on an answer: a new message is safe to type.
    /// A question ("Want me to open a PR?") is yours to answer first, so it holds the queue.
    public static func canDeliver(_ s: Session) -> Bool {
        (s.state == .done && !s.asksForReply) || s.state == .idle
    }

    /// The message to send right now, if any: first in line, at a turn end not yet used.
    public func next(for s: Session) -> QueuedMessage? {
        guard Self.canDeliver(s), used[s.id] != Speech.token(s) else { return nil }
        return list(s.id).first
    }

    /// Call when a delivery attempt starts, so this turn end gets only one.
    public mutating func markAttempt(_ s: Session) { used[s.id] = Speech.token(s) }

    /// "Send now" after a failure: let this turn end be tried again.
    public mutating func allowRetry(_ session: String) { used[session] = nil }
}

extension Summary {
    /// What a busy cat says when you click it: the request it's on and what it's doing now,
    /// with a tally of the work so far as the small print.
    public static func working(_ s: Session) -> (text: String, detail: String?) {
        let task = s.tasks.last.flatMap { $0.endedAt == nil ? $0 : nil }
        var parts: [String] = []
        if let p = task?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            parts.append("Working on \u{201C}\(clip(p, 80))\u{201D}.")
        }
        if s.state == .working, let ask = s.ask {
            parts.append(Speech.ongoing(ask))
        } else if s.state == .thinking {
            parts.append(task == nil ? "Thinking it over." : "Thinking about the next step.")
        }
        if parts.isEmpty { parts.append(s.activity.map { "Busy with \(clip($0, 80))." } ?? "On it.") }
        let tally = task?.tally ?? ""
        return (parts.joined(separator: " "), tally.isEmpty ? (s.state == .working ? s.activity : nil) : tally)
    }
}
