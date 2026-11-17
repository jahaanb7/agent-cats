import Foundation

/// Only Claude's PermissionRequest protocol is supported for decisions.
enum ApprovalProtocol {
    static let timeout: TimeInterval = 120

    static func supports(_ object: [String: Any]) -> Bool {
        object["_agent"] as? String == "claude" &&
        object["hook_event_name"] as? String == "PermissionRequest" &&
        object["_waitForDecision"] as? Bool == true &&
        !(object["session_id"] as? String ?? "").isEmpty &&
        !(object["tool_name"] as? String ?? "").isEmpty &&
        object["tool_name"] as? String != "AskUserQuestion"
    }

    enum Decision { case allow, deny, handoff }

    /// The user's own words for a denial, as plain text: control characters dropped, length capped.
    static func cleanMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let kept = message.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(1000))
    }

    static func response(_ decision: Decision, message: String? = nil) -> [String: Any] {
        guard decision != .handoff else { return [:] }
        var value: [String: Any] = ["behavior": decision == .allow ? "allow" : "deny"]
        if decision == .deny {
            value["message"] = cleanMessage(message).map { "The user declined in Agent Cats and said: \($0)" }
                ?? "Denied by the user in Agent Cats."
        }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": value]]
    }

    /// Emit only the supported decision fields, never arbitrary data received from the socket.
    static func validatedResponse(_ data: Data) -> Data? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let output = root["hookSpecificOutput"] as? [String: Any],
              output["hookEventName"] as? String == "PermissionRequest",
              let decision = output["decision"] as? [String: Any],
              let behavior = decision["behavior"] as? String,
              behavior == "allow" || behavior == "deny" else { return nil }
        // Re-derive the reply; only the user's message text survives, re-cleaned.
        let said = (decision["message"] as? String).flatMap { m -> String? in
            let prefix = "The user declined in Agent Cats and said: "
            return m.hasPrefix(prefix) ? String(m.dropFirst(prefix.count)) : nil
        }
        return try? JSONSerialization.data(withJSONObject: response(behavior == "allow" ? .allow : .deny, message: said))
    }
}
