import Foundation

// MARK: - helpers

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseDate(_ v: Any?) -> Date? {
    if let s = v as? String { return isoFrac.date(from: s) ?? isoPlain.date(from: s) }
    if let n = v as? Double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
    if let n = v as? Int { return Date(timeIntervalSince1970: Double(n) > 1e12 ? Double(n) / 1000 : Double(n)) }
    return nil
}

func jsonObject(_ line: Substring) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func jsonObject(_ s: String) -> [String: Any]? { jsonObject(Substring(s)) }

func clip(_ s: String, _ n: Int = 70) -> String {
    let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    return one.count > n ? String(one.prefix(n - 1)) + "…" : one
}

/// Longer text for the speech bubble: whitespace trimmed, blank-line runs collapsed, length capped.
func speechClip(_ s: String, _ n: Int = 600) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
    return t.count > n ? String(t.prefix(n - 1)) + "…" : t
}

/// First question + option labels from an AskUserQuestion tool input.
func askQuestion(_ input: Any?) -> AgentQuestion? {
    guard let qs = (input as? [String: Any])?["questions"] as? [[String: Any]], let q = qs.first,
          let text = q["question"] as? String, !text.isEmpty else { return nil }
    let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }.map { clip($0, 48) }
    return AgentQuestion(text: speechClip(text, 300), options: options, more: qs.count - 1,
                         multiSelect: q["multiSelect"] as? Bool ?? false)
}

func int(_ v: Any?) -> Int { (v as? Int) ?? Int((v as? Double) ?? 0) }

/// "Bash npm test", "Edit router.ts" — a short label for a tool call.
func toolLabel(_ name: String, _ input: Any?) -> String {
    let inp = input as? [String: Any] ?? [:]
    let keys = ["command", "cmd", "file_path", "path", "pattern", "url", "query", "description", "prompt"]
    for k in keys {
        if let v = inp[k] as? String, !v.isEmpty {
            let shown = (k == "file_path" || k == "path") ? (v as NSString).lastPathComponent : v
            return clip("\(name) \(shown)")
        }
    }
    if let s = input as? String, !s.isEmpty { return clip("\(name) \(s)") }
    return name
}

// MARK: - hooks (Claude Code and Codex share the same payload shape)

public enum HookParser {
    /// `obj` is the hook's stdin JSON plus the `_agent`, `_pid`, `_tty`, `_ts` fields our hook CLI adds.
    public static func parse(_ obj: [String: Any]) -> AgentEvent? {
        guard let name = obj["hook_event_name"] as? String,
              let sid = obj["session_id"] as? String, !sid.isEmpty else { return nil }
        let agent = AgentKind(rawValue: (obj["_agent"] as? String) ?? "claude") ?? .claude
        let kind: AgentEvent.Kind
        var detail: String?
        var question: AgentQuestion?
        switch name {
        case "SessionStart": kind = .sessionStart; detail = obj["source"] as? String
        case "UserPromptSubmit": kind = .prompt; detail = (obj["prompt"] as? String).map { clip($0) }
        case "PreToolUse":
            kind = obj["tool_name"] as? String == "AskUserQuestion" ? .question : .toolStart
            detail = toolLabel(obj["tool_name"] as? String ?? "tool", obj["tool_input"])
            if kind == .question { question = askQuestion(obj["tool_input"]) }
        case "PostToolUse": kind = .toolEnd; detail = obj["tool_name"] as? String
        case "PostToolUseFailure": kind = .toolFailed; detail = toolLabel(obj["tool_name"] as? String ?? "tool", obj["tool_input"])
        case "PermissionRequest":
            // Some builds route AskUserQuestion through a permission check; it is still a question.
            if obj["tool_name"] as? String == "AskUserQuestion" { kind = .question; question = askQuestion(obj["tool_input"]) }
            else { kind = .permission }
            detail = toolLabel(obj["tool_name"] as? String ?? "tool", obj["tool_input"])
        case "Notification":
            let t = obj["notification_type"] as? String ?? ""
            let msg = (obj["message"] as? String).map { clip($0) }
            switch t {
            case "permission_prompt": kind = .permission
            case "idle_prompt", "elicitation_dialog": kind = .question
            default:
                // Older payloads had no type; fall back to the message text.
                if let m = msg?.lowercased(), m.contains("permission") { kind = .permission }
                else if let m = msg?.lowercased(), m.contains("waiting for your input") { kind = .question }
                else { kind = .meta }
            }
            detail = msg
        case "Stop": kind = .turnEnd
        case "SessionEnd": kind = .sessionEnd; detail = obj["reason"] as? String
        case "PreCompact": kind = .meta; detail = "compacting context"
        default: kind = .meta; detail = name   // SubagentStart/Stop etc.
        }
        var ev = AgentEvent(agent: agent, sessionId: sid, kind: kind, source: .hook,
                            time: parseDate(obj["_ts"]) ?? Date())
        ev.detail = detail
        if let tool = obj["tool_name"] as? String, ["PreToolUse", "PermissionRequest"].contains(name) {
            ev.toolName = tool
            ev.ask = Summary.toolAsk(tool, obj["tool_input"])
            ev.toolFiles = WorkTask.changedFiles(tool, obj["tool_input"])
        }
        if name == "Notification", kind == .permission, let m = obj["message"] as? String { ev.ask = Summary.firstSentence(m) }
        ev.toolUseId = obj["tool_use_id"] as? String
        if name == "UserPromptSubmit", let p = obj["prompt"] as? String { ev.prompt = speechClip(p, 300) }
        ev.question = question
        if let m = obj["last_assistant_message"] as? String, !m.isEmpty { ev.message = speechClip(m) }
        ev.cwd = obj["cwd"] as? String
        ev.model = obj["model"] as? String
        ev.transcriptPath = obj["transcript_path"] as? String
        if let p = obj["_pid"] as? Int { ev.pid = Int32(p) }
        ev.tty = obj["_tty"] as? String
        return ev
    }
}

// MARK: - Claude Code transcripts (~/.claude/projects/<slug>/<session>.jsonl)

public final class ClaudeTranscriptParser {
    private var seenMessageIds = Set<String>()
    public init() {}

    public func parse(line: Substring, fallbackSession: String) -> [AgentEvent] {
        guard let o = jsonObject(line) else { return [] }
        let sid = (o["sessionId"] as? String) ?? (o["session_id"] as? String) ?? fallbackSession
        let time = parseDate(o["timestamp"]) ?? Date()
        let type = o["type"] as? String ?? ""
        func ev(_ k: AgentEvent.Kind) -> AgentEvent {
            var e = AgentEvent(agent: .claude, sessionId: sid, kind: k, source: .log, time: time)
            e.cwd = o["cwd"] as? String
            // A prompt that came in from a phone or browser marks the session as remote-driven.
            let hints = [o["promptSource"], o["turnOrigin"], (o["origin"] as? [String: Any])?["kind"]].compactMap { $0 as? String }
            e.entrypoint = hints.contains(where: SessionOrigin.looksRemote) ? "remote" : o["entrypoint"] as? String
            return e
        }
        if (o["isSidechain"] as? Bool) == true { return [] }   // subagent traffic: ignore for state
        switch type {
        case "user":
            guard let msg = o["message"] as? [String: Any] else { return [] }
            if (o["isMeta"] as? Bool) == true { return [] }
            if let text = msg["content"] as? String {
                if text.hasPrefix("<") { return [] }   // slash-command wrappers, local output
                var e = ev(.prompt); e.detail = clip(text); e.prompt = speechClip(text, 300); return [e]
            }
            var out: [AgentEvent] = []
            for part in msg["content"] as? [[String: Any]] ?? [] {
                switch part["type"] as? String {
                case "tool_result":
                    var e = ev((part["is_error"] as? Bool) == true ? .toolFailed : .toolEnd)
                    e.detail = nil; out.append(e)
                case "text":
                    if let t = part["text"] as? String, !t.hasPrefix("<") { var e = ev(.prompt); e.detail = clip(t); e.prompt = speechClip(t, 300); out.append(e) }
                default: break
                }
            }
            return out
        case "assistant":
            guard let msg = o["message"] as? [String: Any] else { return [] }
            var out: [AgentEvent] = []
            if (o["isApiErrorMessage"] as? Bool) == true {
                var e = ev(.error)
                let txt = ((msg["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "API error"
                e.detail = clip(txt); return [e]
            }
            let model = msg["model"] as? String
            // One API message is split across several lines that repeat the same usage; count it once.
            let mid = (msg["id"] as? String) ?? (o["requestId"] as? String) ?? UUID().uuidString
            if let u = msg["usage"] as? [String: Any], !seenMessageIds.contains(mid) {
                seenMessageIds.insert(mid)
                var t = TokenUsage()
                t.input = int(u["input_tokens"]); t.output = int(u["output_tokens"])
                t.cacheRead = int(u["cache_read_input_tokens"]); t.cacheWrite = int(u["cache_creation_input_tokens"])
                var e = ev(.usage); e.usage = t; e.model = model
                e.contextTokens = t.input + t.cacheRead + t.cacheWrite + t.output
                out.append(e)
            }
            for part in msg["content"] as? [[String: Any]] ?? [] {
                if part["type"] as? String == "tool_use" {
                    let asks = part["name"] as? String == "AskUserQuestion"
                    var e = ev(asks ? .question : .toolStart); e.model = model
                    let name = part["name"] as? String ?? "tool"
                    e.detail = toolLabel(name, part["input"])
                    e.toolName = name; e.ask = Summary.toolAsk(name, part["input"])
                    e.toolFiles = WorkTask.changedFiles(name, part["input"]); e.toolUseId = part["id"] as? String
                    if asks { e.question = askQuestion(part["input"]) }
                    out.append(e)
                } else if part["type"] as? String == "text", let t = part["text"] as? String,
                          !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var e = ev(.meta); e.model = model; e.message = speechClip(t); out.append(e)
                }
            }
            if out.isEmpty, model != nil { var e = ev(.meta); e.model = model; out.append(e) }
            return out
        case "system":
            switch o["subtype"] as? String {
            case "turn_duration": return [ev(.turnEnd)]
            case "informational":
                let c = o["content"] as? String ?? ""
                if c.lowercased().contains("limit") { var e = ev(.error); e.detail = clip(c); return [e] }
                return []
            case "compact_boundary": var e = ev(.meta); e.detail = "context compacted"; return [e]
            default: return []
            }
        case "ai-title":
            var e = ev(.meta); e.title = o["aiTitle"] as? String; return [e]
        case "cost-state":
            var e = ev(.meta); e.costUSD = o["totalCostUSD"] as? Double; return [e]
        default:
            return []
        }
    }
}

// MARK: - Codex rollouts (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

public final class CodexRolloutParser {
    public init() {}

    public func parse(line: Substring, fallbackSession: String) -> [AgentEvent] {
        guard let o = jsonObject(line) else { return [] }
        let time = parseDate(o["timestamp"]) ?? Date()
        let type = o["type"] as? String ?? ""
        let p = o["payload"] as? [String: Any] ?? [:]
        let sid = (type == "session_meta" ? (p["id"] as? String) ?? (p["session_id"] as? String) : nil) ?? fallbackSession
        func ev(_ k: AgentEvent.Kind) -> AgentEvent { AgentEvent(agent: .codex, sessionId: sid, kind: k, source: .log, time: time) }

        switch type {
        case "session_meta":
            var e = ev(.sessionStart); e.cwd = p["cwd"] as? String
            e.detail = p["originator"] as? String
            e.entrypoint = (p["originator"] as? String) ?? (p["source"] as? String)
            return [e]
        case "turn_context":
            var e = ev(.meta); e.model = p["model"] as? String; e.cwd = p["cwd"] as? String; return [e]
        case "response_item":
            switch p["type"] as? String {
            case "custom_tool_call", "function_call", "local_shell_call":
                var e = ev(.toolStart)
                let name = p["name"] as? String ?? "tool"
                var input: Any? = p["input"] ?? p["arguments"]
                if let s = input as? String, let j = jsonObject(s) { input = j }
                if let s = input as? String, let r = s.range(of: "cmd:\\\"") ?? s.range(of: "cmd:\"") {
                    input = String(s[r.upperBound...].prefix(80)).replacingOccurrences(of: "\\\"", with: "\"")
                }
                e.detail = name == "wait" ? nil : toolLabel(name, input)
                if name != "wait" {
                    e.toolName = name; e.ask = Summary.toolAsk(name, input)
                    e.toolFiles = WorkTask.changedFiles(name, input); e.toolUseId = p["call_id"] as? String
                }
                return [e]
            case "custom_tool_call_output", "function_call_output":
                return [ev(.toolEnd)]
            case "message" where p["role"] as? String == "assistant":
                let text = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
                var e = ev(.meta); e.message = speechClip(text); return [e]
            default: return []
            }
        case "event_msg":
            switch p["type"] as? String {
            case "task_started":
                var e = ev(.prompt); e.contextWindow = (p["model_context_window"] as? Int); return [e]
            case "user_message":
                guard let m = p["message"] as? String, !m.isEmpty else { return [] }
                var e = ev(.meta); e.prompt = speechClip(m, 300); return [e]
            case "task_complete": return [ev(.turnEnd)]
            case "turn_aborted": var e = ev(.turnEnd); e.detail = p["reason"] as? String; return [e]
            case "error", "stream_error":
                var e = ev(.error); e.detail = clip((p["message"] as? String) ?? "error"); return [e]
            case "exec_approval_request", "apply_patch_approval_request", "request_permissions":
                var e = ev(.permission); e.detail = clip((p["command"] as? [String])?.joined(separator: " ") ?? "approval")
                if let why = p["reason"] as? String, !why.isEmpty { e.ask = Summary.firstSentence(why) }
                else if let c = (p["command"] as? [String])?.joined(separator: " ") { e.ask = Summary.toolAsk("exec_command", ["cmd": c]) }
                else { e.ask = "I want to make a change that needs your OK." }
                return [e]
            case "token_count":
                var e = ev(.usage)
                if let info = p["info"] as? [String: Any] {
                    if let tot = info["total_token_usage"] as? [String: Any] {
                        var t = TokenUsage()
                        let cached = int(tot["cached_input_tokens"])
                        t.input = max(0, int(tot["input_tokens"]) - cached); t.cacheRead = cached
                        t.cacheWrite = int(tot["cache_write_input_tokens"])
                        t.output = int(tot["output_tokens"]); t.reasoning = int(tot["reasoning_output_tokens"])
                        e.usage = t
                    }
                    if let last = info["last_token_usage"] as? [String: Any] { e.contextTokens = int(last["total_tokens"]) }
                    e.contextWindow = info["model_context_window"] as? Int
                }
                if let rl = p["rate_limits"] as? [String: Any] {
                    var lims: [RateLimit] = []
                    for key in ["primary", "secondary"] {
                        guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
                        let mins = int(w["window_minutes"])
                        let name = mins >= 10080 ? "weekly" : mins >= 60 ? "\(mins / 60)h" : "\(mins)m"
                        lims.append(RateLimit(name: name, usedPercent: used, resetsAt: parseDate(w["resets_at"])))
                    }
                    e.rateLimits = lims
                    e.plan = rl["plan_type"] as? String
                    if rl["rate_limit_reached_type"] as? String != nil {
                        var x = ev(.error); x.detail = "usage limit reached"; return [e, x]
                    }
                }
                return [e]
            default: return []
            }
        default:
            return []
        }
    }

    /// rollout-2026-11-10T18-03-42-<uuid>.jsonl -> <uuid>
    public static func sessionId(fromPath path: String) -> String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return base.count >= 36 ? String(base.suffix(36)) : base
    }
}
