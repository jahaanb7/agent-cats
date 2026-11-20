import Foundation

/// Fixture-based checks for parsers, the state machine, layout and the installer merge.
enum SelfTest {
    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String) {
        if ok { passes += 1 } else { failures += 1; print("FAIL  \(name)") }
    }

    static func run() -> Bool {
        hooks(); claudeLog(); codexLog(); timing(); layout(); keys(); installer(); approvals(); visibility(); speech()
        summaries(); approvalHolding(); workHistory(); queueing(); styling()
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
        check(go(hook("PreToolUse", ["tool_name": "AskUserQuestion"])) == .question, "question tool waits for user")
        check(go(hook("PostToolUse", ["tool_name": "AskUserQuestion"])) == .thinking, "answered question resumes thinking")
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
        check(one.scale == 2.0 && three.scale == 1.5 && six.scale == 1.5, "a lone cat is shown bigger (got \(one.scale), \(three.scale))")
        check(one.width < three.width && three.width < six.width, "tree grows with each session")
        check(TreeLayout.compute(ordered: sessions(1), maxWidth: 680, preferredScale: 1.0).scale == 1.0, "small setting zooms a lone cat less")
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

    static func visibility() {
        var widget = WidgetVisibility()
        check(!widget.isExpanded, "widget starts tucked away")
        widget.update(attention: [])
        check(!widget.isExpanded, "ordinary session updates do not reveal widget")
        widget.toggle()
        check(widget.isExpanded, "pull cord opens widget")
        widget.update(attention: [])
        check(widget.isExpanded, "manual opening survives session updates")
        widget.toggle()
        check(!widget.isExpanded, "second pull tucks widget away")
        widget.update(attention: ["request-1"])
        check(widget.isExpanded, "new notification reveals widget")
        widget.hide()
        widget.update(attention: ["request-1"])
        check(!widget.isExpanded, "dismissed notification does not reopen every refresh")
        widget.update(attention: ["request-1", "request-2"])
        check(widget.isExpanded, "new request reveals room after dismissal")
        widget.update(attention: [])
        check(!widget.isExpanded, "resolved notification retracts automatic reveal")
        widget.toggle()
        widget.update(attention: ["request-3"])
        widget.update(attention: [])
        check(widget.isExpanded, "resolution keeps manually opened room visible")
        widget.hide()
        check(!widget.isExpanded, "outside click hides manually opened room")
        widget.show()
        widget.show()
        check(widget.isExpanded, "opening app reveals room even when already running")
    }

    static func approvals() {
        let store = ApprovalStore()
        let object: [String: Any] = ["_agent": "claude", "hook_event_name": "PermissionRequest",
            "_waitForDecision": true, "session_id": "S", "tool_name": "Bash", "tool_input": ["command": "echo hello"]]
        let first = HookReply()
        store.add(object, reply: first)
        check(store.requests.count == 1 && first.pending, "live permission waits for decision")
        let id = store.requests[0].id
        check(store.requests[0].input.contains("echo hello"), "approval displays complete tool input")
        check(store.resolve(id, decision: .allow), "allow accepted for live request")
        check(!store.resolve(id, decision: .deny), "duplicate/stale decision rejected")
        let response = try! JSONSerialization.data(withJSONObject: first.response()!)
        check(ApprovalProtocol.validatedResponse(response) != nil, "allow uses valid Claude response schema")
        check(!first.complete(ApprovalProtocol.response(.deny)), "completed reply cannot change decision")
        let second = HookReply()
        store.add(object, reply: second)
        check(store.resolve(store.requests[0].id, decision: .deny), "deny accepted")
        let denied = second.response()!["hookSpecificOutput"] as! [String: Any]
        check((denied["decision"] as! [String: Any])["behavior"] as? String == "deny", "deny response does not grant permission")
        let expired = HookReply(timeout: -1)
        store.add(object, reply: expired)
        check(store.requests.isEmpty && expired.response()?.isEmpty == true, "expired request falls through without decision")
        let disconnected = HookReply()
        store.add(object, reply: disconnected)
        disconnected.complete([:])
        check(store.sweep() && store.requests.isEmpty, "disconnected request removed")
        let cancelled = HookReply()
        store.add(object, reply: cancelled)
        store.cancel(session: "S")
        check(cancelled.response()?.isEmpty == true && store.requests.isEmpty, "session end releases approval to agent")
        for key in ["_agent", "_waitForDecision", "hook_event_name", "tool_name"] {
            var unsupported = object
            unsupported[key] = key == "_agent" ? "codex" : key == "tool_name" ? "AskUserQuestion" : "invalid"
            let reply = HookReply()
            store.add(unsupported, reply: reply)
            check(store.requests.isEmpty && reply.response()?.isEmpty == true, "unsupported approval rejected: " + key)
        }
        var malformed = object
        malformed["tool_input"] = "not an input object"
        let invalid = HookReply()
        store.add(malformed, reply: invalid)
        check(store.requests.isEmpty && invalid.response()?.isEmpty == true, "unreviewable input cannot be approved")
        let a = HookReply(), b = HookReply()
        store.add(object, reply: a); store.add(object, reply: b)
        let ids = store.requests.map(\.id)
        check(ids.count == 2 && ids[0] != ids[1], "parallel requests have distinct identities")
        _ = store.resolve(ids[0], decision: .handoff)
        check(a.response()?.isEmpty == true && b.pending, "handoff resolves only the selected request")
        store.cancel()
        check(!b.pending, "shutdown releases all requests")
        check(ApprovalProtocol.validatedResponse(Data("{}".utf8)) == nil, "empty response makes no decision")
        check(ApprovalProtocol.validatedResponse(Data("not-json".utf8)) == nil, "malformed response makes no decision")
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
        let permission = hooks["PermissionRequest"] as! [[String: Any]]
        let permissionHook = (permission.last!["hooks"] as! [[String: Any]])[0]
        check((permissionHook["command"] as? String)?.hasSuffix("claude --approvals") == true, "Claude permission hook opts into responses")
        check(permissionHook["timeout"] as? Int == 130, "permission timeout includes fallback margin")
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

    static func speech() {
        // AskUserQuestion: the question and its options reach the session, then clear once answered.
        let store = SessionStore()
        let first: [String: Any] = ["question": "Which database should we use?", "options": [["label": "Postgres"], ["label": "SQLite"]]]
        let ask: [String: Any] = ["questions": [first]]
        store.apply(hook("UserPromptSubmit", ["prompt": "set up storage"])!)
        store.apply(hook("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": ask])!)
        var s = store.sessions["S1"]!
        check(s.question == AgentQuestion(text: "Which database should we use?", options: ["Postgres", "SQLite"]), "AskUserQuestion parsed (got \(String(describing: s.question)))")
        var sp = Speech.make(s, hookPending: false)
        check(sp.mood == .question && sp.choices.map(\.label) == ["Postgres", "SQLite"], "question bubble offers the options")
        check(sp.choices.first?.reply == .keys([.text("1")]) && sp.choices.last?.reply == .keys([.text("2")]), "option N types N")
        check(sp.steps(forText: "MySQL\nplease") == [.text("3"), .pause, .text("MySQL please"), .pause, .returnKey], "free text picks 'type something' then types one line")
        var multi = s; multi.question?.more = 1
        check(Speech.make(multi, hookPending: false).choices.map(\.reply) == [.openTerminal], "multi-question prompts go to the terminal")
        multi = s; multi.question?.multiSelect = true
        check(Speech.make(multi, hookPending: false).textReply == nil, "multi-select goes to the terminal")
        var none = s; none.question?.options = []
        check(Speech.make(none, hookPending: false).choices.map(\.reply) == [.openTerminal], "question without options goes to the terminal")
        var many = s; many.question?.options = (1...10).map { "o\($0)" }
        check(Speech.make(many, hookPending: false).choices.map(\.reply) == [.openTerminal], "more than 9 options goes to the terminal")
        check(Speech.make(s, hookPending: false, canType: false, appName: "Cursor").choices.map(\.label) == ["Answer in Cursor"], "untypeable app offers the jump only")
        let routed = hook("PermissionRequest", ["tool_name": "AskUserQuestion", "tool_input": ask])!
        check(routed.kind == .question && routed.question?.options == ["Postgres", "SQLite"], "AskUserQuestion permission check stays a question")
        store.apply(hook("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])!)
        check(store.sessions["S1"]!.question != nil, "waiting notification keeps the open question")
        store.apply(hook("PostToolUse", ["tool_name": "AskUserQuestion"])!)
        check(store.sessions["S1"]!.question == nil, "answered question clears")

        // Permission: hook waiting -> hook buttons; otherwise keys. Deny text reaches the agent.
        store.apply(hook("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])!)
        s = store.sessions["S1"]!
        sp = Speech.make(s, hookPending: true)
        check(sp.choices.map(\.reply) == [.hook(allow: true), .hook(allow: false), .handoff] && sp.textReply == .hookDeny, "hook permission bubble: Allow, Deny, In terminal, and a chat box")
        check(Speech.make(s, hookPending: false).choices.map(\.reply) == [.keys([.text("1")]), .keys([.escape])], "terminal permission keys")
        check(sp.choices.map(\.primary) == [false, true, false], "destructive command makes Deny the default")
        check(Speech.make(s, hookPending: true, canType: false).choices.count == 3, "hook answers work even without a terminal")
        let deny = ApprovalProtocol.response(.deny, message: "use make clean\u{7}")
        let back = ApprovalProtocol.validatedResponse(try! JSONSerialization.data(withJSONObject: deny))
        let msg = ((((back.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["message"] as? String)
        check(msg == "The user declined in Agent Cats and said: use make clean", "deny message survives the hook, cleaned (got \(msg ?? "nil"))")
        check(ApprovalProtocol.response(.deny).description.contains("Denied by the user"), "plain deny unchanged")

        // Finished turn: the agent's last words, with quick Yes/No when it ended on a question.
        let p = ClaudeTranscriptParser()
        for e in p.parse(line: #"{"type":"assistant","sessionId":"S1","message":{"id":"z9","model":"m","content":[{"type":"text","text":"Tests pass. Want me to open a PR?"}]}}"#, fallbackSession: "S1") { store.apply(e) }
        store.apply(hook("Stop")!)
        s = store.sessions["S1"]!
        sp = Speech.make(s, hookPending: false)
        check(sp.mood == .question && sp.needsAnswer && sp.text == "Want me to open a PR?", "a turn ending on a question asks you just the question (got \(sp.mood), \(sp.text))")
        check(sp.choices.map(\.label) == ["Yes", "No"], "yes/no offered for a trailing question")
        check(s.wantsYou && !s.state.needsAttention, "trailing question wants you without changing state")
        store.tick(now: s.stateSince.addingTimeInterval(300)) { _ in true }
        check(store.sessions["S1"]!.state == .done, "a question left on the table doesn't doze off")
        check(Session.endsWithQuestion("Shall I **ship it?**\n") && !Session.endsWithQuestion("Shipped. Done."), "trailing-question detection")
        check(sp.steps(forText: "  ") == nil, "blank reply sends nothing")
        store.apply(hook("UserPromptSubmit", ["prompt": "yes"])!)
        check(store.sessions["S1"]!.lastMessage == nil, "new prompt clears the old reply")
        check(Speech.typeable("a\u{1b}[2Jb\r\nc") == "a[2Jb c", "escape sequences can't be typed")
        let attached = Speech.withFiles("look at this", paths: ["/Users/me/Shot 1 (2).png", "/tmp/a.txt"])
        check(attached == #"look at this /Users/me/Shot\ 1\ \(2\).png /tmp/a.txt"#, "attachments go out as escaped paths (got \(attached))")
        check(Speech.withFiles("", paths: ["/tmp/x.png"]) == "/tmp/x.png", "a file alone is a valid reply")
        check(Speech(mood: .question, headline: "", text: "", choices: [], textReply: .keys(prefix: []), placeholder: "", token: "t")
                .steps(forText: attached)?.contains(.text(attached)) == true, "escaped paths survive typing cleanup")

        // Where a session runs.
        check(SessionOrigin.classify(entrypoint: "cli", hasTTY: true, hostBundleID: "com.googlecode.iterm2", hostName: "iTerm2") == .terminal("iTerm"), "iTerm session is a terminal one")
        check(SessionOrigin.classify(entrypoint: "sdk-cli", hasTTY: true, hostBundleID: "com.apple.Terminal", hostName: nil) == .background, "scripted run is background")
        check(SessionOrigin.classify(entrypoint: "cli", hasTTY: false, hostBundleID: "com.todesktop.230313mzl4w4u92", hostName: "Cursor") == .editor("Cursor"), "Cursor session is an editor one")
        check(SessionOrigin.classify(entrypoint: "codex_vscode", hasTTY: false, hostBundleID: nil, hostName: nil) == .editor("VS Code"), "Codex VS Code originator")
        check(SessionOrigin.classify(entrypoint: "remote", hasTTY: true, hostBundleID: "com.apple.Terminal", hostName: nil) == .remote, "remote-driven session")
        check(SessionOrigin.classify(entrypoint: nil, hasTTY: false, hostBundleID: nil, hostName: nil) == nil, "unknown origin stays unknown")
        let remoteLine = #"{"type":"user","sessionId":"R1","entrypoint":"cli","promptSource":"remote_control","message":{"role":"user","content":"hi"}}"#
        check(ClaudeTranscriptParser().parse(line: Substring(remoteLine), fallbackSession: "R1").first?.entrypoint == "remote", "a prompt from a phone or browser marks the session remote")

        // Codex assistant text.
        let cp = CodexRolloutParser()
        let ce = cp.parse(line: #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#, fallbackSession: "C9")
        check(ce.first?.message == "Done.", "codex assistant message")
    }

    static func summaries() {
        check(Summary.toolAsk("Bash", ["command": "npm test", "description": "Run the test suite"]) == "I want to run the test suite.", "bash uses Claude's own description")
        check(Summary.toolAsk("Bash", ["command": "git push origin main"]) == "I want to run git push.", "bash without description gets a gist (got \(Summary.toolAsk("Bash", ["command": "git push origin main"])))")
        check(Summary.toolAsk("Bash", ["command": "rm -rf build"]) == "I want to delete build.", "rm gist")
        check(Summary.toolAsk("Edit", ["file_path": "/a/b/Models.swift"]) == "I want to edit Models.swift.", "edit summary")
        check(Summary.toolAsk("WebFetch", ["url": "https://docs.example.com/x"]) == "I want to open a page on docs.example.com.", "fetch summary")
        check(Summary.toolAsk("mcp__github__create_issue", [:]).contains("create issue"), "mcp summary")
        let reply = "## Summary\n\nDone.\n\nI fixed the flaky login test by waiting for the token. Also bumped the timeout.\n\n- `Auth.swift`: retry\n\nWant me to open a PR?"
        check(Summary.firstSentence(reply) == "I fixed the flaky login test by waiting for the token.", "first useful sentence, markdown stripped (got \(Summary.firstSentence(reply)))")
        check(Summary.ask(reply) == "Want me to open a PR?", "ask picks the question")
        check(Summary.askFromLabel("Bash rm -rf build && make") == "I want to delete build.", "label fallback (got \(Summary.askFromLabel("Bash rm -rf build && make")))")
        check(Summary.askFromLabel("Edit Models.swift") == "I want to edit Models.swift.", "label fallback for edits")
        check(Summary.firstSentence("Updated v1.2 in file.swift today. Next.") == "Updated v1.2 in file.swift today.", "dots inside words don't split")
    }

    /// The bug: a parallel tool call or a subagent's tool events in the same session used to cancel a
    /// waiting approval and knock the cat out of "asking", so Allow went nowhere.
    static func styling() {
        let dir = NSTemporaryDirectory() + "agentcats-style-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let style = CatStyle(file: dir + "/styles.json")
        check(style.accessory(for: "Miso") == nil, "no accessory by default")
        style.set("crown", for: "Miso")
        check(CatStyle(file: dir + "/styles.json").accessory(for: "Miso") == "crown", "accessory is saved between launches")
        style.set("nonsense", for: "Miso")
        check(style.accessory(for: "Miso") == nil, "unknown accessory is ignored")
        let roster = CatRoster(file: dir + "/cats.json")
        var s = Session(id: "x", agent: .claude, at: Date()); s.cwd = "/p/demo"
        roster.setCat("Oreo", for: s)
        check(CatRoster(file: dir + "/cats.json").cat(for: s, taken: []) == "Oreo", "chosen cat is kept for the project")
        check(CatRoster(file: dir + "/cats.json").cat(for: s, taken: ["Oreo"]) != "Oreo", "chosen cat yields when already taken")
    }

    static func approvalHolding() {
        let m = Monitor()
        m.acceptsApprovals = true
        let req: [String: Any] = ["_agent": "claude", "hook_event_name": "PermissionRequest", "_waitForDecision": true,
                                  "session_id": "P1", "cwd": "/tmp/p", "tool_name": "Bash",
                                  "tool_input": ["command": "make deploy", "description": "Deploy the site"]]
        m.queue.sync {
            m.ingestHook(req)
            let reply = HookReply()
            m.approvals.add(req, reply: reply)
            m.syncApproval("P1")
            var s = m.store.sessions["P1"]!
            check(s.state == .permission && s.awaitingApproval && s.ask == "I want to deploy the site.", "approval sets ask (got \(s.ask ?? "nil"))")
            let token = Speech.token(s)
            // A parallel Read runs and finishes while we wait.
            m.ingestHook(["_agent": "claude", "hook_event_name": "PreToolUse", "session_id": "P1", "tool_name": "Read", "tool_input": ["file_path": "/tmp/p/a"]])
            m.ingestHook(["_agent": "claude", "hook_event_name": "PostToolUse", "session_id": "P1", "tool_name": "Read", "tool_input": ["file_path": "/tmp/p/a"]])
            s = m.store.sessions["P1"]!
            check(reply.pending && m.approvals.requests.count == 1, "other tool calls don't cancel the waiting approval")
            check(s.state == .permission && Speech.token(s) == token, "cat keeps asking through parallel tool traffic")
            check(Speech.make(s, hookPending: true).text == "I want to deploy the site.", "bubble says the summary")
            let id = m.approvals.requests[0].id
            check(m.resolveApproval(id, decision: .allow), "allow reaches the waiting hook")
            s = m.store.sessions["P1"]!
            check(s.state == .working && !s.awaitingApproval, "allowed request moves on")
            let out = reply.response()?["hookSpecificOutput"] as? [String: Any]
            check((out?["decision"] as? [String: Any])?["behavior"] as? String == "allow", "hook got allow")

            // Answered in the terminal: the same tool finishing releases it.
            let r2 = HookReply()
            m.ingestHook(req); m.approvals.add(req, reply: r2); m.syncApproval("P1")
            m.ingestHook(["_agent": "claude", "hook_event_name": "PostToolUse", "session_id": "P1", "tool_name": "Bash",
                          "tool_input": ["command": "make deploy", "description": "Deploy the site"]])
            check(!r2.pending && m.approvals.requests.isEmpty && !m.store.sessions["P1"]!.awaitingApproval, "matching tool end releases the request")
        }
    }

    static func workHistory() {
        let store = SessionStore()
        store.apply(hook("UserPromptSubmit", ["prompt": "fix the login bug"])!)
        store.apply(hook("PreToolUse", ["tool_name": "Edit", "tool_use_id": "t1", "tool_input": ["file_path": "/x/Auth.swift"]])!)
        store.apply(hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t2", "tool_input": ["command": "swift test", "description": "Run the tests"]])!)
        // The transcript sees the same calls; they count once.
        let p = ClaudeTranscriptParser()
        for e in p.parse(line: #"{"type":"assistant","sessionId":"S1","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/x/Auth.swift"}},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"swift test"}}]}}"#, fallbackSession: "S1") { store.apply(e) }
        store.apply(hook("Stop", ["last_assistant_message": "Fixed the login bug by refreshing the token first. All tests pass."])!)
        let t = store.sessions["S1"]!.tasks
        check(t.count == 1 && t[0].prompt == "fix the login bug", "task recorded with prompt")
        check(t[0].files == ["Auth.swift"] && t[0].commands == 1 && t[0].steps == ["run the tests"], "work counted once (got \(t[0].files) \(t[0].commands) \(t[0].steps))")
        check(t[0].outcome == "Fixed the login bug by refreshing the token first. All tests pass.", "outcome summary (got \(t[0].outcome ?? "nil"))")
        check(t[0].endedAt != nil && t[0].tally == "changed 1 file · ran 1 command", "tally (got \(t[0].tally))")
        store.apply(hook("UserPromptSubmit", ["prompt": "now add a test"])!)
        check(store.sessions["S1"]!.tasks.count == 2, "next prompt starts a new task")
    }

    static func queueing() {
        // A busy cat sums up what it's on, and queues what you type.
        var s = Session(id: "Q1", agent: .claude, at: Date())
        s.state = .working; s.ask = "I want to run the test suite."; s.activity = "Bash npm test"
        var task = WorkTask(prompt: "build the new checkout page\nand make it fast", startedAt: Date())
        task.files = ["Checkout.tsx", "cart.ts"]; task.commands = 3
        s.tasks = [task]
        var sp = Speech.make(s, hookPending: false)
        check(sp.text == "Working on \u{201C}build the new checkout page and make it fast\u{201D}. I\u{2019}m going to run the test suite.",
              "working summary: request and current step (got \(sp.text))")
        check(sp.detail == "changed 2 files · ran 3 commands", "working tally as small print (got \(sp.detail ?? "nil"))")
        check(sp.headline == "Working on it" && sp.textReply == .queue, "working bubble queues what you type")
        check(sp.steps(forText: "hi") == nil, "queued text is never typed straight away")
        check(Speech.make(s, hookPending: false, canType: false).textReply == nil, "no queue when the terminal can't be typed into")
        s.state = .thinking
        check(Speech.make(s, hookPending: false).text.hasSuffix("Thinking about the next step."), "thinking summary")
        s.tasks = []; s.state = .working; s.ask = nil
        sp = Speech.make(s, hookPending: false)
        check(sp.text == "Busy with Bash npm test." && sp.detail == "Bash npm test", "working without a task falls back to the activity (got \(sp.text))")

        // The queue: in order, one delivery per turn end, never mid-turn or over a question.
        var q = MessageQueue()
        let m1 = q.add("first  thing\n", to: "Q1")!, m2 = q.add("second", to: "Q1")!
        check(q.add("   ", to: "Q1") == nil, "empty messages aren't queued")
        check(q.list("Q1").map(\.text) == ["first  thing", "second"] && m1.id != m2.id, "queue keeps order, text made typeable")
        check(q.counts == ["Q1": 2], "queued counts")
        s.state = .working
        check(q.next(for: s) == nil, "nothing is sent while it works")
        for st in [CatState.thinking, .permission, .question, .error, .gone] {
            s.state = st; check(q.next(for: s) == nil, "nothing is sent while \(st)")
        }
        s.state = .done; s.lastMessage = "Tests pass. Want me to open a PR?"; s.stateSince = Date()
        check(q.next(for: s) == nil, "a question holds the queue until you answer")
        s.lastMessage = "All done."
        check(q.next(for: s) == m1, "turn end sends the first message")
        q.markAttempt(s)
        check(q.next(for: s) == nil, "one attempt per turn end")
        q.allowRetry("Q1")
        check(q.next(for: s) == m1, "Send now retries the same turn end")
        q.markAttempt(s); q.remove(m1.id, from: "Q1")
        check(q.next(for: s) == nil, "the next message waits for the next turn")
        s.state = .working; s.stateSince = Date().addingTimeInterval(1)
        s.state = .idle; s.stateSince = Date().addingTimeInterval(2)
        check(q.next(for: s) == m2, "next turn end sends the next message")
        q.remove(m2.id, from: "Q1")
        check(q.counts.isEmpty && q.list("Q1").isEmpty, "empty after delivery")
        _ = q.add("x", to: "gone"); q.prune(keeping: ["Q1"])
        check(q.list("gone").isEmpty, "queues of ended sessions are dropped")
        for i in 0..<MessageQueue.limit { _ = q.add("m\(i)", to: "Q1") }
        check(q.add("one too many", to: "Q1") == nil, "queue is capped")
    }
}
