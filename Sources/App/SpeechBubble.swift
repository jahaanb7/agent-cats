import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Floating panel for the bubble. Unlike the room panel it can become key, so the reply field
/// takes typing, but it never activates the app (your current app stays in front).
final class BubblePanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class BubbleAnim: ObservableObject {
    @Published var shown = 0          // characters revealed so far (typewriter)
    @Published var popped = false     // drives the pop-in spring
}

final class BubbleModel: ObservableObject {
    enum Status: Equatable { case idle, sending, sent, failed(String) }

    @Published var speech: Speech?
    @Published var cat = ""
    @Published var status: Status = .idle
    @Published var draft = ""
    /// Files and screenshots going out with the next reply (sent as their paths).
    @Published var attachments: [URL] = []
    @Published var tailOnTop = true
    @Published var tailX: CGFloat = 150
    /// Bumped whenever a new message should pop in and type out again.
    @Published var generation = 0
    /// Other cats waiting to talk; the chip lets you hop to the next one.
    @Published var waiting = 0
    @Published var showHint = true
    /// Pop and typewriter progress live apart so ticking letters don't relayout the panel.
    let anim = BubbleAnim()
    var reduceMotion = false
    var focusField = false

    var onChoice: ((Speech.Choice) -> Void)?
    var onNext: (() -> Void)?
    var onSendText: ((String) -> Void)?
    var onChooseFiles: (() -> Void)?
    var onScreenshot: (() -> Void)?
    var onPasteImage: (() -> Void)?
    var onAddFiles: (([URL]) -> Void)?
    var onClose: (() -> Void)?
    var onOpenTerminal: (() -> Void)?
}

/// Speech-bubble outline with a small tail pointing at the cat.
struct BubbleShape: Shape {
    var tailOnTop: Bool
    var tailX: CGFloat
    static let tail: CGFloat = 9

    /// One continuous outline (body + tail) so the border runs around the tail, not across it.
    func path(in r: CGRect) -> Path {
        let t = Self.tail, c: CGFloat = 14, w: CGFloat = 8
        let b = tailOnTop ? CGRect(x: r.minX, y: r.minY + t, width: r.width, height: r.height - t)
                          : CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - t)
        let x = min(max(tailX, b.minX + c + w), b.maxX - c - w)
        var p = Path()
        p.move(to: CGPoint(x: b.minX + c, y: b.minY))
        if tailOnTop {
            p.addLine(to: CGPoint(x: x - w, y: b.minY))
            p.addLine(to: CGPoint(x: x, y: r.minY))
            p.addLine(to: CGPoint(x: x + w, y: b.minY))
        }
        p.addLine(to: CGPoint(x: b.maxX - c, y: b.minY))
        p.addArc(center: CGPoint(x: b.maxX - c, y: b.minY + c), radius: c, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - c))
        p.addArc(center: CGPoint(x: b.maxX - c, y: b.maxY - c), radius: c, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        if !tailOnTop {
            p.addLine(to: CGPoint(x: x + w, y: b.maxY))
            p.addLine(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x - w, y: b.maxY))
        }
        p.addLine(to: CGPoint(x: b.minX + c, y: b.maxY))
        p.addArc(center: CGPoint(x: b.minX + c, y: b.maxY - c), radius: c, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: b.minX, y: b.minY + c))
        p.addArc(center: CGPoint(x: b.minX + c, y: b.minY + c), radius: c, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

private enum Palette {
    static let paper = Color(red: 0.98, green: 0.95, blue: 0.88)
    static let ink = Color(red: 0.20, green: 0.22, blue: 0.17)
    static let line = Color(red: 0.29, green: 0.31, blue: 0.24)
    static let soft = Color(red: 0.45, green: 0.42, blue: 0.34)
    static let green = Color(red: 0.30, green: 0.50, blue: 0.40)
    static let orange = Color(red: 0.86, green: 0.47, blue: 0.24)
    static let red = Color(red: 0.75, green: 0.30, blue: 0.24)
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    @ObservedObject var anim: BubbleAnim
    init(model: BubbleModel) { self.model = model; anim = model.anim }
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if let speech = model.speech {
            content(speech)
                .padding(.horizontal, 14)
                .padding(.top, 12 + (model.tailOnTop ? BubbleShape.tail : 0))
                .padding(.bottom, 12 + (model.tailOnTop ? 0 : BubbleShape.tail))
                .frame(width: 300, alignment: .leading)
                .background(
                    BubbleShape(tailOnTop: model.tailOnTop, tailX: model.tailX)
                        .fill(Palette.paper)
                        .overlay(BubbleShape(tailOnTop: model.tailOnTop, tailX: model.tailX).stroke(Palette.line, lineWidth: 2))
                )
                .scaleEffect(anim.popped ? 1 : 0.6, anchor: UnitPoint(x: model.tailX / 300, y: model.tailOnTop ? 0 : 1))
                .opacity(anim.popped ? 1 : 0)
                .onAppear { start() }
                .onChange(of: model.generation) { _, _ in start() }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard speech.textReply != nil, model.status != .sent else { return false }
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            guard let url, url.isFileURL else { return }
                            DispatchQueue.main.async { model.onAddFiles?([url]) }
                        }
                    }
                    return true
                }
                .environment(\.colorScheme, .light)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(model.cat) says: \(speech.headline). \(speech.text)")
        }
    }

    private func content(_ speech: Speech) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(color(speech.mood)).frame(width: 8, height: 8)
                Text("\(model.cat.uppercased()) · \(speech.headline)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.waiting > 0 {
                    Button { model.onNext?() } label: {
                        Text("+\(model.waiting) more").font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(.white).background(Capsule().fill(Palette.orange))
                    }.buttonStyle(.plain).help("Another cat needs you. Click to hear it.")
                }
                Button { model.onClose?() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.soft)
                }.buttonStyle(.plain).help("Close (Esc)").accessibilityLabel("Close bubble")
            }
            // Typewriter text; the full text reserves the space so the bubble doesn't grow while typing.
            ZStack(alignment: .topLeading) {
                Text(speech.text).opacity(0)
                Text(String(speech.text.prefix(anim.shown)))
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(9)
            .textSelection(.enabled)
            .onTapGesture { anim.shown = speech.text.count }

            if model.status != .sent, !speech.choices.isEmpty {
                FlowButtons(choices: speech.choices, disabled: model.status == .sending) { model.onChoice?($0) }
            }
            if model.status != .sent, speech.textReply != nil {
                if !model.attachments.isEmpty { attachmentChips }
                HStack(spacing: 6) {
                    attachMenu
                    TextField(speech.placeholder, text: $model.draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color.white.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line.opacity(0.4), lineWidth: 1))
                        .focused($fieldFocused)
                        .onSubmit(send)
                        .disabled(model.status == .sending)
                    Button(action: send) {
                        Image(systemName: "paperplane.fill").font(.system(size: 12))
                            .foregroundStyle(.white).frame(width: 28, height: 26)
                            .background(Palette.green.opacity(canSend ? 1 : 0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(!canSend)
                        .accessibilityLabel("Send reply")
                }
            }
            statusLine
            if model.showHint && model.status == .idle {
                Text("Tip: double-click the cat to jump to its terminal")
                    .font(.system(size: 10)).foregroundStyle(Palette.soft.opacity(0.8))
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status {
        case .idle: EmptyView()
        case .sending: Label("Sending…", systemImage: "ellipsis").font(.system(size: 11)).foregroundStyle(Palette.soft)
        case .sent:
            Label("Got it — passing that along!", systemImage: "pawprint.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.green)
        case .failed(let why):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.red)
                Text(why).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Open") { model.onOpenTerminal?() }.controlSize(.small)
            }.font(.system(size: 11)).foregroundStyle(Palette.ink)
        }
    }

    private var canSend: Bool {
        model.status != .sending && (!model.draft.trimmingCharacters(in: .whitespaces).isEmpty || !model.attachments.isEmpty)
    }

    private func send() {
        guard canSend else { return }
        model.onSendText?(model.draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Paperclip: pick files, grab a screenshot, or paste an image from the clipboard.
    private var attachMenu: some View {
        Menu {
            Button("Choose Files…", systemImage: "doc") { model.onChooseFiles?() }
            Button("Take Screenshot…", systemImage: "camera.viewfinder") { model.onScreenshot?() }
            Button("Paste Image", systemImage: "doc.on.clipboard") { model.onPasteImage?() }
                .disabled(!Attachments.clipboardHasImage)
        } label: {
            Image(systemName: "paperclip").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.soft)
                .frame(width: 22, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.status == .sending)
        .help("Attach files or a screenshot. You can also drop files on the bubble.")
        .accessibilityLabel("Attach files or a screenshot")
    }

    private var attachmentChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.attachments, id: \.self) { url in
                HStack(spacing: 6) {
                    if let thumb = Attachments.thumbnail(url) {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: "doc.fill").font(.system(size: 12)).foregroundStyle(Palette.soft).frame(width: 22, height: 22)
                    }
                    Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button { model.attachments.removeAll { $0 == url } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.soft.opacity(0.8))
                    }.buttonStyle(.plain).accessibilityLabel("Remove \(url.lastPathComponent)")
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line.opacity(0.25), lineWidth: 1))
            }
        }
    }

    private func color(_ m: Speech.Mood) -> Color {
        switch m {
        case .permission, .question: return Palette.orange
        case .error: return Palette.red
        case .done: return Palette.green
        case .status: return Palette.soft
        }
    }

    /// Pop the bubble in, then type the message out.
    private func start() {
        let fullCount = model.speech?.text.count ?? 0
        if model.reduceMotion {
            anim.popped = true; anim.shown = fullCount
        } else {
            anim.popped = false; anim.shown = 0
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { anim.popped = true }
            }
            let gen = model.generation
            // Roughly 60 characters a second, capped at about a second and a half overall.
            let step = max(1, fullCount / 90)
            func tick() {
                guard gen == model.generation, anim.shown < fullCount else { return }
                anim.shown = min(fullCount, anim.shown + step)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: tick)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: tick)
        }
        if model.focusField {
            model.focusField = false
            DispatchQueue.main.async { fieldFocused = true }
        }
    }
}

/// Choice buttons that wrap onto extra rows when labels are long.
private struct FlowButtons: View {
    let choices: [Speech.Choice]
    let disabled: Bool
    let tap: (Speech.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r].indices, id: \.self) { i in
                        let c = rows[r][i]
                        Button { tap(c) } label: {
                            Text(c.label).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundStyle(c.primary ? Color.white : Palette.ink)
                                .background(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(c.primary ? Palette.green : Color.white)
                                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .inset(by: 0.5).stroke(Palette.line.opacity(c.primary ? 0 : 0.4), lineWidth: 1))
                                )
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(disabled)
                    }
                }
            }
        }
    }

    /// Greedy packing by an estimated label width (272pt usable).
    private var rows: [[Speech.Choice]] {
        var out: [[Speech.Choice]] = [[]]
        var width: CGFloat = 0
        for c in choices {
            let w = CGFloat(min(c.label.count, 40)) * 7 + 26
            if width + w > 272, !out[out.count - 1].isEmpty { out.append([]); width = 0 }
            out[out.count - 1].append(c); width += w + 6
        }
        return out
    }
}

/// Where pasted and captured images live, and how attachments are turned into text an agent can open.
enum Attachments {
    static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AgentCats/attachments", isDirectory: true)
    }

    static func newImageURL(_ prefix: String) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = folder.appendingPathComponent("\(prefix) \(f.string(from: Date())).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(prefix) \(f.string(from: Date())) \(n).png"); n += 1
        }
        return url
    }

    static var clipboardHasImage: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Saves the clipboard image as a PNG; returns nil when the clipboard holds no image.
    static func saveClipboardImage() -> URL? {
        // Copied files come back as their own URLs rather than a re-encoded image.
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first { return first }
        guard let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let url = newImageURL("Pasted image")
        do { try png.write(to: url); return url } catch { return nil }
    }

    static func reply(text: String, files: [URL]) -> String {
        Speech.withFiles(text, paths: files.map(\.path))
    }

    static func thumbnail(_ url: URL) -> NSImage? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Pasted images and screenshots are only needed for a while; clear out week-old ones.
    static func cleanUp() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: f) }
        }
    }
}
