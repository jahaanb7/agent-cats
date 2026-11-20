import Foundation

/// Turns raw agent output (tool calls, long replies) into one plain sentence a cat can say.
/// Pure and local: no network, no model calls.
public enum Summary {

    // MARK: tool calls

    /// "I want to run the test suite." / "I want to edit Models.swift." — what a tool call is for.
    public static func toolAsk(_ tool: String, _ input: Any?) -> String {
        let inp = input as? [String: Any] ?? [:]
        func str(_ k: String) -> String? {
            guard let v = inp[k] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func file(_ k: String = "file_path") -> String? { str(k).map { ($0 as NSString).lastPathComponent } }
        func quoted(_ s: String, _ n: Int = 40) -> String { "\u{201C}\(clip(s, n))\u{201D}" }

        switch tool {
        case "Bash", "exec_command", "shell", "local_shell", "BashOutput":
            // Claude writes its own 5–10 word description of every command: the best summary there is.
            if let d = str("description") { return sentence("I want to " + lowerFirst(d)) }
            if let c = str("command") ?? str("cmd") ?? (inp["command"] as? [String])?.joined(separator: " ") {
                return sentence("I want to " + commandGist(c))
            }
            return "I want to run a shell command."
        case "Edit", "MultiEdit": return "I want to edit \(file() ?? "a file")."
        case "Write": return "I want to write \(file() ?? "a file")."
        case "NotebookEdit": return "I want to edit the notebook \(file("notebook_path") ?? "")".trimmingCharacters(in: .whitespaces) + "."
        case "Read": return "I want to read \(file() ?? "a file")."
        case "Glob": return str("pattern").map { "I want to look for files matching \(quoted($0))." } ?? "I want to look for files."
        case "Grep": return str("pattern").map { "I want to search the code for \(quoted($0))." } ?? "I want to search the code."
        case "WebFetch":
            if let u = str("url"), let host = URL(string: u)?.host { return "I want to open a page on \(host)." }
            return "I want to open a web page."
        case "WebSearch": return str("query").map { "I want to search the web for \(quoted($0))." } ?? "I want to search the web."
        case "Task", "Agent":
            return str("description").map { sentence("I want to start a helper agent to " + lowerFirst($0)) }
                ?? "I want to start a helper agent."
        case "ExitPlanMode": return "My plan is ready. Can I start on it?"
        case "apply_patch": return "I want to apply a code change."
        case "TodoWrite": return "I want to update my to-do list."
        case "KillShell", "KillBash": return "I want to stop a background command."
        default:
            if tool.hasPrefix("mcp__") {
                // mcp__server__tool_name → the "tool name" tool from server
                let pieces = tool.dropFirst(5).components(separatedBy: "__")
                let action = (pieces.count > 1 ? pieces[1] : pieces[0]).replacingOccurrences(of: "_", with: " ")
                return "I want to use \(pieces[0])\u{2019}s \u{201C}\(action)\u{201D} tool."
            }
            return "I want to use the \(tool) tool."
        }
    }

    /// The same sentence rebuilt from a short tool label ("Bash rm -rf build", "Edit Models.swift"),
    /// for requests that reached us without their full input.
    public static func askFromLabel(_ label: String) -> String {
        let parts = label.split(separator: " ", maxSplits: 1).map(String.init)
        guard let tool = parts.first else { return "I need your OK to continue." }
        let rest = parts.count > 1 ? parts[1].replacingOccurrences(of: "…", with: "") : ""
        switch tool {
        case "Bash", "exec_command", "shell", "local_shell": return toolAsk(tool, rest.isEmpty ? nil : ["command": rest])
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit": return toolAsk(tool, rest.isEmpty ? nil : ["file_path": rest])
        case "WebFetch": return toolAsk(tool, ["url": rest])
        case "WebSearch", "Grep", "Glob": return toolAsk(tool, ["query": rest, "pattern": rest])
        default:
            // Not a tool label (e.g. Codex's raw command, or a notification's text).
            if tool.first?.isUppercase == true, !tool.contains("_"), parts.count == 1 { return toolAsk(tool, nil) }
            return label.hasSuffix(".") ? label : sentence("I want to " + commandGist(label))
        }
    }

    /// A short gist of a shell command when there is no description: "run git push", "delete build/".
    static func commandGist(_ command: String) -> String {
        let first = command.components(separatedBy: CharacterSet(charactersIn: "\n;&|")).first ?? command
        let words = first.split(separator: " ").map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
        guard let head = words.first else { return "run a shell command" }
        let prog = (head as NSString).lastPathComponent
        let rest = words.dropFirst()
        switch prog {
        case "rm": return "delete " + (rest.last(where: { !$0.hasPrefix("-") }) ?? "files")
        case "mv": return "move " + (rest.first(where: { !$0.hasPrefix("-") }) ?? "files")
        case "cp": return "copy " + (rest.first(where: { !$0.hasPrefix("-") }) ?? "files")
        case "mkdir": return "create the folder " + (rest.last ?? "")
        case "cd": return "run " + clip(command.replacingOccurrences(of: "\n", with: " "), 44)
        case "git", "npm", "pnpm", "yarn", "bun", "cargo", "go", "swift", "make", "docker", "kubectl", "gh", "brew", "pip", "uv":
            let sub = rest.first(where: { !$0.hasPrefix("-") }).map { " " + $0 } ?? ""
            return "run \(prog)\(sub)"
        default:
            return "run " + clip(prog + (rest.first.map { " " + $0 } ?? ""), 40)
        }
    }

    // MARK: prose

    /// The first real sentence of a reply, without markdown, capped. "" stays "".
    public static func firstSentence(_ text: String, max n: Int = 160) -> String {
        let sentences = Summary.sentences(text)
        // Skip throwaway openers ("Done.", "Got it.") when something more useful follows.
        let useful = sentences.first { $0.split(separator: " ").count >= 3 } ?? sentences.first ?? ""
        return clip(useful, n)
    }

    /// What a reply is asking you: its last question, or else its first sentence.
    public static func ask(_ text: String, max n: Int = 180) -> String {
        if let q = sentences(text).last(where: { $0.hasSuffix("?") }) { return clip(q, n) }
        return firstSentence(text, max: n)
    }

    /// A brief of a whole reply in at most `count` sentences, for the dashboard.
    public static func brief(_ text: String, sentences count: Int = 2, max n: Int = 260) -> String {
        let all = sentences(text).filter { $0.split(separator: " ").count >= 3 }
        let picked = (all.isEmpty ? sentences(text) : all).prefix(count).joined(separator: " ")
        return clip(picked, n)
    }

    /// Plain-text sentences: markdown markers, code blocks, tables and list bullets removed.
    static func sentences(_ text: String) -> [String] {
        var lines: [String] = []
        var inCode = false
        for raw in text.components(separatedBy: .newlines) {
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || l.isEmpty || l.hasPrefix("|") || l.allSatisfy({ "-=*_ ".contains($0) }) { lines.append(""); continue }
            while let f = l.first, "#>".contains(f) { l.removeFirst() }
            if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("+ ") { l.removeFirst(2) }
            if let r = l.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { l.removeSubrange(r) }
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
            l = l.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            l = l.trimmingCharacters(in: .whitespaces)
            // A heading or list item without end punctuation is its own sentence.
            if let last = l.last, !".!?:".contains(last) { l += "." }
            lines.append(l)
        }
        let joined = lines.filter { !$0.isEmpty }.joined(separator: " ")
        var out: [String] = []
        var cur = ""
        let chars = Array(joined)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            guard ".!?".contains(ch) else { continue }
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            // "e.g." / "v1.2" / "file.swift" aren't sentence ends: need a space after.
            guard next == " " else { continue }
            let t = cur.trimmingCharacters(in: .whitespaces)
            if t.count > 1 { out.append(t) }
            cur = ""
        }
        let tail = cur.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out.map { $0.hasSuffix(":") ? String($0.dropLast()) + "." : $0 }
    }

    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        // Keep acronyms and names ("NPM", "README") as written.
        if s.count > 1, s[s.index(after: s.startIndex)].isUppercase { return s }
        return f.lowercased() + s.dropFirst()
    }

    static func sentence(_ s: String) -> String {
        var t = clip(s, 150)
        if let l = t.last, !".!?…".contains(l) { t += "." }
        return t
    }
}

/// One request you gave the agent and what came of it.
public struct WorkTask: Sendable, Equatable {
    public var prompt: String
    public var startedAt: Date
    public var endedAt: Date?
    public var files: [String] = []      // changed files (basenames), first-touched order
    public var steps: [String] = []      // what it did, one sentence each ("I want to run the tests." → "run the tests")
    public var commands = 0
    public var searches = 0
    public var reads = 0
    public var failures = 0
    public var reply: String?            // its last words for this task

    public init(prompt: String, startedAt: Date) { self.prompt = prompt; self.startedAt = startedAt }

    /// "Edited 3 files · ran 5 commands · 4 lookups"
    public var tally: String {
        var parts: [String] = []
        if !files.isEmpty { parts.append("changed \(files.count) file\(files.count == 1 ? "" : "s")") }
        if commands > 0 { parts.append("ran \(commands) command\(commands == 1 ? "" : "s")") }
        if searches + reads > 0 { parts.append("\(searches + reads) lookup\(searches + reads == 1 ? "" : "s")") }
        if failures > 0 { parts.append("\(failures) failed step\(failures == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// The outcome in a sentence or two, from its final reply.
    public var outcome: String? { reply.map { Summary.brief($0) }.flatMap { $0.isEmpty ? nil : $0 } }

    mutating func record(tool: String, files changed: [String], ask: String?) {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch":
            for p in changed {
                let name = (p as NSString).lastPathComponent
                if !name.isEmpty, !files.contains(name) { files.append(name) }
            }
        case "Bash", "exec_command", "shell", "local_shell":
            commands += 1
            if let a = ask { addStep(a) }
        case "Grep", "Glob", "WebSearch", "WebFetch": searches += 1
        case "Read": reads += 1
        case "Task", "Agent": if let a = ask { addStep(a) }
        default: break
        }
    }

    /// Paths a tool call changes: file_path / notebook_path, or the files named in a Codex patch.
    static func changedFiles(_ tool: String, _ input: Any?) -> [String] {
        let inp = input as? [String: Any] ?? [:]
        if let p = (inp["file_path"] as? String) ?? (inp["notebook_path"] as? String) { return [p] }
        guard tool == "apply_patch", let s = (input as? String) ?? (inp["input"] as? String) else { return [] }
        return s.split(separator: "\n").compactMap { line -> String? in
            for marker in ["*** Update File: ", "*** Add File: "] where line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    private mutating func addStep(_ ask: String) {
        var s = ask
        for p in ["I want to ", "I want "] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if s.hasSuffix(".") { s.removeLast() }
        guard !s.isEmpty, steps.last != s else { return }
        steps.append(s)
        if steps.count > 12 { steps.removeFirst(steps.count - 12) }
    }
}
