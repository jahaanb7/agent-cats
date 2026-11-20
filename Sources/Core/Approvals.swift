import Foundation

/// Shared by the socket worker and monitor queue. Completion wins at most once.
final class HookReply {
    private let lock = NSLock()
    private var result: [String: Any]?
    let deadline: Date

    init(timeout: TimeInterval = ApprovalProtocol.timeout) { deadline = Date().addingTimeInterval(timeout) }
    var pending: Bool {
        lock.lock(); defer { lock.unlock() }
        return result == nil && Date() < deadline
    }
    @discardableResult func complete(_ value: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard result == nil, Date() < deadline else { return false }
        result = value
        return true
    }
    func response() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        if let result { return result }
        return Date() >= deadline ? [:] : nil
    }
}

struct PendingApproval: Identifiable {
    let id = UUID().uuidString
    let sessionID: String
    let tool: String
    let input: String
    let reply: HookReply
    /// One sentence for the cat to say ("I want to run the test suite.") and the short tool label.
    let ask: String
    let detail: String
    var expiresAt: Date { reply.deadline }
    /// Same tool + same input: how a later PostToolUse is matched back to this request.
    var key: String { tool + "\u{0}" + input }
}

/// Used only on Monitor.queue; historical/spooled events never create approvals.
final class ApprovalStore {
    private(set) var requests: [PendingApproval] = []

    func add(_ object: [String: Any], reply: HookReply) {
        guard ApprovalProtocol.supports(object), reply.pending else { reply.complete([:]); return }
        guard let input = object["tool_input"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { reply.complete([:]); return }
        let tool = object["tool_name"] as! String
        requests.append(PendingApproval(sessionID: object["session_id"] as! String, tool: tool, input: text, reply: reply,
                                        ask: Summary.toolAsk(tool, input), detail: toolLabel(tool, input)))
    }

    static func key(tool: String?, input: Any?) -> String? {
        guard let tool, let input = input as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return tool + "\u{0}" + text
    }

    func first(session: String) -> PendingApproval? { requests.first { $0.sessionID == session && $0.reply.pending } }

    @discardableResult func resolve(_ id: String, decision: ApprovalProtocol.Decision, message: String? = nil) -> Bool {
        guard let request = requests.first(where: { $0.id == id }) else { return false }
        let accepted = request.reply.complete(ApprovalProtocol.response(decision, message: message))
        requests.removeAll { $0.id == id }
        return accepted
    }

    /// Releases waiting requests to the agent's own prompt: all of them, one session's, or (with
    /// `key`) only the one a finished tool call belongs to, which means it was answered elsewhere.
    func cancel(session: String? = nil, key: String? = nil) {
        for request in requests where (session == nil || request.sessionID == session) && (key == nil || request.key == key) {
            request.reply.complete([:])
        }
        sweep()
    }

    @discardableResult func sweep() -> Bool {
        let count = requests.count
        requests.removeAll { !$0.reply.pending }
        return requests.count != count
    }
}
