import AppKit

/// Brings the session's terminal tab (or app) to the front.
enum TerminalJump {
    static func open(_ s: Session) {
        if let tty = devicePath(s), terminalTab(tty: tty) || iTermSession(tty: tty, select: true) { return }
        // No tty (desktop apps, IDEs): bring the owning app forward instead.
        if let pid = s.pid, let app = owningApp(of: pid) { app.activate(); return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first { app.activate() }
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
