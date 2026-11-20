import SwiftUI
import AppKit

/// The first-run walkthrough. Shown once automatically; "Take the tour" in the menu replays it.
final class TourController {
    private var window: NSWindow?
    private let book: SpriteBook?
    private static let seenKey = "agentcats.tourSeen"

    init(book: SpriteBook?) { self.book = book }

    var shouldAutoShow: Bool { !UserDefaults.standard.bool(forKey: Self.seenKey) }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false; w.level = .floating
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = NSHostingView(rootView: TourView(book: book) { [weak self] in self?.window?.close(); self?.window = nil })
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct TourCat: View {
    let book: SpriteBook?
    var coat = "Miso"
    var state: CatState = .idle
    var accessory: String? = nil
    var scale: CGFloat = 3.5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 6)) { ctx in
            let frame = Int(ctx.date.timeIntervalSinceReferenceDate * 6)
            let (look, dy) = poseLook(frame)
            Group {
                if let img = book?.image(look) { Image(decorative: img, scale: 1).interpolation(.none).resizable() } else { Color.clear }
            }
            .frame(width: CGFloat(SpriteBook.canvasW) * scale, height: CGFloat(SpriteBook.canvasH) * scale)
            .offset(y: -CGFloat(dy) * scale)
        }
    }

    private func poseLook(_ frame: Int) -> (SpriteBook.Look, Int) {
        var (look, dy) = catLook(coat: coat, agent: "claude", state: state, frame: frame, sinceState: 5, still: false)
        if let accessory { look.accessory = accessory == "none" ? nil : accessory }
        return (look, dy)
    }
}

private struct MockCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(12).frame(width: 250, alignment: .leading).pixelCard(Pix.paper)
    }
}

private func chip(_ text: String, filled: Bool = false) -> some View {
    Text(text).font(Pix.mono(10, .heavy)).padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(filled ? Pix.cream : Pix.ink).background(filled ? Pix.green : Pix.paper)
        .overlay(Rectangle().stroke(Pix.line, lineWidth: 2))
}

final class TourStep: ObservableObject { @Published var step = 0 }

struct TourView: View {
    let book: SpriteBook?
    let finish: () -> Void
    @StateObject private var model: TourStep
    init(book: SpriteBook?, start: Int = 0, finish: @escaping () -> Void) {
        self.book = book; self.finish = finish
        _model = StateObject(wrappedValue: { let m = TourStep(); m.step = start; return m }())
    }
    private var step: Int { get { model.step } nonmutating set { model.step = newValue } }
    private let titles = ["Meet your cats", "They ask in plain English", "Chat and queue", "See what got done", "Make them yours"]
    private let bodies = [
        "Every Claude Code or Codex session you start gets its own cat in the menu bar room. Typing cats are busy, reading cats are thinking, sleeping cats are idle.",
        "When an agent needs permission, its cat pops up a bubble with one plain sentence. Click Allow or Deny. You never have to switch windows.",
        "Click a working cat to see what it's doing. Type a message and it's queued, then sent when the agent finishes its turn. Questions can be answered right in the bubble.",
        "Open the dashboard (Review ↗) for each task, the files changed and the cost. Double-click a cat to jump to its terminal, or right-click it to end the session.",
        "In the dashboard, pick a cat and open Style to change its coat and add a crown, bow, flower, glasses, shades or scarf. If the hooks sheet is open, click Install hooks to finish setup.",
    ]

    var body: some View {
        VStack(spacing: 16) {
            scene.frame(height: 190).frame(maxWidth: .infinity)
                .background(Pix.wall).overlay(Rectangle().stroke(Pix.line, lineWidth: 2))
            Text(titles[step].uppercased()).font(Pix.mono(18, .heavy)).foregroundStyle(Pix.ink)
            Text(bodies[step]).font(.system(size: 13)).foregroundStyle(Pix.soft)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 400)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(0..<titles.count, id: \.self) { Rectangle().fill($0 == step ? Pix.orange : Pix.line.opacity(0.3)).frame(width: 8, height: 8) }
            }
            HStack {
                Button { finish() } label: { Text("SKIP").font(Pix.mono(10, .heavy)).foregroundStyle(Pix.soft) }.buttonStyle(.plain)
                Spacer()
                if step > 0 { Button { step -= 1 } label: { chip("BACK") }.buttonStyle(.plain) }
                Button { if step == titles.count - 1 { finish() } else { step += 1 } } label: {
                    chip(step == titles.count - 1 ? "LET'S GO" : "NEXT", filled: true)
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 20)
        .frame(width: 520, height: 470)
        .background(Pix.paper)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private var scene: some View {
        switch step {
        case 0:
            HStack(spacing: 14) {
                TourCat(book: book, coat: "Miso", state: .working)
                TourCat(book: book, coat: "Mochi", state: .thinking)
                TourCat(book: book, coat: "Pepper", state: .done)
                TourCat(book: book, coat: "Sumi", state: .idle)
            }
        case 1:
            HStack(spacing: 14) {
                TourCat(book: book, coat: "Pepper", state: .permission)
                MockCard {
                    Text("PEPPER · CAN I DO THIS?").font(Pix.mono(9, .heavy)).foregroundStyle(Pix.orange)
                    Text("I want to deploy the site.").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pix.ink)
                    HStack { chip("ALLOW", filled: true); chip("DENY"); chip("IN TERMINAL") }
                }
            }
        case 2:
            HStack(spacing: 14) {
                TourCat(book: book, coat: "Miso", state: .working)
                MockCard {
                    Text("WORKING ON IT").font(Pix.mono(9, .heavy)).foregroundStyle(Pix.green)
                    Text("Building the checkout page. Ran the tests.").font(.system(size: 12)).foregroundStyle(Pix.ink)
                    Text("1  add a loading spinner  ×").font(Pix.mono(10, .medium)).foregroundStyle(Pix.soft)
                    chip("QUEUED · SENDS WHEN DONE")
                }
            }
        case 3:
            HStack(spacing: 14) {
                TourCat(book: book, coat: "Biscuit", state: .done)
                MockCard {
                    Text("LAST TASK").font(Pix.mono(9, .heavy)).foregroundStyle(Pix.soft)
                    Text("fix the flaky login test").font(.system(size: 13, weight: .semibold)).foregroundStyle(Pix.ink)
                    Text("changed 1 file · ran 4 commands · all 212 tests pass").font(.system(size: 11)).foregroundStyle(Pix.green)
                }
            }
        default:
            HStack(spacing: 10) {
                TourCat(book: book, coat: "Miso", state: .done, accessory: "crown", scale: 3)
                TourCat(book: book, coat: "Mochi", state: .done, accessory: "shades", scale: 3)
                TourCat(book: book, coat: "Pepper", state: .done, accessory: "bow", scale: 3)
                TourCat(book: book, coat: "Sumi", state: .done, accessory: "glasses", scale: 3)
            }
        }
    }
}
