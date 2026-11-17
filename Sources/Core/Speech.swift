import Foundation

/// One keystroke-level step typed into an agent's terminal.
public enum KeyStep: Equatable, Sendable {
    case text(String)   // literal characters, no newline
    case returnKey
    case escape
    case pause          // let the TUI redraw before the next step
}

/// What a cat says in its speech bubble, and how each reply reaches the agent.
/// Pure: built from a Session snapshot so it can be tested without any UI.
public struct Speech: Equatable, Sendable {
    public enum Mood: Equatable, Sendable { case permission, question, done, error, status }

    public enum Reply: Equatable, Sendable {
        case hook(allow: Bool)   // answer the waiting PermissionRequest hook (no typing)
        case keys([KeyStep])     // type into the session's terminal
        case openTerminal
    }

    public struct Choice: Equatable, Sendable {
        public var label: String
        public var reply: Reply
        public var primary = false
    }

    /// How free text typed in the bubble is delivered.
    public enum TextReply: Equatable, Sendable {
        case hookDeny                     // deny the waiting hook and pass the text to the agent
        case keys(prefix: [KeyStep])      // prefix, then the text, then Return
    }

    public var mood: Mood
    public var headline: String
    public var text: String
    public var choices: [Choice]
    public var textReply: TextReply?
    public var placeholder: String
    /// Identifies the moment being answered; a reply is only delivered while it still matches.
    public var token: String

    public var needsAnswer: Bool { mood == .permission || mood == .question }

    public static func token(_ s: Session) -> String {
        "\(s.id)|\(s.state.rawValue)|\(s.stateSince.timeIntervalSince1970)"
    }

    /// - canType: the session's terminal can be typed into (Terminal.app / iTerm2, or unknown).
    /// - appName: where the session lives, for "Open in …" when it can't be typed into.
    public static func make(_ s: Session, hookPending: Bool, canType: Bool = true, appName: String? = nil) -> Speech {
        var sp = base(s, hookPending: hookPending)
        guard !canType else { return sp }
        // No way to type there: drop keystroke replies and offer the jump instead.
        sp.choices = sp.choices.filter { if case .keys = $0.reply { return false }; return true }
        if case .keys? = sp.textReply { sp.textReply = nil }
        if sp.choices.isEmpty, sp.needsAnswer || sp.mood == .done {
            sp.choices = [.init(label: "Answer in \(appName ?? "the terminal")", reply: .openTerminal, primary: true)]
        }
        return sp
    }

    /// Commands where a one-tap Allow is a bad default.
    static func looksDestructive(_ text: String) -> Bool {
        let t = text.lowercased()
        // "--force" also matches "--force-with-lease"; that's acceptable, it's still a force push.
        return ["rm -r", "rm -f", "--force", "push -f", "reset --hard", "clean -f", "drop table", "drop database",
                "sudo ", "mkfs", "dd if=", "chmod -r", "chown -r", "truncate "].contains { t.contains($0) }
    }

    private static func base(_ s: Session, hookPending: Bool) -> Speech {
        let token = token(s)
        let claude = s.agent == .claude
        switch s.state {
        case .permission:
            let what = s.activity ?? "use a tool"
            let risky = looksDestructive(what)
            if hookPending {
                return Speech(mood: .permission, headline: risky ? "Careful! Run this?" : "Can I run this?", text: what,
                              choices: [.init(label: "Allow", reply: .hook(allow: true), primary: !risky),
                                        .init(label: "Deny", reply: .hook(allow: false), primary: risky)],
                              textReply: .hookDeny, placeholder: "Or say what to do instead…", token: token)
            }
            // Claude Code: "1" = Yes, Esc = No. Codex: "y" / "n".
            let yes: [KeyStep] = claude ? [.text("1")] : [.text("y")]
            let no: [KeyStep] = claude ? [.escape] : [.text("n")]
            return Speech(mood: .permission, headline: risky ? "Careful! Run this?" : "Can I run this?", text: what,
                          choices: [.init(label: "Allow", reply: .keys(yes), primary: !risky),
                                    .init(label: "Deny", reply: .keys(no), primary: risky)],
                          textReply: claude ? .keys(prefix: [.escape, .pause]) : nil,
                          placeholder: "Or say what to do instead…", token: token)

        case .question:
            // Digits pick options 1–9 only, and an empty or longer list has no safe digit mapping.
            if let q = s.question, claude, q.multiSelect || q.more > 0 || q.options.isEmpty || q.options.count > 9 {
                // Multi-part and multi-select questions need the terminal's own picker.
                let note = q.multiSelect ? "(pick several in the terminal)" : "(+\(q.more) more questions in the terminal)"
                return Speech(mood: .question, headline: "Pick for me?", text: q.text + "\n" + note,
                              choices: [.init(label: "Answer in terminal", reply: .openTerminal, primary: true)],
                              textReply: nil, placeholder: "", token: token)
            }
            if let q = s.question, claude {
                let text = q.text
                let choices = q.options.enumerated().map { i, label in
                    Choice(label: label, reply: .keys([.text("\(i + 1)")]), primary: i == 0)
                }
                // The entry after the listed options is Claude's "type something" field.
                return Speech(mood: .question, headline: "Pick one for me?", text: text, choices: choices,
                              textReply: .keys(prefix: [.text("\(q.options.count + 1)"), .pause]),
                              placeholder: "Type your own answer…", token: token)
            }
            let text = s.lastMessage ?? "I'm waiting for you."
            return Speech(mood: .question, headline: "Your turn", text: text,
                          choices: yesNo(text), textReply: .keys(prefix: []),
                          placeholder: "Reply…", token: token)

        case .done:
            let text = s.lastMessage ?? s.activity.map { "Finished \($0)" } ?? "All done!"
            return Speech(mood: .done, headline: "All done!", text: text,
                          choices: yesNo(text), textReply: .keys(prefix: []),
                          placeholder: "Reply to keep going…", token: token)

        case .error:
            return Speech(mood: .error, headline: "I hit a snag", text: s.activity ?? "Something went wrong.",
                          choices: [.init(label: "Open terminal", reply: .openTerminal, primary: true)],
                          textReply: nil, placeholder: "", token: token)

        case .working, .thinking:
            return Speech(mood: .status, headline: s.state == .working ? "Working…" : "Thinking…",
                          text: s.activity ?? "On it.", choices: [], textReply: nil, placeholder: "", token: token)

        case .idle:
            return Speech(mood: .status, headline: "Napping", text: s.lastMessage ?? "Nothing to do right now.",
                          choices: [], textReply: .keys(prefix: []), placeholder: "Give me a task…", token: token)

        case .gone:
            return Speech(mood: .status, headline: "Gone home", text: "This session has ended.",
                          choices: [], textReply: nil, placeholder: "", token: token)
        }
    }

    /// Offer one-tap Yes/No when the agent ended on a question.
    private static func yesNo(_ text: String) -> [Choice] {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else { return [] }
        return [.init(label: "Yes", reply: .keys([.text("Yes"), .pause, .returnKey]), primary: true),
                .init(label: "No", reply: .keys([.text("No"), .pause, .returnKey]))]
    }

    /// Text safe to type into a terminal: one line, no control characters, capped.
    public static func typeable(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let kept = flat.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(2000))
    }

    /// Steps for a free-text reply, or nil when this moment takes no typed text.
    public func steps(forText raw: String) -> [KeyStep]? {
        guard case .keys(let prefix)? = textReply else { return nil }
        let t = Speech.typeable(raw)
        guard !t.isEmpty else { return nil }
        return prefix + [.text(t), .pause, .returnKey]
    }
}
