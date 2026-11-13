import Foundation

/// Fixture-based checks for parsers, the state machine, layout and the installer merge.
enum SelfTest {
    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String) {
        if ok { passes += 1 } else { failures += 1; print("FAIL  \(name)") }
    }

    static func run() -> Bool {
        hooks(); claudeLog(); codexLog(); timing(); layout(); keys(); installer()
        print("\(passes) passed, \(failures) failed")
        return failures == 0
    }

    static func hook(_ name: String, _ extra: [String: Any] = [:], agent: String = "claude", sid: String = "S1") -> AgentEvent? {
        var o: [String: Any] = ["hook_event_name": name, "session_id": sid, "cwd": "/tmp/proj", "_agent": agent, "_pid": 4242, "_tty": "ttys009"]
        for (k, v) in extra { o[k] = v }
        return HookParser.parse(o)
    }

    static func hooks() {
        let store = SessionStore()
        func go(_ e: AgentEvent?) -> CatState { store.apply(e!); return store.sessions["S1"]!.state }
        check(go(hook("SessionStart", ["source": "startup"])) == .idle, "hook SessionStart -> idle")
        check(store.sessions["S1"]!.pid == 4242 && store.sessions["S1"]!.tty == "ttys009", "hook carries pid/tty")
        check(go(hook("UserPromptSubmit", ["prompt": "fix the tests"])) == .thinking, "prompt -> thinking")
        check(go(hook("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "npm test"]])) == .working, "PreToolUse -> working")
        check(store.sessions["S1"]!.activity == "Bash npm test", "tool label")
        check(go(hook("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])) == .permission, "PermissionRequest -> permission")
        check(store.sessions["S1"]!.state.needsAttention, "permission needs attention")
        check(go(hook("PostToolUse", ["tool_name": "Bash"])) == .thinking, "PostToolUse -> thinking")
        check(go(hook("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])) == .question, "idle_prompt -> question")
        check(go(hook("Stop")) == .done, "Stop -> done")
        check(go(hook("SessionEnd", ["reason": "exit"])) == .gone, "SessionEnd -> gone")
        let cx = hook("PreToolUse", ["tool_name": "exec_command", "tool_input": ["cmd": "pytest -q"], "model": "gpt-6-astra"], agent: "codex", sid: "C1")!
        check(cx.agent == .codex && cx.model == "gpt-6-astra" && cx.detail == "exec_command pytest -q", "codex hook payload")
        check(HookParser.parse(["hook_event_name": "Stop"]) == nil, "hook without session id ignored")
    }

    static func claudeLog() {
        let p = ClaudeTranscriptParser()
        let store = SessionStore()
        let lines = [
            #"{"type":"user","sessionId":"A","cwd":"/x/Orion","timestamp":"2026-11-12T10:00:00.000Z","message":{"role":"user","content":"add a login page"}}"#,
            #"{"type":"assistant","sessionId":"A","cwd":"/x/Orion","timestamp":"2026-11-12T10:00:02.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"thinking"}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100}}}"#,
            #"{"type":"assistant","sessionId":"A","cwd":"/x/Orion","timestamp":"2026-11-12T10:00:03.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/x/Orion/src/login.ts"}}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100}}}"#,
            #"{"type":"user","sessionId":"A","timestamp":"2026-11-12T10:00:04.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
            #"{"type":"assistant","sessionId":"A","isSidechain":true,"timestamp":"2026-11-12T10:00:05.000Z","message":{"id":"m2","model":"claude-haiku-5-5","content":[],"usage":{"input_tokens":999999,"output_tokens":1}}}"#,
            #"{"type":"ai-title","aiTitle":"Login page","sessionId":"A"}"#,
            #"{"type":"cost-state","sessionId":"A","totalCostUSD":1.25}"#,
            #"{"type":"system","subtype":"turn_duration","sessionId":"A","timestamp":"2026-11-12T10:00:09.000Z","durationMs":9000}"#
        ]
        var states: [CatState] = []
        for l in lines { for e in p.parse(line: Substring(l), fallbackSession: "A") { store.apply(e) }; if let s = store.sessions["A"] { states.append(s.state) } }
        let s = store.sessions["A"]!
        check(states.prefix(4) == [.thinking, .thinking, .working, .thinking], "claude log states \(states)")
        check(s.state == .done, "turn_duration -> done")
        check(s.usage.cacheRead == 1000 && s.usage.output == 20, "usage counted once per message id (got \(s.usage))")
        check(s.model == "claude-opus-5-5", "model from main thread, not sidechain")
        check(s.title == "Login page" && s.costUSD == 1.25, "title and agent-reported cost")
        check(s.activity == "Edit login.ts", "claude tool label uses file name")
        check(s.contextTokens == 1130, "context tokens = prompt + output of last message")
        check(s.project == "Orion", "project from cwd")
    }

    static func codexLog() {
        let p = CodexRolloutParser()
        let store = SessionStore()
        let lines = [
            #"{"timestamp":"2026-11-12T10:00:00.000Z","type":"session_meta","payload":{"id":"C9","cwd":"/x/Radio","originator":"codex-tui"}}"#,
            #"{"timestamp":"2026-11-12T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-6-astra","cwd":"/x/Radio"}}"#,
            #"{"timestamp":"2026-11-12T10:00:01.500Z","type":"event_msg","payload":{"type":"task_started","model_context_window":258400}}"#,
            #"{"timestamp":"2026-11-12T10:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":\"pytest -q\"}"}}"#,
            #"{"timestamp":"2026-11-12T10:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":19042,"cached_input_tokens":12032,"output_tokens":51,"reasoning_output_tokens":0,"total_tokens":19093},"last_token_usage":{"total_tokens":19093},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":13.0,"window_minutes":300,"resets_at":1794367616},"secondary":{"used_percent":65.0,"window_minutes":10080,"resets_at":1794459192},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-11-12T10:00:04.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#
        ]
        var states: [CatState] = []
        for l in lines { for e in p.parse(line: Substring(l), fallbackSession: "C9") { store.apply(e) }; states.append(store.sessions["C9"]!.state) }
        let s = store.sessions["C9"]!
        check(states == [.idle, .idle, .thinking, .working, .working, .done], "codex states \(states)")
        check(s.model == "gpt-6-astra" && s.project == "Radio", "codex model + project")
        check(s.usage.cacheRead == 12032 && s.usage.input == 7010, "codex usage split (got \(s.usage))")
        check(s.contextWindow == 258400 && s.contextTokens == 19093, "codex context")
        check(s.rateLimits.map(\.name) == ["5h", "weekly"] && s.rateLimits.last?.usedPercent == 65, "codex rate limits")
        check(s.plan == "plus", "codex plan")
        check(CodexRolloutParser.sessionId(fromPath: "/a/rollout-2026-11-10T18-03-42-01a1c7b3-f64b-75e0-92fc-886b127e988b.jsonl") == "01a1c7b3-f64b-75e0-92fc-886b127e988b", "session id from rollout file name")
    }

    static func timing() {
        let store = SessionStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var e = hook("Stop")!; e.time = t0
        store.apply(e)
        store.tick(now: t0.addingTimeInterval(10)) { _ in true }
        check(store.sessions["S1"]!.state == .done, "done holds briefly")
        store.tick(now: t0.addingTimeInterval(60)) { _ in true }
        check(store.sessions["S1"]!.state == .idle, "done -> idle after 45s")
        store.tick(now: t0.addingTimeInterval(61)) { _ in false }
        check(store.sessions["S1"]!.state == .gone, "dead process -> gone")
        store.tick(now: t0.addingTimeInterval(400)) { _ in false }
        check(store.sessions["S1"] == nil, "gone cat leaves the tree")
        // With hooks, log lines don't override state.
        let s2 = SessionStore()
        s2.apply(hook("PermissionRequest", ["tool_name": "Bash"])!)
        var logLine = AgentEvent(agent: .claude, sessionId: "S1", kind: .toolStart, source: .log); logLine.detail = "Bash x"
        s2.apply(logLine)
        check(s2.sessions["S1"]!.state == .permission, "hook state wins over log replay")
    }

    static func layout() {
        func sessions(_ n: Int, attention: Set<Int> = []) -> [Session] {
            (0..<n).map { i in
                var s = Session(id: "s\(i)", agent: .claude, at: Date(timeIntervalSince1970: Double(i)))
                s.state = attention.contains(i) ? .permission : .working
                return s
            }
        }
        let store = SessionStore()
        func ordered(_ ss: [Session]) -> [Session] {
            ss.sorted { ($0.state.needsAttention ? 0 : 1, $0.startedAt) < ($1.state.needsAttention ? 0 : 1, $1.startedAt) }
        }
        _ = store
        let e = TreeLayout.compute(ordered: [], maxWidth: 680)
        check(e.empty && e.width < 60, "no sessions: just a small post")
        let one = TreeLayout.compute(ordered: sessions(1), maxWidth: 680)
        let three = TreeLayout.compute(ordered: sessions(3), maxWidth: 680)
        let six = TreeLayout.compute(ordered: sessions(6), maxWidth: 680)
        check(one.scale == 1.5 && one.width < three.width && three.width < six.width, "tree grows with each session")
        check(six.scale == 1.5 && six.slots.count == 6 && six.width <= 680, "6 cats fit at full size")
        let many = TreeLayout.compute(ordered: sessions(30), maxWidth: 680)
        check(many.scale == 1.0 && many.width <= 680 && many.basket.isEmpty == false, "many cats: shrink to 1pt, overflow to basket (scale \(many.scale), basket \(many.basket.count))")
        check(many.slots.count + many.basket.count == 30, "no session lost")
        let mid = TreeLayout.compute(ordered: sessions(18), maxWidth: 680)
        check(mid.scale == 1.0 && mid.basket.isEmpty && mid.width <= 680, "18 cats: shrink to 1pt, all visible")
        let urgent = TreeLayout.compute(ordered: ordered(sessions(30, attention: [29, 28])), maxWidth: 300)
        check(Set(urgent.slots.map(\.sessionId)).isSuperset(of: ["s29", "s28"]), "cats that need you are never in the basket")
        check(urgent.width <= 300 || urgent.scale == 0.5, "tight budget respected")
        let tiny = TreeLayout.compute(ordered: sessions(4), maxWidth: 680, preferredScale: 1.0)
        check(tiny.scale == 1.0, "preferred size honoured")
        // Perch heights stay put when a cat joins on the left.
        let a = TreeLayout.compute(ordered: sessions(2), maxWidth: 680).slots.map(\.highPerch)
        let b = TreeLayout.compute(ordered: sessions(3), maxWidth: 680).slots.map(\.highPerch)
        check(Array(b.suffix(2)) == a, "existing perches keep their height when the tree grows")
        check(six.slots.allSatisfy { $0.x >= 0 && $0.x + TreeLayout.slotW * six.scale <= six.postX + 0.001 }, "slots sit left of the post without overlap")
        let xs = six.slots.map(\.x)
        check(zip(xs, xs.dropFirst()).allSatisfy { $1 - $0 >= TreeLayout.slotW * six.scale - 0.001 }, "slots never overlap")
    }

    static func keys() {
        check(Monitor.claudeKey(cwd: "/Users/juhi/Claude") == "-Users-juhi-Claude", "claude project slug")
        check(Monitor.claudeKey(cwd: "/Users/j/My App.v2") == "-Users-j-My-App-v2", "slug replaces spaces and dots")
        check(Monitor.claudeKey(transcript: "/h/.claude/projects/-Users-juhi-Claude/abc.jsonl") == "-Users-juhi-Claude", "slug from transcript path")
    }

    static func installer() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/x/gstack/timeline-stop-hook", "timeout": 5]]]]]
        ]
        let cmd = "\"/opt/agentcats-hook\" claude"
        let added = HookInstaller.merged(existing, events: HookInstaller.claudeEvents, command: cmd, remove: false)
        let hooks = added["hooks"] as? [String: Any] ?? [:]
        let stop = hooks["Stop"] as? [[String: Any]] ?? []
        check(stop.count == 2, "gstack Stop hook kept, ours added")
        check(hooks.keys.count == HookInstaller.claudeEvents.count, "all events registered")
        check(added["model"] as? String == "opus", "unrelated settings untouched")
        let again = HookInstaller.merged(added, events: HookInstaller.claudeEvents, command: cmd, remove: false)
        check(HookInstaller.render(again) == HookInstaller.render(added), "install is idempotent")
        let removed = HookInstaller.merged(added, events: HookInstaller.claudeEvents, command: nil, remove: true)
        check(HookInstaller.render(removed) == HookInstaller.render(existing), "uninstall restores the original content")

        // In-place editing keeps every other byte of the user's file.
        let original = "{\n  \"permissions\": {\"allow\": [\"Bash(x)\"]},\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"/x/gstack\", \"timeout\": 5}]}]\n  },\n  \"zeta\": 1\n}\n"
        let doc = jsonObject(original)!
        let withOurs = HookInstaller.merged(doc, events: HookInstaller.claudeEvents, command: cmd, remove: false)
        let edited = HookInstaller.replacingHooks(in: original, with: withOurs["hooks"] as? [String: Any])
        check(edited.hasPrefix("{\n  \"permissions\": {\"allow\": [\"Bash(x)\"]},\n  \"model\": \"opus\",\n  \"hooks\": {"), "keys before hooks untouched")
        check(edited.hasSuffix("  },\n  \"zeta\": 1\n}\n"), "keys after hooks untouched")
        check(jsonObject(edited) != nil, "edited file is valid JSON")
        let back = HookInstaller.merged(jsonObject(edited)!, events: HookInstaller.claudeEvents, command: nil, remove: true)
        let restored = HookInstaller.replacingHooks(in: edited, with: back["hooks"] as? [String: Any])
        check(HookInstaller.normalized(restored) == HookInstaller.normalized(original), "round trip restores content")
        let noHooks = "{\n  \"model\": \"opus\"\n}\n"
        let added2 = HookInstaller.replacingHooks(in: noHooks, with: ["Stop": [["hooks": [["type": "command", "command": cmd]]]]])
        check(jsonObject(added2) != nil && added2.hasPrefix("{\n  \"model\": \"opus\",\n  \"hooks\": {"), "hooks appended when absent")
        let removedOnly = HookInstaller.replacingHooks(in: added2, with: nil)
        check(removedOnly == noHooks, "removing our only hooks restores the file exactly (got \(removedOnly.debugDescription))")
    }
}
