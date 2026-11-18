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
    /// nil until checked; true when every agent's settings already carry the Agent Cats hooks.
    @Published var hooksReady: Bool?
    /// The cats' sprite sheet, shared with the room so the dashboard shows the very same cats.
    var book: SpriteBook?
    var reduceMotion = false
    private var hookChanges: [HookInstaller.Change] = []
    private var installer: HookInstaller {
        HookInstaller(hookBinary: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agentcats-hook").path)
    }
    var canInstallHooks: Bool { !hookChanges.isEmpty }

    func refreshHookStatus() {
        hooksReady = (try? installer.plan()).map(\.isEmpty)
    }

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
            hooksReady = true
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
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.refreshHookStatus()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Agent Cats"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .aqua)   // the room is always a warm, lit room
            w.backgroundColor = NSColor(Pix.wall)
            w.minSize = NSSize(width: 760, height: 500)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DashboardView(model: model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Design tokens (the same materials as the room and the speech bubble)

enum Pix {
    static let wall = Color(red: 0.91, green: 0.86, blue: 0.74)
    static let stripe = Color(red: 0.84, green: 0.79, blue: 0.67)
    static let paper = Color(red: 0.98, green: 0.95, blue: 0.88)
    static let forest = Color(red: 0.22, green: 0.32, blue: 0.28)
    static let cream = Color(red: 0.96, green: 0.91, blue: 0.79)
    static let ink = Color(red: 0.20, green: 0.22, blue: 0.17)
    static let line = Color(red: 0.29, green: 0.31, blue: 0.24)
    static let soft = Color(red: 0.45, green: 0.42, blue: 0.34)
    static let wood = Color(red: 0.62, green: 0.43, blue: 0.29)
    static let woodDark = Color(red: 0.43, green: 0.29, blue: 0.20)
    static let coral = Color(red: 0.88, green: 0.48, blue: 0.37)
    static let coralDark = Color(red: 0.62, green: 0.25, blue: 0.17)
    static let green = Color(red: 0.30, green: 0.50, blue: 0.40)
    static let orange = Color(red: 0.86, green: 0.47, blue: 0.24)
    static let red = Color(red: 0.75, green: 0.30, blue: 0.24)
    static let shadow = Color(red: 0.29, green: 0.31, blue: 0.24).opacity(0.85)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    static func tint(_ s: CatState) -> Color {
        switch s {
        case .permission, .question: return orange
        case .error: return red
        case .working, .thinking: return green
        case .done: return Color(red: 0.30, green: 0.45, blue: 0.62)
        case .idle, .gone: return soft
        }
    }

    static func label(_ s: Session) -> String {
        if s.asksForReply { return "ASKING" }
        switch s.state {
        case .permission: return "NEEDS OK"
        case .question: return "ASKING"
        case .error: return "STUCK"
        case .working: return "WORKING"
        case .thinking: return "THINKING"
        case .done: return "DONE"
        case .idle: return "NAPPING"
        case .gone: return "GONE HOME"
        }
    }
}

// MARK: - Pixel primitives

/// A box with stepped, pixel-art corners.
struct PixelBox: InsettableShape {
    var step: CGFloat = 3
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> PixelBox { var b = self; b.inset += amount; return b }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset), p = step
        var path = Path()
        path.move(to: CGPoint(x: r.minX + p, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - p, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - p, y: r.minY + p))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + p))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - p))
        path.addLine(to: CGPoint(x: r.maxX - p, y: r.maxY - p))
        path.addLine(to: CGPoint(x: r.maxX - p, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + p, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + p, y: r.maxY - p))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - p))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + p))
        path.addLine(to: CGPoint(x: r.minX + p, y: r.minY + p))
        path.closeSubpath()
        return path
    }
}

/// Paper card with an ink outline and a hard, offset pixel shadow, like the speech bubble.
struct PixelCard: ViewModifier {
    var fill: Color = Pix.paper
    var border: Color = Pix.line
    var lift: CGFloat = 3
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    PixelBox().fill(Pix.shadow).offset(x: lift, y: lift)
                    PixelBox().fill(fill)
                    PixelBox().strokeBorder(border, lineWidth: 2)
                }
            )
    }
}

extension View {
    func pixelCard(_ fill: Color = Pix.paper, border: Color = Pix.line, lift: CGFloat = 3) -> some View {
        modifier(PixelCard(fill: fill, border: border, lift: lift))
    }
}

/// Chunky button that physically presses into its shadow.
struct PixelButtonStyle: ButtonStyle {
    var fill: Color = Pix.paper
    var text: Color = Pix.ink
    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return configuration.label
            .font(Pix.mono(11))
            .foregroundStyle(text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                ZStack {
                    PixelBox(step: 2).fill(Pix.shadow).offset(x: 2, y: 2).opacity(down ? 0 : 1)
                    PixelBox(step: 2).fill(fill)
                    PixelBox(step: 2).strokeBorder(Pix.line, lineWidth: 2)
                }
            )
            .offset(x: down ? 2 : 0, y: down ? 2 : 0)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.06), value: down)
    }
}

/// A meter made of pixel blocks.
struct BlockMeter: View {
    var fraction: Double
    var blocks = 12
    var color: Color = Pix.green
    /// Turn orange near the top (context and rate limits); off for meters where high is good.
    var warnHigh = true
    var body: some View {
        HStack(spacing: 2) {
            let lit = Int((min(1, max(0, fraction)) * Double(blocks)).rounded(.up))
            ForEach(0..<blocks, id: \.self) { i in
                Rectangle()
                    .fill(i < lit ? (warnHigh && fraction > 0.85 ? Pix.orange : color) : Pix.stripe)
                    .frame(width: 7, height: 9)
            }
        }
    }
}

/// Small state tag, like a label stitched onto the cushion.
struct StateChip: View {
    let session: Session
    var body: some View {
        let tint = session.wantsYou ? Pix.orange : Pix.tint(session.state)
        Text(Pix.label(session))
            .font(Pix.mono(9, .heavy))
            .foregroundStyle(tint == Pix.soft ? Pix.ink : .white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(PixelBox(step: 2).fill(tint == Pix.soft ? Pix.stripe : tint))
    }
}

/// Where a session runs: a small stamped tag (terminal, editor, background, phone or browser).
struct OriginTag: View {
    let origin: SessionOrigin
    var large = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: origin.symbol).font(.system(size: large ? 10 : 9, weight: .bold))
            Text(origin.label.uppercased()).font(Pix.mono(large ? 9 : 8, .heavy)).lineLimit(1)
        }
        .foregroundStyle(origin == .remote ? Pix.orange : Pix.forest)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .overlay(PixelBox(step: 1.5).strokeBorder((origin == .remote ? Pix.orange : Pix.forest).opacity(0.55), lineWidth: 1))
        .help(help)
    }
    private var help: String {
        switch origin {
        case .terminal: return "Running in a terminal window on this Mac."
        case .editor: return "Running inside an editor on this Mac."
        case .desktop: return "Running in the Claude desktop app."
        case .background: return "Running in the background (a script, claude -p, the Agent SDK or codex exec). There's no window to jump to."
        case .remote: return "A session on this Mac that's being driven from your phone or a browser."
        }
    }
}

/// One of the room's cats, crisp at any size, animated at the room's 6 fps.
struct PixelCat: View {
    let entry: CatTreeView.Entry
    let book: SpriteBook?
    var scale: CGFloat = 2
    var animate = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: animate ? 1.0 / 6 : 3600)) { ctx in
            let frame = Int(ctx.date.timeIntervalSinceReferenceDate * 6) + abs(entry.session.id.hashValue % 7)
            let (look, dy) = catLook(coat: entry.cat, agent: entry.session.agent.rawValue, state: entry.session.state,
                                     frame: frame, sinceState: ctx.date.timeIntervalSince(entry.session.stateSince), still: !animate)
            Group {
                if let img = book?.image(look) {
                    Image(decorative: img, scale: 1).interpolation(.none).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: CGFloat(SpriteBook.canvasW) * scale, height: CGFloat(SpriteBook.canvasH) * scale)
            .offset(y: -CGFloat(dy) * scale)
        }
        .accessibilityHidden(true)
    }
}

/// The coral cushion the cats sit on in the room.
struct Cushion: View {
    var width: CGFloat
    var px: CGFloat = 3
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Pix.coral).frame(height: px)
            Rectangle().fill(Color(red: 0.78, green: 0.33, blue: 0.24)).frame(height: px)
            Rectangle().fill(Pix.coralDark).frame(height: px)
        }.frame(width: width)
    }
}

/// Faint vertical wallpaper stripes, as in the room.
struct Wallpaper: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 8
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Pix.stripe.opacity(0.55)))
                x += 16
            }
        }
        .background(Pix.wall)
    }
}

/// Wood floor with plank seams and a skirting board.
struct Floor: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Pix.wood))
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 3)), with: .color(Pix.woodDark))
            var x: CGFloat = 0
            var row = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 3, width: 1, height: size.height)), with: .color(Pix.woodDark.opacity(0.7)))
                x += row % 2 == 0 ? 36 : 44
                row += 1
            }
        }
        .frame(height: 14)
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    private var selected: CatTreeView.Entry? {
        model.entries.first { $0.session.id == model.selection } ?? model.entries.first
    }
    private var needYou: Int { model.entries.filter { $0.session.wantsYou }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                if !model.entries.isEmpty {
                    sidebar
                    Rectangle().fill(Pix.line.opacity(0.25)).frame(width: 2)
                }
                detailPane
            }
            Floor()
        }
        .background(Wallpaper())
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $model.showHookSetup) { hookSheet }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("AGENT CATS").font(Pix.mono(12, .heavy)).foregroundStyle(Pix.cream)
            Rectangle().fill(Pix.cream.opacity(0.35)).frame(width: 4, height: 4)
            Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(Pix.cream.opacity(0.75))
            Spacer()
            hookBadge
        }
        .padding(.leading, 80)          // clear the window buttons
        .padding(.trailing, 14)
        .frame(height: 38)
        .background(Pix.forest)
        .overlay(alignment: .bottom) { Rectangle().fill(Pix.ink.opacity(0.5)).frame(height: 2) }
    }

    private var subtitle: String {
        let n = model.entries.count
        if n == 0 { return "No sessions · your cats are resting" }
        let s = "\(n) session\(n == 1 ? "" : "s")"
        return needYou > 0 ? "\(s) · \(needYou) need\(needYou == 1 ? "s" : "") you" : "\(s) · all calm"
    }

    @ViewBuilder private var hookBadge: some View {
        if model.hooksReady == true {
            HStack(spacing: 6) {
                Rectangle().fill(Color(red: 0.55, green: 0.85, blue: 0.62)).frame(width: 6, height: 6)
                Text("LIVE").font(Pix.mono(10, .heavy)).foregroundStyle(Pix.cream)
            }
            .help("Hooks are installed: cats react the moment an agent asks for something.")
        } else {
            Button("CONNECT HOOKS") { model.previewHooks() }
                .buttonStyle(PixelButtonStyle(fill: Pix.orange, text: .white))
                .help("Without hooks, cats only learn about requests after the fact.")
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.entries, id: \.session.id) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
            }
            if let message = model.connectionMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(Pix.red)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .frame(width: 252)
    }

    private func row(_ entry: CatTreeView.Entry) -> some View {
        let s = entry.session
        let isSelected = selected?.session.id == s.id
        return Button { model.selection = s.id } label: {
            HStack(spacing: 10) {
                PixelCat(entry: entry, book: model.book, scale: 1.5, animate: !model.reduceMotion)
                    .frame(width: 42, height: 32)
                    .opacity(s.state == .gone ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.cat.uppercased()).font(Pix.mono(11, .heavy)).foregroundStyle(Pix.ink).lineLimit(1)
                        if s.wantsYou {
                            Rectangle().fill(Pix.orange).frame(width: 6, height: 6)
                        }
                    }
                    Text(s.project).font(.system(size: 11)).foregroundStyle(Pix.soft).lineLimit(1)
                    if let origin = Origins.of(s) { OriginTag(origin: origin) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(RowBackground(selected: isSelected, alert: s.wantsYou))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.cat), \(s.project), \(Pix.label(s).lowercased())")
    }

    // MARK: detail

    @ViewBuilder private var detailPane: some View {
        if let entry = selected {
            ScrollView {
                details(entry)
                    .padding(22)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .id(entry.session.id)
            .transition(.opacity)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            if let book = model.book {
                let napper = CatTreeView.Entry(session: Session(id: "napper", agent: .claude, at: .now), cat: "Mochi")
                PixelCat(entry: napper, book: book, scale: 4, animate: !model.reduceMotion)
                Cushion(width: 100, px: 4)
            }
            Text("YOUR CATS ARE NAPPING").font(Pix.mono(13, .heavy)).foregroundStyle(Pix.ink).padding(.top, 18)
            Text("Start a Claude Code or Codex session and its cat will hop onto a perch.")
                .font(.system(size: 12)).foregroundStyle(Pix.soft).multilineTextAlignment(.center)
                .frame(maxWidth: 280).padding(.top, 6)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func details(_ entry: CatTreeView.Entry) -> some View {
        let s = entry.session
        let requests = model.approvals.filter { $0.sessionID == s.id }
        return VStack(alignment: .leading, spacing: 18) {
            hero(entry)
            ForEach(requests) { approvalCard($0) }
            if let message = model.decisionMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(Pix.soft)
            }
            if s.wantsYou && requests.isEmpty { waitingCard(s) }
            stats(s)
            activity(s)
        }
    }

    private func hero(_ entry: CatTreeView.Entry) -> some View {
        let s = entry.session
        return HStack(alignment: .bottom, spacing: 18) {
            VStack(spacing: 0) {
                PixelCat(entry: entry, book: model.book, scale: 3.5, animate: !model.reduceMotion)
                    .opacity(s.state == .gone ? 0.55 : 1)
                Cushion(width: 88, px: 3.5)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.cat.uppercased()).font(Pix.mono(22, .heavy)).foregroundStyle(Pix.ink)
                    StateChip(session: s)
                }
                Text(s.title ?? s.project).font(.system(size: 14, weight: .semibold)).foregroundStyle(Pix.ink)
                    .lineLimit(2).textSelection(.enabled)
                HStack(spacing: 8) {
                    if let origin = Origins.of(s) { OriginTag(origin: origin, large: true) }
                    Text([s.agent.displayName, s.model, s.activity].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.system(size: 11)).foregroundStyle(Pix.soft).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Button("OPEN TERMINAL") { TerminalJump.open(s) }
                        .disabled(s.pid == nil && s.tty == nil)
                    if !s.cwd.isEmpty {
                        Button("FOLDER") { NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd)) }
                    }
                }
                .buttonStyle(PixelButtonStyle())
                .padding(.top, 6)
            }
            .padding(.bottom, 4)
            Spacer(minLength: 0)
        }
    }

    private func approvalCard(_ request: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Rectangle().fill(Pix.orange).frame(width: 8, height: 8)
                Text("CAN I RUN THIS?").font(Pix.mono(11, .heavy)).foregroundStyle(Pix.ink)
                Text(request.tool).font(Pix.mono(11, .regular)).foregroundStyle(Pix.soft)
            }
            requestPreview(request.input)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let remaining = max(0, request.expiresAt.timeIntervalSince(ctx.date))
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button("ALLOW") { model.decide(request, .allow) }
                            .buttonStyle(PixelButtonStyle(fill: Pix.green, text: .white))
                        Button("DENY") { model.decide(request, .deny) }
                            .buttonStyle(PixelButtonStyle())
                        Button("IN TERMINAL") { model.decide(request, .handoff) }
                            .buttonStyle(PixelButtonStyle())
                        Spacer(minLength: 8)
                        BlockMeter(fraction: remaining / ApprovalProtocol.timeout, blocks: 10, color: Pix.orange, warnHigh: false)
                        Text("\(Int(remaining))s").font(Pix.mono(10)).foregroundStyle(Pix.soft).frame(width: 30, alignment: .trailing)
                    }
                    .disabled(remaining == 0)
                    if remaining == 0 {
                        Text("This went back to the agent's own prompt.").font(.system(size: 11)).foregroundStyle(Pix.soft)
                    }
                }
            }
        }
        .padding(16)
        .pixelCard()
    }

    /// Shows a shell command as a command, other tool input as tidy JSON. Always left-aligned.
    @ViewBuilder private func requestPreview(_ input: String) -> some View {
        let obj = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any]
        VStack(alignment: .leading, spacing: 6) {
            if let command = obj?["command"] as? String {
                Text("$ " + command).font(Pix.mono(13, .semibold)).foregroundStyle(Pix.ink)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                if let why = obj?["description"] as? String {
                    Text(why).font(.system(size: 11)).foregroundStyle(Pix.soft)
                }
            } else if let path = obj?["file_path"] as? String {
                Text(path).font(Pix.mono(12, .semibold)).foregroundStyle(Pix.ink).lineLimit(2).truncationMode(.middle)
            } else {
                ScrollView(.vertical) {
                    Text(input).font(Pix.mono(11, .regular)).foregroundStyle(Pix.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 130)
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PixelBox(step: 2).fill(Color.white.opacity(0.7)))
    }

    private func waitingCard(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(s.state == .error ? Pix.red : Pix.orange).frame(width: 8, height: 8)
                Text(s.state == .error ? "I HIT A SNAG" : s.state == .permission ? "WAITING FOR YOUR OK" : "WAITING FOR YOU")
                    .font(Pix.mono(11, .heavy)).foregroundStyle(Pix.ink)
            }
            Text((s.state == .done ? s.lastMessage : s.activity ?? s.lastMessage) ?? "Open the session to see what it needs.")
                .font(.system(size: 13)).foregroundStyle(Pix.ink).lineLimit(8).textSelection(.enabled)
            Text("Click the cat in the room to answer, or open the terminal.")
                .font(.system(size: 11)).foregroundStyle(Pix.soft)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelCard()
    }

    private func stats(_ s: Session) -> some View {
        let tiles: [(String, String, Double?, Bool)] = [
            ("TOKENS", compact(s.usage.input + s.usage.output + s.usage.cacheRead + s.usage.cacheWrite), nil, false),
            ("CACHE", s.usage.cacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "–", s.usage.cacheHitRate, false),
            ("CONTEXT", s.contextPercent.map { String(format: "%.0f%%", $0) } ?? "–", s.contextPercent.map { $0 / 100 }, true),
            ("COST*", s.costUSD.map { String(format: "$%.2f", $0) } ?? "–", nil, false),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ForEach(tiles, id: \.0) { tile in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tile.0).font(Pix.mono(9, .heavy)).foregroundStyle(Pix.soft)
                        Text(tile.1).font(Pix.mono(18, .heavy)).foregroundStyle(Pix.ink).lineLimit(1).minimumScaleFactor(0.7)
                        if let f = tile.2 { BlockMeter(fraction: f, blocks: 8, warnHigh: tile.3) } else { Color.clear.frame(height: 9) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pixelCard(lift: 2)
                    .help(tile.0 == "COST*" ? "The agent's own API-equivalent estimate, not your bill." : "")
                }
            }
            if !s.rateLimits.isEmpty {
                HStack(spacing: 18) {
                    ForEach(Array(s.rateLimits.enumerated()), id: \.offset) { _, limit in
                        HStack(spacing: 8) {
                            Text(limit.name.uppercased()).font(Pix.mono(9, .heavy)).foregroundStyle(Pix.soft)
                            BlockMeter(fraction: limit.usedPercent / 100, blocks: 10)
                            Text(String(format: "%.0f%%", limit.usedPercent)).font(Pix.mono(10)).foregroundStyle(Pix.ink)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func activity(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ACTIVITY").font(Pix.mono(10, .heavy)).foregroundStyle(Pix.soft)
                Spacer()
                Text(s.hookSeen ? "via hooks" : "via session logs").font(.system(size: 10)).foregroundStyle(Pix.soft.opacity(0.8))
            }
            VStack(alignment: .leading, spacing: 5) {
                if s.recent.isEmpty {
                    Text("Waiting for the first event…").font(.system(size: 12)).foregroundStyle(Pix.soft)
                }
                ForEach(Array(readableLog(s.recent).prefix(14).enumerated()), id: \.offset) { _, line in
                    logLine(line)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixelCard(lift: 2)
        }
    }

    /// Newest first, without the bare "tool finished" lines that only add noise.
    private func readableLog(_ recent: [String]) -> [String] {
        recent.reversed().filter { $0.split(separator: " ").count > 2 || !$0.hasSuffix(" toolEnd") }
    }

    /// "12:03:44 toolStart Bash make" → dim time, coloured verb, the rest in ink.
    private func logLine(_ line: String) -> some View {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        let time = parts.first ?? "", kind = parts.count > 1 ? parts[1] : "", rest = parts.count > 2 ? parts[2] : ""
        let words = ["prompt": "you", "toolStart": "runs", "toolEnd": "ran", "toolFailed": "failed", "permission": "asks ok",
                     "question": "asks", "turnEnd": "done", "error": "error", "sessionStart": "wakes", "sessionEnd": "leaves",
                     "processExit": "leaves"]
        let tint: Color = {
            switch kind {
            case "permission", "question": return Pix.orange
            case "error", "toolFailed": return Pix.red
            case "turnEnd": return Color(red: 0.30, green: 0.45, blue: 0.62)
            case "toolStart", "toolEnd": return Pix.green
            default: return Pix.soft
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time).foregroundStyle(Pix.soft.opacity(0.75))
            Text(words[kind] ?? kind).foregroundStyle(tint).frame(width: 62, alignment: .leading)
            Text(rest).foregroundStyle(Pix.ink).lineLimit(1).truncationMode(.tail)
        }
        .font(Pix.mono(11, .regular))
        .textSelection(.enabled)
    }

    private func compact(_ n: Int) -> String {
        switch n {
        case 0: return "–"
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    // MARK: hooks sheet

    private var hookSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CONNECT AGENT HOOKS").font(Pix.mono(14, .heavy)).foregroundStyle(Pix.ink)
            Text("With hooks, a cat pops up the moment an agent asks for permission or a reply, and you can answer from the bubble. Your existing hooks stay, and every changed file is backed up first.")
                .font(.system(size: 12)).foregroundStyle(Pix.soft).fixedSize(horizontal: false, vertical: true)
            ScrollView([.horizontal, .vertical]) {
                Text(model.hookPreview).font(Pix.mono(11, .regular)).foregroundStyle(Pix.ink).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .pixelCard(Color.white.opacity(0.7), lift: 2)
            if let message = model.hookMessage { Text(message).font(.system(size: 12)).foregroundStyle(Pix.ink) }
            HStack(spacing: 10) {
                Spacer()
                Button("CLOSE") { model.showHookSetup = false }.buttonStyle(PixelButtonStyle())
                Button("INSTALL HOOKS") { model.installHooks() }
                    .buttonStyle(PixelButtonStyle(fill: Pix.green, text: .white))
                    .disabled(!model.canInstallHooks)
            }
        }
        .padding(24)
        .frame(width: 660, height: 460)
        .background(Pix.wall)
        .environment(\.colorScheme, .light)
    }
}

/// `@State` is a macro whose plugin ships only with full Xcode; this builds with the Command Line Tools.
private final class HoverState: ObservableObject { @Published var on = false }

/// Selected rows sit on paper with an outline and pixel shadow; others are bare on the wall.
private struct RowBackground: ViewModifier {
    let selected: Bool
    let alert: Bool
    @StateObject private var hover = HoverState()
    func body(content: Content) -> some View {
        content
            .background {
                if selected {
                    ZStack {
                        PixelBox().fill(Pix.shadow).offset(x: 3, y: 3)
                        PixelBox().fill(Pix.paper)
                        PixelBox().strokeBorder(alert ? Pix.orange : Pix.line, lineWidth: 2)
                    }
                } else if hover.on {
                    PixelBox().fill(Pix.paper.opacity(0.55))
                }
            }
            .onHover { hover.on = $0 }
            .animation(.easeOut(duration: 0.12), value: hover.on)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selected)
    }
}
