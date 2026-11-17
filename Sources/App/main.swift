import AppKit

StartupLog.write("Starting Agent Cats \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
guard Bundle.main.url(forResource: "cats", withExtension: "json") != nil else {
    StartupLog.write("Cannot start: cats.json is missing from the app bundle")
    fputs("Agent Cats resources are missing. Rebuild or reinstall the complete app bundle.\n", stderr)
    exit(1)
}
let app = NSApplication.shared
StartupLog.write("AppKit initialized; \(NSScreen.screens.count) desktop screens available")
guard !NSScreen.screens.isEmpty else {
    StartupLog.write("Cannot start: no desktop display is accessible to this process")
    fputs("Agent Cats cannot access the desktop. Open it from Finder or Terminal in your logged-in desktop session.\n", stderr)
    exit(1)
}
let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.agentcats.app")
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
if !others.isEmpty {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.agentcats.reveal"), object: nil, userInfo: nil, deliverImmediately: true)
    StartupLog.write("Asked existing Agent Cats instance to reveal its room")
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
