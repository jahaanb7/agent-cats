import CoreServices
import Darwin
import Foundation

/// Wires every source together: hook socket, transcript/rollout tailing, and process liveness.
/// All state lives on `queue`; observers are called on that queue too.
public final class Monitor {
    public let store = SessionStore()
    let approvals = ApprovalStore()
    var acceptsApprovals = false
    private(set) var listenerError: String?
    public let roster = CatRoster()
    public let queue = DispatchQueue(label: "agentcats.monitor")
    public var onChange: (() -> Void)?
    public private(set) var hookEventsReceived = 0
    public private(set) var startedAt = Date()

    private var tails: [String: FileTail] = [:]
    private var claudeParsers: [String: ClaudeTranscriptParser] = [:]
    private var codexParsers: [String: CodexRolloutParser] = [:]
    private var watcher: DirWatcher?
    private var server: EventServer?
    private var exitSources: [Int32: DispatchSourceProcess] = [:]
    private var timer: DispatchSourceTimer?
    private var procTimer: DispatchSourceTimer?
    private var pendingProcs: [Int32: Int] = [:]       // pid -> consecutive sightings before placeholder
    private var placeholderFor: [Int32: String] = [:]  // pid -> placeholder session id
    public var lookback: TimeInterval = 6 * 3600       // how far back to look for sessions at launch

    public init() {}

    public func start(listen: Bool = true) {
        queue.async { [self] in
            discover()
            if listen {
                server = EventServer(path: Paths.socket, queue: queue) { [weak self] obj, reply in
                    guard let self else { reply.complete([:]); return }
                    self.ingestHook(obj)
                    if self.acceptsApprovals && ApprovalProtocol.supports(obj) {
                        self.approvals.add(obj, reply: reply)
                        self.onChange?()
                    } else { reply.complete([:]) }
                }
                if server?.start() != true {
                    listenerError = "Hook connection unavailable. Close other Agent Cats listeners and reopen the app."
                    server = nil
                }
                drainSpool()
            }
            watcher = DirWatcher(paths: [Paths.claudeProjects, Paths.codexSessions], queue: queue) { [weak self] paths in
                self?.filesChanged(paths)
            }
            scanProcesses()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume(); timer = t
            let p = DispatchSource.makeTimerSource(queue: queue)
            p.schedule(deadline: .now() + 3, repeating: 3, leeway: .seconds(1))
            p.setEventHandler { [weak self] in self?.scanProcesses() }
            p.resume(); procTimer = p
            onChange?()
        }
    }

    // MARK: hooks

    func ingestHook(_ obj: [String: Any]) {
        guard let e = HookParser.parse(obj) else { return }
        if [.toolStart, .toolEnd, .toolFailed, .turnEnd, .sessionEnd, .prompt].contains(e.kind) {
            approvals.cancel(session: e.sessionId)
        }
        hookEventsReceived += 1
        if let pid = e.pid, let ph = placeholderFor[pid], ph != e.sessionId {
            store.apply(e); store.merge(placeholder: ph, into: e.sessionId); placeholderFor[pid] = e.sessionId
        } else {
            store.apply(e)
        }
        if let pid = e.pid { watchExit(pid: pid, session: e.sessionId) }
        if e.agent == .claude, let tp = e.transcriptPath { store.setLaunchKey(e.sessionId, Self.claudeKey(transcript: tp)) }
        if let tp = e.transcriptPath, tails[tp] == nil { follow(path: tp, replay: true) }
        onChange?()
    }

    private func drainSpool() {
        guard let data = FileManager.default.contents(atPath: Paths.spool), !data.isEmpty else { return }
        try? Data().write(to: URL(fileURLWithPath: Paths.spool))
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if let o = jsonObject(line) { ingestHook(o) }
        }
    }

    // MARK: logs

    private func discover() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-lookback)
        var files: [String] = []
        for dir in (try? fm.contentsOfDirectory(atPath: Paths.claudeProjects)) ?? [] {
            let d = Paths.claudeProjects + "/" + dir
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".jsonl") { files.append(d + "/" + f) }
        }
        let cal = Calendar.current
        for back in 0...1 {
            let day = cal.date(byAdding: .day, value: -back, to: Date())!
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let d = String(format: "%@/%04d/%02d/%02d", Paths.codexSessions, c.year!, c.month!, c.day!)
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".jsonl") { files.append(d + "/" + f) }
        }
        for f in files {
            guard let m = (try? fm.attributesOfItem(atPath: f))?[.modificationDate] as? Date, m > cutoff else { continue }
            follow(path: f, replay: true)
        }
    }

    private func filesChanged(_ paths: [String]) {
        var any = false
        for p in Set(paths) where p.hasSuffix(".jsonl") && !p.contains("/subagents/") {
            if tails[p] == nil { follow(path: p, replay: true) } else { readNew(p) }
            any = true
        }
        if any { onChange?() }
    }

    private func follow(path: String, replay: Bool) {
        guard tails[path] == nil, FileManager.default.fileExists(atPath: path) else { return }
        let isCodex = path.hasPrefix(Paths.codexSessions)
        if !isCodex && !path.hasPrefix(Paths.claudeProjects) { return }
        tails[path] = FileTail(path: path, startAtEnd: !replay)
        readNew(path)
    }

    private func readNew(_ path: String) {
        guard let tail = tails[path] else { return }
        let lines = tail.readNewLines()
        guard !lines.isEmpty else { return }
        let isCodex = path.hasPrefix(Paths.codexSessions)
        let fallback = isCodex ? CodexRolloutParser.sessionId(fromPath: path)
                               : ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        for line in lines {
            let events: [AgentEvent]
            if isCodex {
                let p = codexParsers[path] ?? CodexRolloutParser(); codexParsers[path] = p
                events = p.parse(line: line, fallbackSession: fallback)
            } else {
                let p = claudeParsers[path] ?? ClaudeTranscriptParser(); claudeParsers[path] = p
                events = p.parse(line: line, fallbackSession: fallback)
            }
            for var e in events {
                e.transcriptPath = path
                store.apply(e)
                if isCodex, e.kind == .sessionStart, let c = e.cwd { store.setLaunchKey(e.sessionId, c) }
                if !isCodex { store.setLaunchKey(e.sessionId, Self.claudeKey(transcript: path)) }
            }
        }
    }

    // MARK: processes

    /// Matches running `claude` / `codex` processes to sessions by working directory, so cats
    /// appear even without hooks, and so we notice crashes immediately.
    /// Claude keeps transcripts in ~/.claude/projects/<launch folder with every non-alphanumeric as "-">.
    static func claudeKey(transcript: String) -> String {
        ((transcript as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }
    static func claudeKey(cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
    static func processKey(agent: AgentKind, cwd: String) -> String {
        agent == .claude ? claudeKey(cwd: cwd) : cwd
    }

    private func scanProcesses() {
        var live: [(pid: Int32, agent: AgentKind, cwd: String, tty: String?)] = []
        for pid in ProcInfo.allPids() {
            guard let n = ProcInfo.agentName(pid), let agent = AgentKind(rawValue: n) else { continue }
            guard let cwd = ProcInfo.cwd(pid) else { continue }
            live.append((pid, agent, cwd, ProcInfo.tty(pid)))
        }
        let livePids = Set(live.map(\.pid))
        pendingProcs = pendingProcs.filter { livePids.contains($0.key) }
        let claimed = Set(store.sessions.values.compactMap(\.pid))
        for p in live where !claimed.contains(p.pid) {
            // Best unclaimed session of the same agent in the same folder, most recently active first.
            let cands = store.sessions.values
                .filter { $0.agent == p.agent && $0.pid == nil && $0.state != .gone && ($0.launchKey ?? Self.processKey(agent: $0.agent, cwd: $0.cwd)) == Self.processKey(agent: p.agent, cwd: p.cwd) }
                .sorted { $0.lastEventAt > $1.lastEventAt }
            if let s = cands.first {
                store.setProcess(s.id, pid: p.pid, tty: p.tty)
                watchExit(pid: p.pid, session: s.id)
                if let ph = placeholderFor[p.pid], ph != s.id { store.merge(placeholder: ph, into: s.id) }
                placeholderFor[p.pid] = s.id
                onChange?()
            } else if p.tty != nil, placeholderFor[p.pid] == nil {
                // A terminal agent with no transcript yet (just launched). Show it after two sightings.
                pendingProcs[p.pid, default: 0] += 1
                if pendingProcs[p.pid]! >= 2 {
                    let id = "pending-\(p.pid)"
                    var e = AgentEvent(agent: p.agent, sessionId: id, kind: .sessionStart, source: .process)
                    e.cwd = p.cwd; e.pid = p.pid; e.tty = p.tty
                    store.apply(e); store.setLaunchKey(id, Self.processKey(agent: p.agent, cwd: p.cwd)); placeholderFor[p.pid] = id
                    watchExit(pid: p.pid, session: id)
                    onChange?()
                }
            }
        }
        // A placeholder whose folder now has a real transcript-backed session gets merged.
        for (pid, ph) in placeholderFor where ph.hasPrefix("pending-") {
            guard let p = store.sessions[ph] else { placeholderFor[pid] = nil; continue }
            if let real = store.sessions.values.first(where: { !$0.id.hasPrefix("pending-") && $0.agent == p.agent && $0.launchKey == p.launchKey && $0.pid == nil && $0.lastEventAt >= p.startedAt.addingTimeInterval(-5) }) {
                store.setProcess(real.id, pid: pid, tty: p.tty)
                store.merge(placeholder: ph, into: real.id)
                placeholderFor[pid] = real.id
                watchExit(pid: pid, session: real.id)
                onChange?()
            }
        }
    }

    private func watchExit(pid: Int32, session: String) {
        guard exitSources[pid] == nil, ProcInfo.isAlive(pid) else { return }
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            src.cancel(); self.exitSources[pid] = nil
            for s in self.store.sessions.values where s.pid == pid && s.state != .gone {
                self.store.apply(AgentEvent(agent: s.agent, sessionId: s.id, kind: .processExit, source: .process))
            }
            self.approvals.cancel(session: session)
            self.placeholderFor[pid] = nil
            self.onChange?()
        }
        src.resume()
        exitSources[pid] = src
    }

    private func tick() {
        let approvalsChanged = approvals.sweep()
        let changed = store.tick { s in
            if let pid = s.pid { return ProcInfo.isAlive(pid) }
            return nil   // log-only session: unknown liveness, expires when quiet
        }
        for id in changed where store.sessions[id]?.state == .gone || store.sessions[id] == nil { approvals.cancel(session: id) }
        if !changed.isEmpty || approvalsChanged { onChange?() }
    }

    /// Ordered sessions with their assigned cat names.
    public func snapshot() -> [(session: Session, cat: String)] {
        var taken = Set<String>()
        // Hide stubs: transcripts with no folder and no process (e.g. a file holding only a cost record).
        return store.ordered.filter { !$0.cwd.isEmpty || $0.pid != nil }.map { s in
            let c = roster.cat(for: s, taken: taken); taken.insert(c); return (s, c)
        }
    }
}

// MARK: - file tailing

final class FileTail {
    let path: String
    private var offset: UInt64 = 0
    private var partial = Data()

    init(path: String, startAtEnd: Bool) {
        self.path = path
        if startAtEnd, let a = try? FileManager.default.attributesOfItem(atPath: path), let s = a[.size] as? UInt64 { offset = s }
    }

    func readNewLines() -> [Substring] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial.removeAll() }   // truncated or replaced
        guard size > offset else { return [] }
        try? fh.seek(toOffset: offset)
        let data = fh.readData(ofLength: Int(size - offset))
        offset += UInt64(data.count)
        partial.append(data)
        guard let lastNL = partial.lastIndex(of: 0x0A) else { return [] }
        let complete = partial[partial.startIndex...lastNL]
        partial = Data(partial[partial.index(after: lastNL)...])
        return String(decoding: complete, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    }
}

// MARK: - FSEvents

final class DirWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(paths: [String], queue: DispatchQueue, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<DirWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.handler(Array(arr.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, cb, &ctx, existing as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags)
        if let s = stream { FSEventStreamSetDispatchQueue(s, queue); FSEventStreamStart(s) }
    }

    deinit {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }
}
