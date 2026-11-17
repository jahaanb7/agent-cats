import AppKit
import ApplicationServices

/// Types a reply into the exact terminal tab a session runs in.
///
/// - iTerm2: writes into the matching session by tty. No focus change, no Accessibility.
/// - Terminal.app: selects the tab by tty, posts key events, then puts you back where you were.
///   Needs Accessibility.
/// - Anything else (IDEs, other terminals): refused, because the exact pane can't be targeted.
///
/// Safety model:
/// - The whole reply is checked once, before its first key: the moment is still current, the
///   session's tab is in front, and none of our windows holds the keyboard.
/// - After the first key, a sequence always finishes (an Esc that denied a request must not be
///   left without the text that explains it). It still stops if focus leaves Terminal.
/// - All AppleScript and key posting runs on one serial background queue, so the UI never waits.
enum TerminalTyper {
    enum Outcome: Equatable {
        case sent
        case needsAccessibility
        case failed(String)
    }

    private static var busy = false   // main thread only
    private static let queue = DispatchQueue(label: "agentcats.typer")

    /// - stillValid: must be called on main. False once the agent has moved on.
    /// - willFocusTerminal: called on main just before Terminal is brought forward.
    /// - done: called on main with the outcome.
    static func send(_ steps: [KeyStep], to s: Session, stillValid: @escaping () -> Bool,
                     willFocusTerminal: @escaping () -> Void, done: @escaping (Outcome) -> Void) {
        guard !busy else { done(.failed("Still typing the last reply…")); return }
        guard let tty = TerminalJump.devicePath(s) else {
            done(.failed("I can't find this session's terminal. Double-click me to open it.")); return
        }
        guard stillValid() else { done(.failed("The agent already moved on, so I didn't send that.")); return }
        busy = true
        func finish(_ o: Outcome) { busy = false; done(o) }

        if TerminalJump.isRunning(TerminalJump.iTermID) {
            queue.async {
                let outcome = iTermSend(steps, tty: tty, stillValid: stillValid)
                DispatchQueue.main.async { finish(outcome) }
            }
            return
        }
        guard TerminalJump.isRunning(TerminalJump.terminalID) else {
            let app = s.pid.flatMap(TerminalJump.owningApp(of:))?.localizedName ?? "that app"
            busy = false
            done(.failed("I can only type into Terminal or iTerm. Double-click me to answer in \(app).")); return
        }
        guard AXIsProcessTrusted() else {
            busy = false
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            done(.needsAccessibility); return
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let wasInTerminal = previous?.bundleIdentifier == TerminalJump.terminalID
        queue.async {
            let previousTab = wasInTerminal ? TerminalJump.terminalFrontTTY() : nil
            DispatchQueue.main.sync { willFocusTerminal() }
            let outcome = terminalSend(steps, tty: tty, stillValid: stillValid)
            DispatchQueue.main.async {
                // Put the user back: their own Terminal tab, or the app they were in.
                if let previousTab, previousTab != tty {
                    queue.async { _ = TerminalJump.terminalTab(tty: previousTab) }
                } else if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    previous.activate()
                }
                finish(outcome)
            }
        }
    }

    // MARK: iTerm2 (background queue)

    private static func iTermSend(_ steps: [KeyStep], tty: String, stillValid: @escaping () -> Bool) -> Outcome {
        guard TerminalJump.iTermSession(tty: tty, select: false) else {
            return .failed("That terminal tab is gone. Double-click me to look for it.")
        }
        for (i, step) in steps.enumerated() {
            if i == 0 || step == .pause { guard DispatchQueue.main.sync(execute: stillValid) else { return stopped() } }
            if step == .pause { Thread.sleep(forTimeInterval: 0.3); continue }
            guard TerminalJump.iTermSession(tty: tty, select: false, body: iTermWrite(step)) else { return stopped() }
            Thread.sleep(forTimeInterval: 0.08)
        }
        return .sent
    }

    private static func iTermWrite(_ step: KeyStep) -> String {
        switch step {
        case .text(let t): return "write text \(appleScriptString(t)) newline NO"
        case .returnKey: return "write text (ASCII character 13) newline NO"
        case .escape: return "write text (ASCII character 27) newline NO"
        case .pause: return ""
        }
    }

    static func appleScriptString(_ t: String) -> String {
        "\"" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Terminal.app (background queue)

    private static func terminalSend(_ steps: [KeyStep], tty: String, stillValid: @escaping () -> Bool) -> Outcome {
        guard TerminalJump.terminalTab(tty: tty) else {
            return .failed("That terminal tab is gone. Double-click me to look for it.")
        }
        Thread.sleep(forTimeInterval: 0.35)   // let Terminal come forward before the first key
        // Full check before the first key: the moment is current and the right tab is in front.
        let ready = DispatchQueue.main.sync { stillValid() && !NSApp.isActive }
        guard ready, TerminalJump.terminalFrontTabIs(tty: tty) else { return stopped() }
        for step in steps {
            if step == .pause { Thread.sleep(forTimeInterval: 0.3); continue }
            // Later keys: only focus matters now, so a sequence can't be cut in half by a new event.
            let focused = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == TerminalJump.terminalID
            guard focused else { return stopped() }
            post(step)
            Thread.sleep(forTimeInterval: 0.08)
        }
        return .sent
    }

    private static func stopped() -> Outcome {
        .failed("The agent or terminal changed while I was typing, so I stopped.")
    }

    // MARK: key events

    private static func post(_ step: KeyStep) {
        let src = CGEventSource(stateID: .hidSystemState)
        func send(_ code: CGKeyCode, _ units: [UniChar]? = nil) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
                e?.flags = []
                if let units { units.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) } }
                e?.post(tap: .cghidEventTap)
            }
        }
        switch step {
        case .returnKey: send(36)
        case .escape: send(53)
        case .pause: break
        case .text(let t):
            // Key events carry ~20 UTF-16 units; chunk by whole characters so emoji never split.
            var chunk: [UniChar] = []
            for ch in t {
                let u = Array(String(ch).utf16)
                if chunk.count + u.count > 20 { send(0, chunk); chunk = [] }
                chunk += u
            }
            if !chunk.isEmpty { send(0, chunk) }
        }
    }
}
