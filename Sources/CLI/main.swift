// agentcats: Phase 1 developer CLI.
//   agentcats watch [--width PT] [--no-listen]   live view of every session + the tree layout
//   agentcats sessions [--json]                   one-shot snapshot
//   agentcats layout [--width PT]                 how the cat tree would size right now
//   agentcats hooks plan|install --yes|uninstall --yes
//   agentcats selftest
import Darwin
import Foundation

setvbuf(stdout, nil, _IOFBF, 1 << 16)
var args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "watch"
func flag(_ name: String) -> Bool { args.contains(name) }
func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().path
let hookBinary = exeDir + "/agentcats-hook"

// Default tree budget: 45% of a 1512pt-wide MacBook screen. The app uses the real screen width.
let maxWidth = Double(value("--width") ?? "") ?? 680

// MARK: rendering

let esc = "\u{1B}["
func color(_ s: CatState) -> String {
    switch s {
    case .permission: return "38;5;208"
    case .question: return "38;5;220"
    case .error: return "38;5;196"
    case .working: return "38;5;116"
    case .thinking: return "38;5;252"
    case .done: return "38;5;228"
    case .idle: return "38;5;110"
    case .gone: return "38;5;240"
    }
}
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n - 1)) + " " : s + String(repeating: " ", count: n - s.count)
}
func compact(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.2fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fK", Double(n) / 1e3) : "\(n)"
}
func age(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    return s >= 3600 ? "\(s / 3600)h\(s % 3600 / 60)m" : s >= 60 ? "\(s / 60)m\(s % 60)s" : "\(s)s"
}

func render(_ mon: Monitor, live: Bool) -> String {
    let snap = mon.snapshot()
    let layout = TreeLayout.compute(ordered: snap.map(\.session), maxWidth: maxWidth)
    var o = ""
    let needs = snap.filter { $0.session.state.needsAttention }.count
    o += "\(esc)1mAGENT CATS\(esc)0m  \(snap.count) session\(snap.count == 1 ? "" : "s")"
    o += needs > 0 ? "  \(esc)38;5;208m\(needs) need you\(esc)0m" : "  nothing needs you (tree fades)"
    o += "   hook events: \(mon.hookEventsReceived)\n"
    if layout.empty {
        o += "tree: empty post \(Int(layout.width))×\(Int(layout.height))pt\n\n"
    } else {
        o += "tree: \(layout.slots.count) cat\(layout.slots.count == 1 ? "" : "s") at \(layout.scale)pt/px → \(Int(layout.width))×\(Int(layout.height))pt"
        o += " (budget \(Int(maxWidth))pt)"
        if !layout.basket.isEmpty { o += ", +\(layout.basket.count) asleep in the basket" }
        o += "\n"
        // Mini map of perch order, left (front) to right (post).
        let byId = Dictionary(uniqueKeysWithValues: snap.map { ($0.session.id, $0) })
        var map = "      "
        if !layout.basket.isEmpty { map += "[+\(layout.basket.count)] " }
        for sl in layout.slots {
            if let x = byId[sl.sessionId] { map += "\(esc)\(color(x.session.state))m\(sl.highPerch ? "▀" : "▄")\(x.cat)\(esc)0m " }
        }
        o += map + "┃post\n\n"
    }
    o += "\(esc)2m" + pad("CAT", 11) + pad("STATE", 11) + pad("AGENT", 7) + pad("PROJECT", 16) + pad("MODEL", 18)
       + pad("TOKENS", 9) + pad("CACHE", 6) + pad("CTX", 6) + pad("COST*", 8) + pad("IN STATE", 9) + pad("TTY", 9) + "SRC\(esc)0m\n"
    for (s, cat) in snap {
        let ctx = s.contextPercent.map { String(format: "%.0f%%", $0) } ?? "–"
        let cache = s.usage.cacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "–"
        let cost = s.costUSD.map { String(format: "$%.2f", $0) } ?? "–"
        o += pad(cat, 11) + "\(esc)\(color(s.state))m" + pad(s.state.rawValue, 11) + "\(esc)0m"
        o += pad(s.agent.rawValue, 7) + pad(s.project, 16) + pad(s.model ?? "–", 18)
        o += pad(s.usage.total > 0 ? compact(s.usage.total) : "–", 9) + pad(cache, 6) + pad(ctx, 6) + pad(cost, 8)
        o += pad(age(s.stateSince), 9) + pad(s.tty ?? (s.pid.map { "pid \($0)" } ?? "–"), 9)
        o += s.hookSeen ? "hook" : (s.pid != nil ? "log+pid" : "log")
        o += "\n"
        var line2 = "           "
        if let t = s.title { line2 += "\(esc)1m\(t)\(esc)0m  " }
        if let a = s.activity { line2 += "\(esc)2m\(a)\(esc)0m" }
        if line2.trimmingCharacters(in: .whitespaces).count > 0 { o += line2 + "\n" }
        if !s.rateLimits.isEmpty {
            o += "           limits: " + s.rateLimits.map { l in
                "\(l.name) \(Int(l.usedPercent))%" + (l.resetsAt.map { " (resets in \(age2($0)))" } ?? "")
            }.joined(separator: "  ") + (s.plan.map { "  plan: \($0)" } ?? "") + "\n"
        }
    }
    if snap.isEmpty { o += "\(esc)2m(no active sessions in the last \(Int(mon.lookback / 3600))h)\(esc)0m\n" }
    if live { o += "\n\(esc)2m* cost = the agent's own API-equivalent estimate, not your bill. ctrl-c to quit.\(esc)0m\n" }
    return o
}
func age2(_ d: Date) -> String {
    let s = max(0, Int(d.timeIntervalSinceNow))
    return s >= 86400 ? "\(s / 86400)d\(s % 86400 / 3600)h" : s >= 3600 ? "\(s / 3600)h\(s % 3600 / 60)m" : "\(s / 60)m"
}

func sessionsJSON(_ mon: Monitor) -> String {
    let arr: [[String: Any]] = mon.snapshot().map { s, cat in
        var d: [String: Any] = ["id": s.id, "cat": cat, "agent": s.agent.rawValue, "state": s.state.rawValue,
                                "project": s.project, "cwd": s.cwd, "hookSeen": s.hookSeen,
                                "tokens": ["input": s.usage.input, "output": s.usage.output, "cacheRead": s.usage.cacheRead, "cacheWrite": s.usage.cacheWrite],
                                "lastEventAt": ISO8601DateFormatter().string(from: s.lastEventAt)]
        if let m = s.model { d["model"] = m }
        if let t = s.title { d["title"] = t }
        if let a = s.activity { d["activity"] = a }
        if let p = s.pid { d["pid"] = Int(p) }
        if let t = s.tty { d["tty"] = t }
        if let c = s.costUSD { d["estCostUSD"] = c }
        if let c = s.contextTokens { d["contextTokens"] = c }
        if let w = s.contextWindow { d["contextWindow"] = w }
        if !s.rateLimits.isEmpty { d["rateLimits"] = s.rateLimits.map { ["name": $0.name, "usedPercent": $0.usedPercent] } }
        return d
    }
    let data = (try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

// MARK: commands

switch cmd {
case "watch":
    let mon = Monitor()
    var dirty = true
    mon.onChange = { dirty = true }
    mon.start(listen: !flag("--no-listen"))
    print("\(esc)?25l", terminator: "")
    signal(SIGINT) { _ in print("\u{1B}[?25h"); exit(0) }
    let t = DispatchSource.makeTimerSource(queue: mon.queue)
    var lastDraw = Date.distantPast
    t.schedule(deadline: .now() + 0.3, repeating: 0.25)
    t.setEventHandler {
        guard dirty || Date().timeIntervalSince(lastDraw) > 1 else { return }
        dirty = false; lastDraw = Date()
        let frame = render(mon, live: true)
        print("\(esc)H\(esc)2J" + frame, terminator: ""); fflush(stdout)
    }
    t.resume()
    dispatchMain()

case "sessions", "layout":
    let mon = Monitor()
    let done = DispatchSemaphore(value: 0)
    mon.start(listen: false)
    // Give discovery and one process scan time to finish.
    mon.queue.asyncAfter(deadline: .now() + 3.5) { done.signal() }
    done.wait()
    mon.queue.sync {
        if cmd == "layout" {
            let snap = mon.snapshot()
            let l = TreeLayout.compute(ordered: snap.map(\.session), maxWidth: maxWidth)
            print("sessions: \(snap.count), budget: \(Int(maxWidth))pt")
            print("scale: \(l.scale)pt per art pixel, size: \(Int(l.width))×\(Int(l.height))pt, visible cats: \(l.slots.count), basket: \(l.basket.count)")
            for n in [0, 1, 3, 6, 10, 16, 30] {
                let fake = (0..<n).map { Session(id: "s\($0)", agent: .claude, at: Date().addingTimeInterval(Double($0))) }
                let x = TreeLayout.compute(ordered: fake, maxWidth: maxWidth)
                print(String(format: "  if %2d sessions: %4.1fpt/px  %4d×%-3dpt  visible %2d  basket %2d", n, x.scale, Int(x.width), Int(x.height), x.slots.count, x.basket.count))
            }
        } else if flag("--json") {
            print(sessionsJSON(mon))
        } else {
            print(render(mon, live: false), terminator: "")
        }
        fflush(stdout)
    }

case "hooks":
    let sub = args.count > 1 ? args[1] : "plan"
    let inst = HookInstaller(hookBinary: hookBinary)
    do {
        let remove = sub == "uninstall"
        let changes = try inst.plan(remove: remove)
        if changes.isEmpty { print(remove ? "No Agent Cats hooks installed." : "Hooks already up to date."); exit(0) }
        for c in changes { print(HookInstaller.diff(c)) }
        guard sub != "plan" else {
            print("Dry run only. Nothing was written. Run `agentcats hooks install --yes` to apply.")
            exit(0)
        }
        guard flag("--yes") else { print("Refusing to write without --yes."); exit(1) }
        guard FileManager.default.isExecutableFile(atPath: hookBinary) || remove else { print("Missing \(hookBinary); run ./build.sh first."); exit(1) }
        let backups = try inst.apply(changes)
        print("Done. Backups:\n" + backups.map { "  " + $0 }.joined(separator: "\n"))
        if !remove { print("Codex asks you to trust new hooks the next time it starts; approve them there.") }
    } catch {
        print("error: \(error.localizedDescription)"); exit(1)
    }

case "procs":
    for pid in ProcInfo.allPids() {
        guard let n = ProcInfo.agentName(pid) else { continue }
        let cwd = ProcInfo.cwd(pid) ?? "?"
        print("\(pid)  \(n)  tty=\(ProcInfo.tty(pid) ?? "-")  cwd=\(cwd)  key=\(Monitor.claudeKey(cwd: cwd))")
    }

case "selftest":
    exit(SelfTest.run() ? 0 : 1)

default:
    print("usage: agentcats [watch|sessions [--json]|layout|hooks plan|install --yes|uninstall --yes|selftest] [--width PT]")
    exit(2)
}
