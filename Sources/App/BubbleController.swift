import AppKit
import Combine
import SwiftUI

/// Owns the one speech bubble on screen: which cat is talking, when cats speak on their own,
/// where the bubble sits, and how replies reach the agent.
final class BubbleController {
    struct Env {
        /// Screen rect of a visible cat, nil when it isn't on screen (room tucked away, in the basket).
        var catRect: (String) -> NSRect?
        /// The waiting hook approval for a session, if any.
        var pendingApproval: (String) -> PendingApproval?
        /// Resolves a hook approval; calls back with whether the hook was still waiting.
        var decide: (PendingApproval, ApprovalProtocol.Decision, String?, @escaping (Bool) -> Void) -> Void
        var hop: (String) -> Void
        var reduceMotion: () -> Bool
    }

    let model = BubbleModel()
    private let panel = BubblePanel()
    private let host: NSHostingView<BubbleView>
    private let env: Env

    private var entries: [String: CatTreeView.Entry] = [:]
    private(set) var sessionID: String?
    private var auto = false                     // opened by the cat itself, not by a click
    private var spoken: [String: String] = [:]   // session -> token it last spoke up about
    private var queue: [String] = []             // sessions waiting for their turn to speak
    private var pendingClose: DispatchWorkItem?
    private var placeQueued = false
    private var watch: AnyCancellable?
    private var targets: [String: (pid: Int32?, ok: Bool, app: String?)] = [:]
    private let started = Date()

    init(env: Env) {
        self.env = env
        host = NSHostingView(rootView: BubbleView(model: model))
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        panel.onEscape = { [weak self] in self?.close() }
        model.onClose = { [weak self] in self?.close() }
        model.onChoice = { [weak self] c in self?.perform(c.reply, text: nil) }
        model.onSendText = { [weak self] t in self?.sendText(t) }
        model.onOpenTerminal = { [weak self] in self?.openTerminal() }
        model.onNext = { [weak self] in self?.showNext() }
        // Content grows or shrinks (status line, "Sent", wrapped buttons): refit once per run loop.
        watch = model.objectWillChange.sink { [weak self] _ in self?.queuePlace() }
    }

    var isOpen: Bool { sessionID != nil }

    // MARK: clicks

    /// Single click toggles the bubble at once. A double-click is two of these plus `doubleClick`:
    /// the first toggles, the second reopens, so the bubble never flickers and is still there when you return.
    func click(_ session: Session) {
        if sessionID == session.id { close() } else { open(session.id, auto: false) }
    }

    /// Menu item: open the bubble without toggling it off.
    func toggleNow(_ session: Session) {
        if sessionID == session.id { close() } else { open(session.id, auto: false) }
    }

    /// Double-click: make sure the bubble is up, then jump to the terminal. The bubble stays.
    func doubleClick(_ session: Session) {
        if sessionID != session.id { open(session.id, auto: false) }
        UserDefaults.standard.set(true, forKey: "bubbleDoubleClickLearned")
        model.showHint = false
        TerminalJump.open(session)
    }

    /// A click in another app. Returns true when the bubble handled it (the room should stay put).
    func outsideClick() -> Bool {
        guard isOpen else { return false }
        // Questions stay until answered; everything else gets out of the way.
        if model.speech?.needsAnswer == true, model.status != .sent { return true }
        close(dismissed: false)
        return true
    }

    // MARK: opening and closing

    /// - dismissed: you closed it on purpose (×, Esc, click). Otherwise an unanswered question will
    ///   speak up again when its cat is next on screen.
    func close(dismissed: Bool = true) {
        if let id = sessionID, !dismissed, model.speech?.needsAnswer == true, model.status != .sent {
            spoken[id] = nil
        }
        pendingClose?.cancel(); pendingClose = nil
        sessionID = nil
        model.speech = nil
        model.draft = ""
        model.status = .idle
        model.anim.popped = false
        panel.orderOut(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isOpen else { return }
            // Anything that changed while this bubble was up gets its turn now.
            for e in self.entries.values { self.considerSpeaking(e.session) }
            self.speakNext()
        }
    }

    private func open(_ id: String, auto: Bool) {
        guard let entry = entries[id], env.catRect(id) != nil else { return }
        pendingClose?.cancel(); pendingClose = nil
        if sessionID != id { model.draft = "" }
        sessionID = id
        self.auto = auto
        queue.removeAll { $0 == id }
        spoken[id] = Speech.token(entry.session)
        model.status = .idle
        model.cat = entry.cat
        model.reduceMotion = env.reduceMotion()
        model.speech = speech(for: entry.session)
        // The hint teaches double-click on your own clicks only, and goes away once you've used it.
        let hints = UserDefaults.standard.integer(forKey: "bubbleHintsShown")
        let learned = UserDefaults.standard.bool(forKey: "bubbleDoubleClickLearned")
        model.showHint = !auto && !learned && hints < 4 && model.speech?.mood != .error
        if model.showHint { UserDefaults.standard.set(hints + 1, forKey: "bubbleHintsShown") }
        // A click means "I want to answer", so the cursor goes in the field. A bubble the cat opened
        // itself never takes the keyboard from whatever you are typing in.
        model.focusField = !auto && model.speech?.textReply != nil
        updateWaiting()
        model.generation += 1
        placeNow()
        if auto { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
        env.hop(id)
        scheduleAutoHide()
    }

    /// Next cat that wants to talk, from the "+N more" chip. The current one waits its turn.
    private func showNext() {
        guard let cur = sessionID, let next = queue.first(where: { $0 != cur && env.catRect($0) != nil }) else { return }
        let stillWaiting = model.speech?.needsAnswer == true && model.status != .sent
        pendingClose?.cancel(); pendingClose = nil
        sessionID = nil
        open(next, auto: false)
        if stillWaiting { spoken[cur] = nil; queue.append(cur); updateWaiting() }
    }

    private func speech(for s: Session) -> Speech {
        let t = target(s)
        return Speech.make(s, hookPending: env.pendingApproval(s.id) != nil, canType: t.ok, appName: t.app)
    }

    /// Whether replies can be typed into this session's terminal (cached per process).
    private func target(_ s: Session) -> (ok: Bool, app: String?) {
        if let c = targets[s.id], c.pid == s.pid { return (c.ok, c.app) }
        var r: (ok: Bool, app: String?) = (TerminalJump.devicePath(s) != nil, nil)
        if let app = s.pid.flatMap(TerminalJump.owningApp(of:)) {
            r.app = app.localizedName
            if let id = app.bundleIdentifier { r.ok = r.ok && [TerminalJump.terminalID, TerminalJump.iTermID].contains(id) }
        }
        targets[s.id] = (s.pid, r.ok, r.app)
        return r
    }

    /// Closes the bubble after `seconds`, unless `keep` is true then; in that case it re-checks every 3s
    /// so a bubble with a draft or a failure message closes once that's settled.
    private func scheduleClose(after seconds: TimeInterval, unless keep: @escaping () -> Bool = { false }) {
        pendingClose?.cancel()
        // `open` cancels pending closes, so this id can't close a newer bubble.
        let id = sessionID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionID == id else { return }
            if keep() { self.scheduleClose(after: 3, unless: keep); return }
            self.close(dismissed: false)
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Status and "done" bubbles that the cat opened itself fade away; questions wait for you.
    private func scheduleAutoHide() {
        guard auto, let sp = model.speech, !sp.needsAnswer else { return }
        scheduleClose(after: 9) { [weak self] in
            guard let self else { return false }
            return !self.model.draft.isEmpty || self.panel.isKeyWindow || self.model.status != .idle
        }
    }

    // MARK: live updates

    /// Called after every snapshot is applied to the tree and the room has been laid out.
    func update(entries list: [CatTreeView.Entry]) {
        entries = Dictionary(uniqueKeysWithValues: list.map { ($0.session.id, $0) })
        targets = targets.filter { entries[$0.key] != nil }
        refreshOpenBubble()
        for e in list { considerSpeaking(e.session) }
        speakNext()
        updateWaiting()
    }

    private func refreshOpenBubble() {
        guard let id = sessionID else { return }
        guard let e = entries[id], env.catRect(id) != nil else { close(dismissed: false); return }
        guard let current = model.speech, model.status != .sending else { queuePlace(); return }
        let fresh = speech(for: e.session)
        if fresh.token != current.token {
            // The agent moved on. After a reply that's success: let "Sent" show, then go.
            // An unanswered question that got answered in the terminal just closes.
            if model.status == .sent || (current.needsAnswer && !fresh.needsAnswer) {
                var frozen = current; frozen.token = fresh.token; frozen.choices = []; frozen.textReply = nil
                model.speech = frozen
                scheduleClose(after: model.status == .sent ? 0.9 : 0.2)
                return
            }
            spoken[id] = fresh.token
            model.status = .idle
            model.speech = fresh
            model.generation += 1
            env.hop(id)
            scheduleAutoHide()
        } else if fresh != current, model.status != .sent {
            // Same moment, better details (e.g. the reply text arrived after the Stop hook).
            model.speech = fresh
        }
        queuePlace()
    }

    /// Cats speak up when they need you, finish, or get stuck.
    private func considerSpeaking(_ s: Session) {
        let urgent = s.state.needsAttention
        guard urgent || s.state == .done else { return }
        let token = Speech.token(s)
        guard spoken[s.id] != token, sessionID != s.id else { return }
        // No replaying old news from before launch; "done" is only worth saying while it's fresh.
        if s.stateSince < started.addingTimeInterval(-2) || (!urgent && Date().timeIntervalSince(s.stateSince) > 60) {
            spoken[s.id] = token; return
        }
        guard !queue.contains(s.id) else { return }
        if urgent {
            let firstCalm = queue.firstIndex { !(entries[$0]?.session.state.needsAttention ?? false) } ?? queue.endIndex
            queue.insert(s.id, at: firstCalm)
        } else {
            queue.append(s.id)
        }
    }

    private func speakNext() {
        queue.removeAll { id in
            guard let s = entries[id]?.session else { return true }
            // "Done" is only news for a minute. A question still waiting is still worth asking.
            if s.state == .done, Date().timeIntervalSince(s.stateSince) > 60 { return true }
            return spoken[id] == Speech.token(s) || !(s.state.needsAttention || s.state == .done)
        }
        // A cat that's off screen (basket, room tucked) waits without blocking the others.
        guard let next = queue.first(where: { env.catRect($0) != nil }), let s = entries[next]?.session else { return }
        if isOpen {
            // Only a bubble the cat opened itself, that isn't asking anything and that you aren't
            // using, gives way — and only to something urgent.
            guard auto, let cur = model.speech, !cur.needsAnswer, model.draft.isEmpty, !panel.isKeyWindow,
                  model.status == .idle, s.state.needsAttention else { return }
        }
        open(next, auto: true)
    }

    private func updateWaiting() {
        let n = queue.filter { $0 != sessionID && (entries[$0]?.session.state.needsAttention ?? false) }.count
        if model.waiting != n { model.waiting = n }
    }

    // MARK: placement

    private func queuePlace() {
        guard !placeQueued else { return }
        placeQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.placeQueued = false
            self?.placeNow()
        }
    }

    /// Keep the bubble beside its cat with the tail pointing at it. Above when there's room,
    /// otherwise below (the usual case, since the room hangs from the menu bar).
    private func placeNow() {
        guard let id = sessionID, let cat = env.catRect(id) else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(cat) }) ?? NSScreen.main else { return }
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        let width: CGFloat = 300
        let vf = screen.visibleFrame
        let above = cat.maxY + 4 + height <= vf.maxY
        if model.tailOnTop != !above { model.tailOnTop = !above }
        let x = min(max(cat.midX - width / 2, vf.minX + 8), vf.maxX - width - 8)
        let tailX = cat.midX - x
        if abs(model.tailX - tailX) > 0.5 { model.tailX = tailX }
        let y = above ? cat.maxY + 2 : cat.minY + 6 - height
        let frame = NSRect(x: x, y: max(vf.minY + 4, y), width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // MARK: replies

    private func sendText(_ text: String) {
        guard let sp = model.speech else { return }
        if sp.textReply == .hookDeny {
            perform(.hook(allow: false), text: text)
        } else if let steps = sp.steps(forText: text) {
            perform(.keys(steps), text: text)
        }
    }

    private func perform(_ reply: Speech.Reply, text: String?) {
        guard let id = sessionID, let s = entries[id]?.session, let sp = model.speech, model.status != .sending else { return }
        if case .openTerminal = reply { openTerminal(); return }
        // Answer only the moment you were looking at.
        guard Speech.token(s) == sp.token else {
            model.status = .failed("The agent already moved on, so I didn't send that.")
            refreshOpenBubble(); return
        }
        model.status = .sending
        pendingClose?.cancel(); pendingClose = nil
        switch reply {
        case .hook(let allow):
            guard let request = env.pendingApproval(id) else {
                model.status = .failed("That request isn't waiting any more."); return
            }
            env.decide(request, allow ? .allow : .deny, text) { [weak self] accepted in
                guard let self, self.sessionID == id else { return }
                self.finishSend(accepted ? .sent : .failed("That request expired. Answer it in the terminal."), id: id)
            }
        case .keys(let steps):
            var hidden = false
            TerminalTyper.send(steps, to: s, stillValid: { [weak self] in
                // The live session must still be in the exact moment the bubble showed.
                guard let self, let live = self.entries[id]?.session else { return false }
                return Speech.token(live) == sp.token
            }, willFocusTerminal: { [weak self] in
                // Give up the keyboard so the keys can only reach the terminal.
                guard let self else { return }
                self.panel.makeFirstResponder(nil)
                self.panel.orderOut(nil)
                hidden = true
            }) { [weak self] outcome in
                guard let self, self.sessionID == id else { return }
                if hidden { self.panel.orderFrontRegardless() }
                switch outcome {
                case .sent: self.finishSend(.sent, id: id)
                case .needsAccessibility:
                    self.finishSend(.failed("Allow Agent Cats in System Settings › Privacy & Security › Accessibility, then try again."), id: id)
                case .failed(let why): self.finishSend(.failed(why), id: id)
                }
            }
        case .openTerminal:
            break
        }
    }

    private func finishSend(_ status: BubbleModel.Status, id: String) {
        model.status = status
        guard status == .sent else { refreshOpenBubble(); return }
        model.draft = ""
        env.hop(id)
        // The agent usually reacts (token changes → close). If it doesn't visibly, tidy up anyway.
        scheduleClose(after: 4)
        refreshOpenBubble()
    }

    func openTerminal() {
        guard let id = sessionID, let s = entries[id]?.session else { return }
        close()
        TerminalJump.open(s)
    }
}
