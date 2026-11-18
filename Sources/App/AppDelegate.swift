import AppKit

/// Borderless, non-activating panel just under the menu bar, top right.
final class TreePanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        // Shown on every Space, but not over fullscreen apps (no .fullScreenAuxiliary).
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Menu item that runs a closure (keeps per-cat menus free of selector plumbing).
final class CallbackItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private let dashboard = DashboardController()
    private var statusItem: NSStatusItem!
    private var panel: TreePanel!
    private var tree: CatTreeView!
    private var timer: Timer?
    private var room: CatRoomView!
    private var visibility = WidgetVisibility()
    private var currentTreeSize = NSSize.zero
    private var outsideClickMonitor: Any?
    private var refreshQueued = false
    private var bubble: BubbleController!
    private var roomShownExpanded = false
    private var collapsing = false
    private var presentGen = 0
    private lazy var chimeSound: NSSound? = {
        let s = NSSound(named: "Pop") ?? NSSound(named: "Tink")
        s?.volume = 0.35
        return s
    }()

    private var preferredScale: Double {
        get { UserDefaults.standard.object(forKey: "scale") as? Double ?? 1.5 }
        set { UserDefaults.standard.set(newValue, forKey: "scale") }
    }
    /// Gone: a double-click on the rope or × hid everything, rope included. A cat that needs you
    /// still pops up (and goes again afterwards); the paw in the menu bar brings everything back.
    private var ropeHidden = false
    private var soundOn: Bool {
        get { UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundOn") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        StartupLog.write("Application launch delegate entered")
        UserDefaults.standard.removeObject(forKey: "ropeHidden")   // was a sticky setting in 0.3.1
        guard let url = Bundle.main.url(forResource: "cats", withExtension: "json"), let book = SpriteBook(url: url) else {
            NSLog("AgentCats: missing cats.json"); NSApp.terminate(nil); return
        }
        panel = TreePanel()
        dashboard.model.book = book
        tree = CatTreeView(book: book)
        tree.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        bubble = BubbleController(env: .init(
            catRect: { [weak self] id in
                guard let self, self.visibility.isExpanded else { return nil }
                return self.tree.screenRect(for: id)
            },
            pendingApproval: { [weak self] id in self?.dashboard.model.approvals.first { $0.sessionID == id } },
            decide: { [weak self] request, decision, message, done in
                self?.resolveApproval(request.id, decision, message: message, done: done)
            },
            hop: { [weak self] id in self?.tree.hop(id) },
            reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
            chime: { [weak self] in self?.chime() }))
        tree.onCatClick = { [weak self] s in self?.bubble.click(s) }
        tree.onCatDoubleClick = { [weak self] s in self?.bubble.doubleClick(s) }
        tree.onCatRightClick = { [weak self] s, e in self?.showCatMenu(s, e) }
        tree.onTreeClick = { [weak self] in self?.dashboard.show() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Agent Cats")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(pawClicked)
        tree.onRightClick = { [weak self] e in self?.showMenu(e) }
        room = CatRoomView(tree: tree)
        room.rope.onPull = { [weak self] in self?.toggleRoom() }
        room.rope.onDoubleClick = { [weak self] in self?.vanish() }
        room.rope.reduceMotion = tree.reduceMotion
        room.onDashboard = { [weak self] in self?.showDashboard() }
        room.onHide = { [weak self] in self?.hideRoom() }
        room.onHideCompletely = { [weak self] in self?.vanish() }
        panel.contentView = room
        panel.alphaValue = 1
        if !CommandLine.arguments.contains("--background") { visibility.show() }
        presentRoom()
        StartupLog.write("Room ready at \(panel.frame); expanded=\(visibility.isExpanded)")
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(revealFromLaunch), name: Notification.Name("local.agentcats.reveal"), object: nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            // Clicking in another app dismisses the bubble first, then the room.
            if self.bubble.outsideClick() { return }
            guard self.visibility.isExpanded, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.dismissRoom()
        }

        monitor.acceptsApprovals = true
        dashboard.model.onDecision = { [weak self] id, decision in
            self?.resolveApproval(id, decision, message: nil) { accepted in
                self?.dashboard.model.decisionMessage = accepted
                    ? (decision == .handoff ? "Continue in the agent’s window." : "Decision submitted to the waiting hook.")
                    : "This request is no longer waiting. Check the agent’s window."
            }
        }
        monitor.onChange = { [weak self] in self?.queueRefresh() }
        monitor.start(listen: true)
        StartupLog.write("Session monitor started")

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tree.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self?.room.rope.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.queueRefresh() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queueRefresh()
        }
    }

    /// Answers a waiting hook approval; `done` runs on the main queue with whether it was still waiting.
    private func resolveApproval(_ id: String, _ decision: ApprovalProtocol.Decision, message: String?, done: @escaping (Bool) -> Void) {
        dashboard.model.approvals.removeAll { $0.id == id }
        monitor.queue.async { [self] in
            let accepted = monitor.approvals.resolve(id, decision: decision, message: message)
            DispatchQueue.main.async { done(accepted) }
            queueRefresh()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealFromLaunch()
        return true
    }

    @objc private func revealFromLaunch() {
        guard room != nil else { return }
        visibility.show()
        presentRoom()
        StartupLog.write("Room revealed by explicit open")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        monitor.queue.sync { monitor.approvals.cancel() }
    }

    // MARK: refresh

    /// Coalesces bursts of events (a busy agent can emit dozens per second) into one redraw.
    private func queueRefresh() {
        DispatchQueue.main.async { [self] in
            guard !refreshQueued else { return }
            refreshQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
                refreshQueued = false
                monitor.queue.async { [self] in
                    let snap = monitor.snapshot()
                    let requests = monitor.approvals.requests.filter { $0.reply.pending }
                    let connectionMessage = monitor.listenerError
                    DispatchQueue.main.async {
                        self.dashboard.model.approvals = requests
                        self.dashboard.model.connectionMessage = connectionMessage
                        self.apply(snap)
                    }
                }
            }
        }
    }

    private func apply(_ snap: [(session: Session, cat: String)]) {
        dashboard.model.entries = snap.map { .init(session: $0.session, cat: $0.cat) }
        guard let screen = NSScreen.screens.first else { return }   // the screen with the menu bar
        let vf = screen.visibleFrame
        let budget = Double(vf.width) * 0.45
        let layout = TreeLayout.compute(ordered: snap.map(\.session), maxWidth: budget, preferredScale: preferredScale)
        currentTreeSize = tree.update(entries: snap.map { .init(session: $0.session, cat: $0.cat) }, layout: layout)
        let attentionKeys = Set(snap.filter { $0.session.wantsYou }.map { Speech.token($0.session) }).union(dashboard.model.approvals.map { "approval|" + $0.id })
        visibility.update(attention: attentionKeys)
        let opening = presentRoom()
        let entries: [CatTreeView.Entry] = snap.map { .init(session: $0.session, cat: $0.cat) }
        if opening && !tree.reduceMotion {
            // Let the room finish dropping in before the cat starts talking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.bubble.update(entries: entries) }
        } else {
            bubble.update(entries: entries)
        }
    }

    /// Shows the room in its current state. Returns true when the room is just now dropping down.
    @discardableResult
    private func presentRoom() -> Bool {
        guard room != nil else { return false }
        let expanded = visibility.isExpanded
        if !expanded, bubble?.isOpen == true { bubble.close(dismissed: false) }
        if !expanded && roomShownExpanded && !tree.reduceMotion && panel.isVisible {
            // Slide the room up first, then shrink the window to the cord (or vanish).
            roomShownExpanded = false
            collapsing = true
            timer?.invalidate(); timer = nil
            presentGen += 1
            let gen = presentGen
            room.animateOut { [weak self] in
                guard let self, self.presentGen == gen else { return }
                self.collapsing = false
                self.layoutRoom()
            }
            return false
        }
        if !expanded && collapsing { return false }   // the slide-up will finish the job
        presentGen += 1
        collapsing = false
        let opening = expanded && !roomShownExpanded
        roomShownExpanded = expanded
        layoutRoom()
        if opening && !tree.reduceMotion { room.animateIn() }
        return opening
    }

    /// Sizes and places the panel for the current state, with no animation of its own.
    private func layoutRoom() {
        guard let room, let screen = NSScreen.screens.first else { return }
        let expanded = visibility.isExpanded
        let size = room.update(expanded: expanded, treeSize: currentTreeSize,
                               count: dashboard.model.entries.count,
                               attention: dashboard.model.entries.filter { $0.session.wantsYou }.count)
        let vf = screen.visibleFrame
        // The rope remains anchored at the same horizontal position in both states.
        let frame = NSRect(x: vf.maxX - size.width - 14, y: vf.maxY - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        room.layoutSubtreeIfNeeded()
        // While open, the room (and its bubble) also shows over full-screen apps, so a cat asking
        // you something is never invisible. The idle rope stays out of full-screen apps.
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if expanded { behavior.insert(.fullScreenAuxiliary) }
        if panel.collectionBehavior != behavior { panel.collectionBehavior = behavior }
        if !expanded && ropeHidden {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = tree.reduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 1
            }
        }
        if expanded {
            let fps: Double = tree.hasLivelyCats ? 6 : 2
            tree.tickInterval = 1 / fps
            startTimer(fps: fps)
        } else {
            timer?.invalidate(); timer = nil
        }
    }

    /// Rope click, × or menu: open the room, or tuck it back to the rope (which stays visible).
    @objc private func toggleRoom() {
        if visibility.isExpanded { hideRoom() } else { visibility.show(); presentRoom() }
    }
    private func hideRoom() { ropeHidden = false; visibility.hide(); presentRoom() }
    /// Clicking elsewhere: get out of the way, but stay gone if you had hidden everything.
    private func dismissRoom() { visibility.hide(); presentRoom() }

    /// The paw always gets you back: it undoes "hide completely" and opens the room.
    @objc private func pawClicked() {
        if ropeHidden { ropeHidden = false; visibility.show(); presentRoom() } else { toggleRoom() }
    }

    /// Double-click on the rope: tuck away and disappear completely. Click the paw to bring it back.
    private func vanish() {
        ropeHidden = true
        visibility.hide()
        presentRoom()
    }

    @objc private func hideCompletely() { vanish() }

    @objc private func toggleSound() {
        soundOn.toggle()
        if soundOn { chime() }
    }

    private func chime() {
        guard soundOn, let s = chimeSound else { return }
        s.stop()
        s.play()
    }

    private func startTimer(fps: Double) {
        if let t = timer, abs(t.timeInterval - 1 / fps) < 0.001 { return }
        timer?.invalidate()
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
            guard let self, self.panel.occlusionState.contains(.visible) else { return }   // no work when hidden
            self.tree.animate()
        }
        t.tolerance = 0.25 / fps
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: menu

    @objc private func showDashboard() {
        let needingAttention = dashboard.model.entries.first { $0.session.wantsYou }?.session.id
        dashboard.show(session: needingAttention)
    }

    private func showMenu(_ e: NSEvent) { NSMenu.popUpContextMenu(generalMenu(), with: e, for: tree) }

    private func generalMenu() -> NSMenu {
        let m = NSMenu()
        let title = NSMenuItem(title: "Agent Cats", action: nil, keyEquivalent: ""); title.isEnabled = false
        m.addItem(title)
        let toggle = NSMenuItem(title: visibility.isExpanded ? "Tuck away" : "Pull down cats", action: #selector(toggleRoom), keyEquivalent: "")
        toggle.target = self
        m.addItem(toggle)
        if !visibility.isExpanded || ropeHidden { toggle.action = #selector(pawClicked) }
        let open = NSMenuItem(title: "Open dashboard", action: #selector(showDashboard), keyEquivalent: "")
        open.target = self
        m.addItem(open)
        m.addItem(.separator())
        let gone = NSMenuItem(title: "Hide completely (double-click rope or ×)", action: #selector(hideCompletely), keyEquivalent: "")
        gone.target = self
        gone.toolTip = "Even the rope disappears. A cat that needs you still pops up. Click the paw to bring it back."
        m.addItem(gone)
        let sound = NSMenuItem(title: "Play a sound when a cat asks", action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self; sound.state = soundOn ? .on : .off
        m.addItem(sound)
        m.addItem(.separator())
        for (name, v) in [("Large cats", 1.5), ("Small cats", 1.0)] {
            let i = NSMenuItem(title: name, action: #selector(setScale(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = v; i.state = preferredScale == v ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        let q = NSMenuItem(title: "Quit Agent Cats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(q)
        return m
    }

    private func showCatMenu(_ s: Session, _ e: NSEvent) {
        let m = NSMenu()
        let cat = dashboard.model.entries.first { $0.session.id == s.id }?.cat ?? "Cat"
        let title = NSMenuItem(title: "\(cat) · \(s.project)", action: nil, keyEquivalent: ""); title.isEnabled = false
        m.addItem(title)
        m.addItem(CallbackItem(bubble.sessionID == s.id ? "Hide bubble" : "What do you need?") { [weak self] in self?.bubble.toggleNow(s) })
        let jump = CallbackItem("Open terminal") { TerminalJump.open(s) }
        jump.isEnabled = s.pid != nil || s.tty != nil
        m.addItem(jump)
        if !s.cwd.isEmpty {
            m.addItem(CallbackItem("Open project folder") { NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd)) })
        }
        m.addItem(CallbackItem("Show details…") { [weak self] in self?.dashboard.show(session: s.id) })
        m.addItem(.separator())
        let more = NSMenuItem(title: "Agent Cats", action: nil, keyEquivalent: "")
        more.submenu = generalMenu()
        m.addItem(more)
        NSMenu.popUpContextMenu(m, with: e, for: tree)
    }

    @objc private func setScale(_ sender: NSMenuItem) {
        preferredScale = sender.representedObject as? Double ?? 1.5
        queueRefresh()
    }
}
