import AppKit
import SwiftUI

// Menu bar mode: the rail lives under Reflex's menu bar icon instead of at
// the screen's edge. A click on the icon opens a panel with what the rail
// shows beside its column — the question waiting on you, or every agent —
// and the column's actions along its foot. The icon carries the counts the
// edge tab would: amber for questions, blue for agents at work.

@MainActor
final class MenuBarModel: ObservableObject {
    static let shared = MenuBarModel()
    @Published var open = false
    /// The content's measured size, for taking the mouse over it.
    @Published var size: CGSize = .zero
    /// From the panel window's left edge to the content's: the window never
    /// moves while shown, the content lines up under the icon inside it.
    @Published var inset: CGFloat = 0
}

struct MenuBarPanel: View {
    static let window = NSUserInterfaceItemIdentifier("reflex.menu-bar")
    /// The panel window: as large as the content can get, and clear.
    static let windowSize = NSSize(width: 520, height: 760)

    enum Mode: Equatable { case question, agents, empty }

    @ObservedObject var model = MenuBarModel.shared
    @ObservedObject var store = Store.shared
    @ObservedObject var archive = SessionArchive.shared
    @ObservedObject var rail = RailModel.shared
    @ObservedObject var updater = Updater.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    @FocusState private var focused: Bool
    var openAgent: (AgentInfo) -> Void
    var openBar: (AgentInfo?) -> Void
    var reveal: (AgentInfo) -> Void
    var openInbox: () -> Void
    var openSettings: () -> Void
    var openPhone: () -> Void
    var restart: () -> Void
    var openLog: () -> Void
    var quit: () -> Void
    var close: () -> Void

    /// The waiting question, unless you asked for the list; the list when
    /// nothing waits (here, unlike the rail, it is what you came for).
    static func mode(_ rail: RailModel, _ store: Store) -> Mode {
        let agents = store.state.agents
        if rail.panel == .agents && !agents.isEmpty { return .agents }
        if Rail.card(rail, store.state.inbox) != nil { return .question }
        return agents.isEmpty ? .empty : .agents
    }

    private var mode: Mode { MenuBarPanel.mode(rail, store) }
    private var questions: [ItemInfo] { Rail.questions(store.state.inbox) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.open {
                VStack(alignment: .leading, spacing: 8) {
                    content
                    if let v = updater.pending { update(v) }
                    footer
                }
                .padding(10)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.size = $0 }
                .transition(.asymmetric(
                    insertion: .modifier(active: SurfaceFX(opacity: 0, scale: 0.98, y: reduce ? 0 : -6, blur: 3),
                                         identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0)),
                    removal: .opacity.animation(Motion.exit)))
            }
        }
        .padding(.leading, model.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(model.open ? Motion.enter : Motion.exit, value: model.open)
        .animation(Motion.swap, value: mode)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { key($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.identifier == MenuBarPanel.window { focused = true }
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .question:
            if let q = Rail.card(rail, store.state.inbox) {
                VStack(alignment: .leading, spacing: 8) {
                    QuestionCard(item: q, count: questions.count, index: rail.cardIndex,
                                 agent: store.state.agents.first { $0.pane == q.pane },
                                 pending: store.state.pending.first { $0.item == q.id },
                                 openAgent: openAgent,
                                 showAgents: store.state.agents.isEmpty ? nil : { rail.panel = .agents })
                    KeyHint(keys: q.options.prefix(3).map(\.key))
                }
                .transition(.surface(reduce: reduce))
            }
        case .agents:
            AgentList(agents: store.state.agents, pulses: store.pulses, waiting: questions.count,
                      background: archive.backgroundSessions,
                      open: openAgent, ask: { openBar($0) }, reveal: reveal,
                      showQuestion: { rail.panel = .question })
                .transition(.surface(reduce: reduce))
        case .empty:
            VStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 22)).foregroundStyle(Ink.dim)
                Text("No agents running").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                Text("Press ⌥⌥ to ask for something.").font(.system(size: 11.5)).foregroundStyle(Ink.dim)
            }
            .frame(width: 340)
            .padding(.vertical, 18)
            .raySurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .transition(.surface(reduce: reduce))
        }
    }

    /// The rail column's buttons, in a row.
    private var footer: some View {
        HStack(spacing: 2) {
            action("tray", "Inbox", badge: store.state.inbox.count, openInbox)
            action("sparkle", "Ask (⌥⌥)") { openBar(nil) }
            action("gearshape", "Settings", openSettings)
            Spacer(minLength: 8)
            Menu {
                Button("Take Reflex with You…", systemImage: "iphone", action: openPhone)
                if Updater.available { Button(updater.menuTitle) { Updater.check() } }
                Divider()
                Button("Restart reflexd", action: restart)
                Button("Open log", action: openLog)
                Divider()
                Button("Quit Reflex", action: quit)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.dim)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        // As wide as what is above it: the stack is as wide as its widest.
        .frame(maxWidth: .infinity)
        .raySurface(Capsule())
    }

    /// A version Sparkle found while Reflex was in the background.
    private func update(_ version: String) -> some View {
        Button {
            close()
            Updater.check()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Tone.done)
                Text("Reflex \(version) is available").foregroundStyle(Ink.text)
                Spacer(minLength: 8)
                Text("Update…").foregroundStyle(Ink.dim)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .raySurface(Capsule())
        .transition(.surface(reduce: reduce))
    }

    private func action(_ symbol: String, _ help: String, badge: Int = 0, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Ink.text)
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                            .background(Tone.blocked, in: Capsule())
                            .offset(x: 2, y: -1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .help(help)
    }

    /// As on the rail (1–9 answer, ⇥ next, typing filters the list); esc
    /// clears a filter first, then closes.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard model.open else { return .ignored }
        if press.key == .escape && (mode != .agents || rail.filter.isEmpty) { close(); return .handled }
        switch mode {
        case .question: return Rail.key(press, mode: .question)
        case .agents: return Rail.key(press, mode: .agents)
        case .empty: return .ignored
        }
    }
}
