import AppKit
import SwiftUI

final class DashboardModel: ObservableObject {
    @Published var entries: [CatTreeView.Entry] = []
    @Published var selection: String?
    @Published var approvals: [PendingApproval] = []
    @Published var decisionMessage: String?
    @Published var showHookSetup = false
    @Published var hookPreview = ""
    @Published var hookMessage: String?
    @Published var connectionMessage: String?
    private var hookChanges: [HookInstaller.Change] = []
    private var installer: HookInstaller {
        HookInstaller(hookBinary: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agentcats-hook").path)
    }
    var canInstallHooks: Bool { !hookChanges.isEmpty }

    func previewHooks() {
        hookMessage = nil
        do {
            hookChanges = try installer.plan()
            hookPreview = hookChanges.isEmpty ? "Agent Cats hooks are already up to date." : hookChanges.map(HookInstaller.diff).joined(separator: "\n")
        } catch {
            hookChanges = []
            hookPreview = error.localizedDescription
        }
        showHookSetup = true
    }

    func installHooks() {
        do {
            // A settings edit after preview must be reviewed again, never overwritten.
            let current = try installer.plan()
            guard current.count == hookChanges.count,
                  zip(current, hookChanges).allSatisfy({ $0.path == $1.path && $0.before == $1.before && $0.after == $1.after }) else {
                previewHooks()
                hookMessage = "Settings changed since the preview. Review the updated changes before installing."
                return
            }
            _ = try installer.apply(hookChanges)
            hookChanges = []
            hookMessage = "Hooks installed with backups. Restart your agent sessions to load them. Claude approval requests can now wait here for up to two minutes."
        } catch { hookMessage = error.localizedDescription }
    }

    var onDecision: ((String, ApprovalProtocol.Decision) -> Void)?

    func decide(_ request: PendingApproval, _ decision: ApprovalProtocol.Decision) {
        approvals.removeAll { $0.id == request.id }
        decisionMessage = nil
        onDecision?(request.id, decision)
    }
}

final class DashboardController {
    let model = DashboardModel()
    private var window: NSWindow?

    func show(session: String? = nil) {
        if let session { model.selection = session }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Agent Cats — Mission Control"
            w.minSize = NSSize(width: 700, height: 460)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DashboardView(model: model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    private var selected: CatTreeView.Entry? {
        model.entries.first { $0.session.id == model.selection } ?? model.entries.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("AGENT CATS").font(.system(.headline, design: .monospaced))
                Text("\(model.entries.count) sessions · \(model.entries.filter { $0.session.state.needsAttention }.count) need you")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.entries, id: \.session.id) { entry in
                            Button { model.selection = entry.session.id } label: {
                                HStack(alignment: .top) {
                                    Circle().fill(color(entry.session.state)).frame(width: 8, height: 8).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.cat + " · " + entry.session.project).fontWeight(.semibold)
                                        Text(entry.session.agent.displayName + " · " + entry.session.state.displayLabel)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected?.session.id == entry.session.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if let message = model.connectionMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                Button("Set up agent hooks…", systemImage: "link") { model.previewHooks() }
                    .font(.caption)
            }.padding(20).frame(width: 250)
            Divider()
            if let entry = selected {
                ScrollView {
                    details(entry).padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "pawprint.fill").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Your cats are resting").font(.title2)
                    Text("Start a Claude Code or Codex session. Its cat will appear here automatically.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 310)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $model.showHookSetup) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect agent hooks").font(.title2.bold())
                Text("Hooks improve live status and let you allow or deny Claude tool requests here. Existing hooks are preserved, and changed files are backed up.")
                    .foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(model.hookPreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(12).background(Color.primary.opacity(0.05))
                if let message = model.hookMessage { Text(message).font(.callout) }
                HStack {
                    Spacer()
                    Button("Close") { model.showHookSetup = false }
                    Button("Install hooks") { model.installHooks() }.disabled(!model.canInstallHooks)
                }
            }.padding(24).frame(width: 650, height: 450)
        }
    }

    private func details(_ entry: CatTreeView.Entry) -> some View {
        let s = entry.session
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.cat).font(.largeTitle.bold())
                    Text(s.title ?? s.project).font(.title3).textSelection(.enabled)
                }
                Spacer()
                Text(s.state.displayLabel).font(.caption.bold()).padding(8)
                    .background(color(s.state).opacity(0.16)).clipShape(Capsule())
            }
            ForEach(model.approvals.filter { $0.sessionID == s.id }) { request in
                approvalCard(request)
            }
            if let message = model.decisionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if s.state.needsAttention && !model.approvals.contains(where: { $0.sessionID == s.id }) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(s.state == .permission ? "Approval requested" : s.state.displayLabel, systemImage: "exclamationmark.bubble")
                        .font(.headline)
                    Text(s.activity ?? "Open this session to review the request.").textSelection(.enabled)
                    Text("Review and respond in the agent’s window.").font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Button("Open agent window", systemImage: "arrow.up.forward.app") { TerminalJump.open(s) }
                    .disabled(s.pid == nil && s.tty == nil)
                if !s.cwd.isEmpty {
                    Button("Project folder", systemImage: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd)) }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
                metric("Agent", s.agent.displayName)
                metric("Model", s.model ?? "–")
                metric("Project", s.cwd.isEmpty ? "–" : s.cwd)
                metric("Activity", s.activity ?? "–")
                metric("State source", s.hookSeen ? "Hooks connected" : "Session logs")
                metric("Tokens · in / out", "\(s.usage.input.formatted()) / \(s.usage.output.formatted())")
                metric("Cache hit rate", s.usage.cacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "–")
                metric("Context used", s.contextPercent.map { String(format: "%.1f%%", $0) } ?? "–")
                metric("Reported cost", s.costUSD.map { String(format: "$%.3f", $0) } ?? "–")
                ForEach(Array(s.rateLimits.enumerated()), id: \.offset) { _, limit in
                    metric(limit.name + " usage", String(format: "%.0f%%", limit.usedPercent))
                }
            }.font(.callout)
            Divider()
            Text("RECENT ACTIVITY").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if s.recent.isEmpty { Text("Waiting for session events…").foregroundStyle(.secondary) }
            ForEach(Array(s.recent.reversed().enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private func approvalCard(_ request: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Approve “" + request.tool + "”?", systemImage: "hand.raised.fill").font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(request.input).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 160).padding(10).background(Color.primary.opacity(0.05))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(request.expiresAt.timeIntervalSince(context.date)))
                VStack(alignment: .leading, spacing: 10) {
                    Text(remaining > 0 ? "Returns to the agent’s prompt in \(remaining)s." : "Request expired. Continue in the agent’s window.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Allow once") { model.decide(request, .allow) }
                        Button("Deny", role: .destructive) { model.decide(request, .deny) }
                        Button("Handle in agent") { model.decide(request, .handoff) }
                    }.disabled(remaining == 0)
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(_ state: CatState) -> Color {
        switch state {
        case .permission, .question: return .orange
        case .error: return .red
        case .working, .thinking: return .green
        case .done: return .blue
        case .idle, .gone: return .gray
        }
    }
}
