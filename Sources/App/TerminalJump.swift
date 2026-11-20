import AppKit

/// Brings the session's terminal tab (or app) to the front.
enum TerminalJump {
    /// All AppleScript runs here, never on the main thread: Terminal can take a moment to answer
    /// (seconds, the first time macOS asks for Automation access) and the cats must not freeze.
    static let scriptQueue = DispatchQueue(label: "agentcats.applescript", qos: .userInitiated)

    /// Brings the session forward. Returns at once; the work happens on `scriptQueue`.
    static func open(_ s: Session) {
        scriptQueue.async {
            // A session seen only in its transcript may still have a live process we haven't matched yet.
            let found = (s.pid == nil || s.tty == nil) ? liveProcess(for: s) : nil
            let pid = s.pid ?? found?.pid
            var session = s
            if session.tty == nil { session.tty = found?.tty }
            if let tty = devicePath(session), terminalTab(tty: tty) || iTermSession(tty: tty, select: true) { return }
            DispatchQueue.main.async {
                // Other terminals, IDEs, the desktop app — or Terminal without Automation access: bring the app forward.
                if let pid, let app = owningApp(of: pid) { bringForward(app); return }
                for id in [terminalID, iTermID] {
                    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { bringForward(app); return }
                }
                NSSound.beep()
            }
        }
    }

    /// Activation that works from a background (accessory) app. On macOS 14+ a plain `activate()`
    /// from an app that isn't frontmost is often ignored, which made double-clicks do nothing.
    static func bringForward(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
        app.activate(options: [.activateAllWindows])
        guard let url = app.bundleURL else { return }
        // Launch Services always honours an explicit open: a reliable second try.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        }
    }

    /// The running agent process for a session, matched by its folder.
    static func liveProcess(for s: Session) -> (pid: Int32, tty: String?)? {
        guard !s.cwd.isEmpty else { return nil }
        func key(_ path: String) -> String { String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }) }
        for pid in ProcInfo.allPids() {
            guard ProcInfo.agentName(pid) == s.agent.rawValue, let cwd = ProcInfo.cwd(pid) else { continue }
            if cwd == s.cwd || key(cwd) == s.launchKey { return (pid, ProcInfo.tty(pid)) }
        }
        return nil
    }

    static let terminalID = "com.apple.Terminal", iTermID = "com.googlecode.iterm2"

    /// "/dev/ttys009" for a session, only when the tty name is plain (it is pasted into AppleScript).
    static func devicePath(_ s: Session) -> String? {
        guard let t = s.tty, !t.isEmpty, t.count < 32,
              t.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return "/dev/" + t
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Runs an AppleScript and returns its boolean result (false on any error).
    @discardableResult static func runScript(_ src: String) -> Bool { script(src)?.booleanValue ?? false }

    private static func script(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { NSLog("AgentCats: AppleScript failed: \(err)") }
        return r
    }

    /// The tty of Terminal.app's front tab ("/dev/ttys004"), to put the user back there afterwards.
    static func terminalFrontTTY() -> String? {
        guard isRunning(terminalID) else { return nil }
        let t = script("""
        tell application id "\(terminalID)"
          if (count of windows) is 0 then return ""
          return tty of selected tab of front window
        end tell
        """)?.stringValue
        return (t?.hasPrefix("/dev/") ?? false) ? t : nil
    }

    /// Finds the iTerm2 session on this tty and selects it (and/or runs `body` inside `tell s`).
    @discardableResult static func iTermSession(tty: String, select: Bool, body: String = "") -> Bool {
        guard isRunning(iTermID) else { return false }
        let pick = select ? "select w\n tell t to select\n tell s to select\n activate" : ""
        return runScript("""
        tell application id "\(iTermID)"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  \(pick)
                  tell s
                    \(body)
                  end tell
                  return true
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return false
        """)
    }

    /// True when Terminal.app's frontmost window shows the tab on this tty.
    static func terminalFrontTabIs(tty: String) -> Bool {
        guard isRunning(terminalID) else { return false }
        return runScript("""
        tell application id "\(terminalID)"
          if (count of windows) is 0 then return false
          return (tty of selected tab of front window) is "\(tty)"
        end tell
        """)
    }

    /// Selects the Terminal.app tab whose tty matches. First use asks for Automation permission (free, one-time).
    static func terminalTab(tty: String) -> Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first != nil else { return false }
        let src = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set miniaturized of w to false
                set selected of t to true
                set index of w to 1
                activate
                return true
              end if
            end repeat
          end repeat
        end tell
        return false
        """
        return runScript(src)
    }

    /// Walks up from the agent process to the first ancestor that is a GUI app (Terminal, iTerm, VS Code…).
    static func owningApp(of pid: Int32) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            guard let pp = ProcInfo.parent(p), pp > 1, pp != p else { return nil }
            p = pp
        }
        return nil
    }
}

/// Where each session runs (terminal, editor, background…), cached per process.
enum Origins {
    private static var hosts: [Int32: (id: String?, name: String?)] = [:]

    static func of(_ s: Session) -> SessionOrigin? {
        var host: (id: String?, name: String?) = (nil, nil)
        if let pid = s.pid {
            if let cached = hosts[pid] { host = cached } else {
                let app = TerminalJump.owningApp(of: pid)
                host = (app?.bundleIdentifier, app?.localizedName)
                if hosts.count > 200 { hosts.removeAll() }
                hosts[pid] = host
            }
        }
        return s.origin(hostBundleID: host.id, hostName: host.name)
    }
}

/// Ends an agent session from its cat: stops the agent process and, if asked, closes its terminal.
enum SessionEnder {
    /// Asks first (it can't be undone), then ends the session.
    static func confirmAndEnd(_ s: Session, cat: String) {
        let alert = NSAlert()
        alert.messageText = "End \(cat)’s session?"
        alert.informativeText = "This stops \(s.agent.displayName) in \(s.project). The conversation stays in its history, so you can resume it later."
        alert.alertStyle = .warning
        let tty = TerminalJump.devicePath(s) != nil || TerminalJump.liveProcess(for: s)?.tty != nil
        if tty { alert.addButton(withTitle: "End & Close Terminal") }
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let r = alert.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn, second = NSApplication.ModalResponse.alertSecondButtonReturn
        if tty && r == first { end(s, closeTerminal: true) }
        else if (tty && r == second) || (!tty && r == first) { end(s, closeTerminal: false) }
    }

    /// SIGTERM lets Claude Code and Codex shut down cleanly (history saved, SessionEnd hook fired).
    @discardableResult static func end(_ s: Session, closeTerminal: Bool) -> Bool {
        let found = TerminalJump.liveProcess(for: s)
        guard let pid = s.pid ?? found?.pid, ProcInfo.isAlive(pid) else { NSSound.beep(); return false }
        var withTTY = s
        if withTTY.tty == nil { withTTY.tty = found?.tty }
        let tty = TerminalJump.devicePath(withTTY)
        kill(pid, SIGTERM)
        // Still running after a few seconds (stuck on a prompt): insist.
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if ProcInfo.isAlive(pid) { kill(pid, SIGKILL) } }
        guard closeTerminal, let tty else { return true }
        TerminalJump.scriptQueue.asyncAfter(deadline: .now() + 1.2) {
            if TerminalJump.iTermSession(tty: tty, select: false, body: "close") { return }
            guard TerminalJump.isRunning(TerminalJump.terminalID) else { return }
            // Terminal can only close windows from a script: close it when this was its only tab.
            TerminalJump.runScript("""
            tell application id "\(TerminalJump.terminalID)"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    if (count of tabs of w) is 1 then close w
                    return true
                  end if
                end repeat
              end repeat
            end tell
            return false
            """)
        }
        return true
    }
}
