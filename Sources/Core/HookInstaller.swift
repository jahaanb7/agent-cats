import Foundation

/// Plans, installs and removes Agent Cats hooks. Nothing is written without an explicit install call,
/// every write is preceded by a timestamped backup, and existing hooks (e.g. gstack's) are kept.
public struct HookInstaller {
    public struct Change {
        public var path: String
        public var before: String?   // nil = file does not exist yet
        public var after: String?    // nil = delete the file
    }

    public var hookBinary: String
    public static let marker = "agentcats-hook"

    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                               "PermissionRequest", "Notification", "Stop", "SubagentStop", "PreCompact", "SessionEnd"]
    static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                              "PermissionRequest", "Stop", "SessionEnd"]

    public init(hookBinary: String) { self.hookBinary = hookBinary }

    func command(_ agent: AgentKind) -> String { "\"\(hookBinary)\" \(agent.rawValue)" }

    /// Adds (or with `remove`, strips) our entries in a Claude-style `{"hooks": {...}}` document.
    static func merged(_ doc: [String: Any], events: [String], command: String?, remove: Bool) -> [String: Any] {
        var doc = doc
        var hooks = doc["hooks"] as? [String: Any] ?? [:]
        let all = Set(events).union(hooks.keys)
        for ev in all {
            var groups = (hooks[ev] as? [[String: Any]] ?? []).compactMap { g -> [String: Any]? in
                var g = g
                let hs = (g["hooks"] as? [[String: Any]] ?? []).filter { !(($0["command"] as? String) ?? "").contains(marker) }
                if hs.isEmpty && g["hooks"] != nil { return nil }
                g["hooks"] = hs
                return g
            }
            if !remove, events.contains(ev), let cmd = command {
                let interactive = ev == "PermissionRequest" && cmd.hasSuffix(" claude")
                groups.append(["hooks": [["type": "command", "command": cmd + (interactive ? " --approvals" : ""),
                                           "timeout": interactive ? Int(ApprovalProtocol.timeout + 10) : 5]]])
            }
            if groups.isEmpty { hooks[ev] = nil } else { hooks[ev] = groups }
        }
        if hooks.isEmpty { doc["hooks"] = nil } else { doc["hooks"] = hooks }
        return doc
    }

    static func render(_ doc: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\" : ", with: "\": ") + "\n"
    }

    static func load(_ path: String) -> (text: String?, doc: [String: Any])? {
        guard let d = FileManager.default.contents(atPath: path) else { return (nil, [:]) }
        let text = String(decoding: d, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, [:]) }
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }  // unparseable: refuse
        return (text, o)
    }

    public func plan(remove: Bool = false) throws -> [Change] {
        var out: [Change] = []
        for (agent, path, events) in [(AgentKind.claude, Paths.claudeSettings, Self.claudeEvents),
                                      (.codex, Paths.codexHooks, Self.codexEvents)] {
            guard let loaded = Self.load(path) else {
                throw NSError(domain: "AgentCats", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(path) is not valid JSON; not touching it"])
            }
            let (text, doc) = loaded
            let next = Self.merged(doc, events: events, command: command(agent), remove: remove)
            // Edit only the "hooks" block in place so the rest of the file stays byte-for-byte identical.
            var after: String? = text.map { Self.replacingHooks(in: $0, with: next["hooks"] as? [String: Any]) } ?? Self.render(next)
            if agent == .codex && next.isEmpty { after = text == nil ? nil : "" }
            if after == "" { after = nil }   // our hooks were the only content: remove the file
            if text == nil && after == nil { continue }
            if let t = text, let a = after, Self.normalized(t) == Self.normalized(a) { continue }
            out.append(Change(path: path, before: text, after: after))
        }
        return out
    }

    /// Range of a top-level key's value (and, for removal, the whole `"key": value,` member).
    static func topLevelMember(_ text: String, key: String) -> (member: Range<String.Index>, value: Range<String.Index>)? {
        let s = Array(text.unicodeScalars)
        var i = 0, depth = 0
        func idx(_ n: Int) -> String.Index { text.unicodeScalars.index(text.unicodeScalars.startIndex, offsetBy: n) }
        func skipString(_ j: Int) -> Int {   // j at opening quote; returns index after closing quote
            var k = j + 1
            while k < s.count { if s[k] == "\\" { k += 2; continue }; if s[k] == "\"" { return k + 1 }; k += 1 }
            return k
        }
        var memberStart = -1
        while i < s.count {
            let c = s[i]
            if c == "\"" {
                let end = skipString(i)
                if depth == 1 {
                    let name = String(String.UnicodeScalarView(s[(i + 1)..<(end - 1)]))
                    var k = end
                    while k < s.count, s[k] == " " || s[k] == "\n" || s[k] == "\t" || s[k] == "\r" { k += 1 }
                    if k < s.count, s[k] == ":" {
                        if name == key {
                            memberStart = i
                            k += 1
                            while k < s.count, s[k] == " " || s[k] == "\n" || s[k] == "\t" || s[k] == "\r" { k += 1 }
                            let vStart = k
                            var d = 0, m = k
                            while m < s.count {
                                let ch = s[m]
                                if ch == "\"" { m = skipString(m); if d == 0 { break }; continue }
                                if ch == "{" || ch == "[" { d += 1 }
                                if ch == "}" || ch == "]" { d -= 1; if d == 0 { m += 1; break }; if d < 0 { break } }
                                if d == 0 && ch == "," { break }
                                m += 1
                            }
                            let vEnd = m
                            // member: from key to just before the next key (eat a trailing comma) or the previous comma.
                            var mEnd = vEnd
                            while mEnd < s.count, s[mEnd] == " " || s[mEnd] == "\n" || s[mEnd] == "\t" || s[mEnd] == "\r" { mEnd += 1 }
                            var mStart = memberStart
                            if mEnd < s.count, s[mEnd] == "," {
                                mEnd += 1
                                while mEnd < s.count, s[mEnd] == " " || s[mEnd] == "\t" || s[mEnd] == "\r" || s[mEnd] == "\n" { mEnd += 1 }
                                // keep the indentation of the following key
                                var back = mEnd; while back > vEnd, s[back - 1] == " " || s[back - 1] == "\t" { back -= 1 }
                                mEnd = back
                                var ls = mStart; while ls > 0, s[ls - 1] == " " || s[ls - 1] == "\t" { ls -= 1 }
                                mStart = ls
                            } else {
                                var p = mStart - 1
                                while p >= 0, s[p] == " " || s[p] == "\n" || s[p] == "\t" || s[p] == "\r" { p -= 1 }
                                if p >= 0, s[p] == "," { mStart = p; mEnd = vEnd }
                            }
                            return (idx(mStart)..<idx(mEnd), idx(vStart)..<idx(vEnd))
                        }
                    }
                }
                i = end; continue
            }
            if c == "{" || c == "[" { depth += 1 }
            if c == "}" || c == "]" { depth -= 1 }
            i += 1
        }
        return nil
    }

    static func indent(_ json: String, by n: Int) -> String {
        let pad = String(repeating: " ", count: n)
        return json.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { $0.offset == 0 ? String($0.element) : pad + $0.element }.joined(separator: "\n")
    }

    static func replacingHooks(in text: String, with hooks: [String: Any]?) -> String {
        var out = text
        if let r = topLevelMember(text, key: "hooks") {
            if let h = hooks {
                out.replaceSubrange(r.value, with: indent(render(h).trimmingCharacters(in: .whitespacesAndNewlines), by: 2))
            } else {
                out.removeSubrange(r.member)
            }
            return out
        }
        guard let h = hooks else { return text }
        // No hooks yet: add as the last top-level member.
        guard let close = out.lastIndex(of: "}") else { return render(["hooks": h]) }
        var before = out[..<close]
        while let l = before.last, l == " " || l == "\n" || l == "\t" || l == "\r" { before.removeLast() }
        let needsComma = before.last != "{"
        let member = "  \"hooks\": " + indent(render(h).trimmingCharacters(in: .whitespacesAndNewlines), by: 2)
        return String(before) + (needsComma ? "," : "") + "\n" + member + "\n" + String(out[close...])
    }

    static func normalized(_ s: String) -> String {
        guard let o = jsonObject(s) else { return s }
        return render(o)
    }

    /// Writes the planned changes after backing up each file. Returns backup paths.
    public func apply(_ changes: [Change]) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Paths.backups, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var backups: [String] = []
        for c in changes {
            if let before = c.before {
                let b = Paths.backups + "/" + c.path.replacingOccurrences(of: "/", with: "_") + "." + stamp
                try before.write(toFile: b, atomically: true, encoding: .utf8)
                backups.append(b)
            }
            if let after = c.after {
                try fm.createDirectory(atPath: (c.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try after.write(toFile: c.path, atomically: true, encoding: .utf8)
            } else if fm.fileExists(atPath: c.path) {
                try fm.removeItem(atPath: c.path)
            }
        }
        return backups
    }

    /// Unified diff for display, via /usr/bin/diff.
    public static func diff(_ c: Change) -> String {
        let tmp = NSTemporaryDirectory()
        let a = tmp + "agentcats-before.json", b = tmp + "agentcats-after.json"
        try? (c.before ?? "").write(toFile: a, atomically: true, encoding: .utf8)
        try? (c.after ?? "").write(toFile: b, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        p.arguments = ["-u", "--label", c.before == nil ? "/dev/null" : c.path, "--label", c.after == nil ? "/dev/null" : c.path, a, b]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        try? FileManager.default.removeItem(atPath: a); try? FileManager.default.removeItem(atPath: b)
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
