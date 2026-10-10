import SwiftUI

// The rail, at the right edge of the screen.
//
//   tab       While an agent is active, a small dark tab grows out of the edge:
//             a spinning ring per working agent, amber for waiting, green for
//             done. Hover it to open the rail.
//   rail      A column of round glass buttons — inbox, the agents' dots, Ask /
//             Settings, more — and beside it, in its own window, the question
//             waiting on you (answer with 1, 2 or 3) or, once you click the
//             dots, every agent.
//
// With nothing active there is no tab: rest on the edge for half a second.

@MainActor
final class RailModel: ObservableObject {
    static let shared = RailModel()
    /// The rail (buttons and card) is open.
    @Published var visible = false
    /// 0…1 while the pointer rests on the edge (drawn by the sliver panel).
    @Published var dwell: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["REFLEX_DEBUG_DWELL"] ?? "") ?? 0)
    /// Which question card is showing when several wait.
    @Published var cardIndex = 0
    /// Beside the buttons: the question, the agent list, or whichever fits.
    enum Panel { case auto, question, agents }
    @Published var panel: Panel = .auto
    /// Typed while the pointer is on the agent list: filters it.
    @Published var filter = ""
    /// The list shows only this state ("blocked", "working", "done", "idle").
    @Published var stateFilter: String?
    /// The pointer is on the rail.
    @Published var hovering = false
    /// The dot under the pointer, whose status shows beside the column.
    @Published var hoverDot: String?
    /// Measured sizes of the open column and of what sits beside it; each
    /// window is made to fit its own.
    @Published var columnSize: CGSize = .zero
    @Published var sideSize: CGSize = .zero
    /// Where the rail is centred, in points from the top of its windows
    /// (which span the screen's height and never move while shown).
    @Published var anchor: CGFloat = 400
    /// The same for the edge tab, which stays where the rail last was.
    @Published var tabAnchor: CGFloat = 400
}

/// Puts each child at the trailing edge with its centre `y` points from the
/// top, kept within the bounds. The rail's windows span the screen and never
/// resize or move while shown: content is placed inside them in the same
/// layout pass that sizes it, so no frame is ever drawn in the wrong place
/// (a window resized under its content showed the old content shifted for a
/// frame — the jump).
struct Anchored: Layout {
    var y: CGFloat

    var animatableData: CGFloat {
        get { y }
        set { y = newValue }
    }

    static func top(_ y: CGFloat, height h: CGFloat, in H: CGFloat) -> CGFloat {
        min(max(y - h / 2, 0), max(0, H - h))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let top = Anchored.top(y, height: s.height, in: b.height)
            v.place(at: CGPoint(x: b.maxX - s.width, y: b.minY + top), anchor: .topLeading, proposal: ProposedViewSize(s))
        }
    }
}

// MARK: - Shared pieces

enum Ink {
    static let text = Color.primary.opacity(0.92)
    static let dim = Color.primary.opacity(0.55)
    static let line = Color.primary.opacity(0.1)
    static let hover = Color.primary.opacity(0.08)
}

/// An agent's state, the way the tab and rail draw it.
struct AgentGlyph: View {
    var status: String
    var size: CGFloat = 12
    var pulse: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            switch status {
            case "working":
                Circle().stroke(Tone.working.opacity(0.25), lineWidth: 1.6)
                // One turn every 0.9 s, read from the clock: it never stalls,
                // however the agent's state came and went.
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduce)) { ctx in
                    Circle().trim(from: 0, to: 0.72)
                        .stroke(Tone.working, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .rotationEffect(.degrees(reduce ? 0 : 360 * Loop.phase(ctx.date, period: 0.9)))
                }
            case "blocked":
                Circle().fill(Tone.blocked).frame(width: size * 0.62, height: size * 0.62)
            case "done":
                Circle().fill(Tone.done).frame(width: size * 0.62, height: size * 0.62)
            default:
                Circle().fill(Color.primary.opacity(0.28)).frame(width: size * 0.5, height: size * 0.5)
            }
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: pulse) { v, s in v.scaleEffect(s) } keyframes: { _ in
            if reduce {
                LinearKeyframe(1, duration: 0.01)
            } else {
                SpringKeyframe(1.5, duration: 0.14, spring: .snappy)
                SpringKeyframe(1, duration: 0.3, spring: .bouncy)
            }
        }
    }
}

/// The tab's outline: rounded on the screen side, with concave "ears" where it
/// meets the screen edge, so it reads as growing out of the edge.
struct EdgeTabShape: InsettableShape {
    var ear: CGFloat = 9
    var radius: CGFloat = 12
    var inset: CGFloat = 0
    func inset(by amount: CGFloat) -> EdgeTabShape {
        var s = self
        s.inset += amount
        return s
    }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let w = r.width, h = r.height, f = ear, c = min(radius, (h - 2 * f) / 2)
        var p = Path()
        p.move(to: CGPoint(x: w, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - f, y: f), control: CGPoint(x: w, y: f))
        p.addLine(to: CGPoint(x: c, y: f))
        p.addQuadCurve(to: CGPoint(x: 0, y: f + c), control: CGPoint(x: 0, y: f))
        p.addLine(to: CGPoint(x: 0, y: h - f - c))
        p.addQuadCurve(to: CGPoint(x: c, y: h - f), control: CGPoint(x: 0, y: h - f))
        p.addLine(to: CGPoint(x: w - f, y: h - f))
        p.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w, y: h - f))
        p.closeSubpath()
        return p
    }
}

private struct RoundButton<Label: View>: View {
    var help: String
    var action: () -> Void
    @ViewBuilder var label: Label
    var body: some View {
        Button(action: action) {
            label
                .frame(width: 40, height: 40)
                .raySurface(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .help(help)
    }
}


private struct PillButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(hover ? Ink.text : Ink.dim)
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { h in withAnimation(Motion.micro) { hover = h } }
        .help(help)
    }
}

// MARK: - The rail
//
// Two windows: the button column (and the tab) in one that never changes
// size while the rail is open, and what sits beside it — the question card,
// the agent list, a dot's status pill — in a second, sized to its content.
// So nothing in the column can shift when the side content comes and goes,
// and neither window is ever larger than what it shows.

/// What sits beside the column.
enum RailSideMode: Equatable {
    case none, question, agents
    /// A hovered dot's status pill, at that dot's row.
    case pill(index: Int, status: String, label: String, word: String)
}

/// One row of the dot column or the edge tab: an agent, or — once there are
/// too many to show one by one — a state and how many agents are in it.
enum RailDot: Identifiable, Equatable {
    case agent(AgentInfo)
    case state(String, Int)

    var id: String {
        switch self {
        case .agent(let a): return a.pane
        case .state(let s, _): return "state:" + s
        }
    }

    var status: String {
        switch self {
        case .agent(let a): return Rail.norm(a.status)
        case .state(let s, _): return s
        }
    }
}

extension Rail {
    /// The button column alone: 40 pt buttons, the badge's overhang, the edge margin.
    static let columnWidth: CGFloat = 60
    /// Past these, the tab and the dots count agents per state instead.
    static let tabLimit = 5
    static let dotLimit = 8
    static let states = ["blocked", "working", "done", "idle"]

    static func norm(_ status: String) -> String { states.contains(status) ? status : "idle" }

    /// Waiting first, then working, done, idle; most recently switched first within.
    @MainActor static func ordered(_ agents: [AgentInfo]) -> [AgentInfo] {
        let rank = Dictionary(uniqueKeysWithValues: states.enumerated().map { ($1, $0) })
        return Recents.shared.sorted(agents).enumerated().sorted { l, r in
            let a = rank[norm(l.element.status)]!, b = rank[norm(r.element.status)]!
            return a != b ? a < b : l.offset < r.offset
        }.map(\.element)
    }

    /// One dot per agent while they fit; past `limit`, one row per state.
    @MainActor static func dots(_ agents: [AgentInfo], limit: Int) -> [RailDot] {
        if agents.count <= limit { return ordered(agents).map { .agent($0) } }
        return states.compactMap { s in
            let n = agents.filter { norm($0.status) == s }.count
            return n > 0 ? .state(s, n) : nil
        }
    }

    /// The edge tab's height for these rows (glyphs, or glyph-and-count).
    @MainActor static func tabHeight(_ agents: [AgentInfo]) -> CGFloat {
        let rows = dots(active(agents), limit: tabLimit)
        let body = rows.reduce(CGFloat(0)) { h, r in
            if case .state = r { return h + 23 } else { return h + 11 }
        }
        return 42 + body + 11 * CGFloat(max(0, rows.count - 1))
    }

    static func active(_ agents: [AgentInfo]) -> [AgentInfo] {
        agents.filter { ["working", "blocked", "done"].contains($0.status) }
    }

    static func questions(_ inbox: [ItemInfo]) -> [ItemInfo] {
        inbox.filter { ($0.kind == "ask" || $0.kind == "route") && !$0.options.isEmpty }
    }

    static func card(_ rail: RailModel, _ inbox: [ItemInfo]) -> ItemInfo? {
        let q = questions(inbox)
        return q.indices.contains(rail.cardIndex) ? q[rail.cardIndex] : q.first
    }

    /// The waiting question; every agent only once you click the dots; a
    /// pill while a dot is hovered; nothing while the inbox is open.
    @MainActor static func side(_ rail: RailModel, _ store: Store, inboxShown: Bool) -> RailSideMode {
        guard rail.visible, !inboxShown else { return .none }
        let agents = store.state.agents
        if rail.panel == .agents && !agents.isEmpty { return .agents }
        let rows = dots(agents, limit: dotLimit)
        if rail.panel != .agents, let id = rail.hoverDot, let i = rows.firstIndex(where: { $0.id == id }) {
            switch rows[i] {
            case .agent(let a): return .pill(index: i, status: norm(a.status), label: a.folder, word: StatusPill.word(a.status))
            case .state(let s, let n): return .pill(index: i, status: s, label: "\(n)", word: StatusPill.word(s).lowercased())
            }
        }
        return card(rail, store.state.inbox) != nil ? .question : .none
    }

    /// With the pointer over the rail: 1–9 answer the card, ⇥ shows the next
    /// one, U takes back the last send.
    @MainActor static func key(_ press: KeyPress) -> KeyPress.Result {
        let rail = RailModel.shared, store = Store.shared
        guard rail.visible else { return .ignored }
        let mode = side(rail, store, inboxShown: InboxModel.shared.shown)
        if mode == .agents {
            if press.key == .escape { rail.filter = ""; return .handled }
            if press.key == .delete { if !rail.filter.isEmpty { rail.filter.removeLast() }; return .handled }
            let c = press.characters
            if c.count == 1, let ch = c.first, ch.isLetter || ch.isNumber || ch == " " || ch == "-" || ch == "_" || ch == "." {
                rail.filter.append(ch)
                return .handled
            }
            return .ignored
        }
        guard mode == .question else { return .ignored }
        let qs = questions(store.state.inbox)
        if press.key == .tab, qs.count > 1 {
            rail.cardIndex = (rail.cardIndex + 1) % qs.count
            return .handled
        }
        guard let c = card(rail, store.state.inbox), press.characters.count == 1,
              c.options.contains(where: { $0.key == press.characters }) else { return .ignored }
        Task { await Client.local.answer(item: c.id, key: press.characters); await Store.shared.refresh() }
        return .handled
    }

    /// Top of the column to the centre of dot `i` (see `column`).
    static func dotCenter(_ i: Int) -> CGFloat { 40 + 10 + 6 + 28 * CGFloat(i) + 14 }
}

/// The tab, and the open column.
struct Rail: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var rail = RailModel.shared
    @ObservedObject var settings = Settings.shared
    @ObservedObject var inbox = InboxModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var glass
    var openInbox: () -> Void
    var openBar: (AgentInfo?) -> Void
    var openSettings: () -> Void
    var restart: () -> Void
    var openLog: () -> Void
    var openPhone: () -> Void
    var quit: () -> Void

    private var side: RailSideMode { Rail.side(rail, store, inboxShown: inbox.shown) }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            Anchored(y: rail.anchor) {
              ZStack(alignment: .trailing) {
                if rail.visible {
                    column
                        .padding(.trailing, 10)
                        .padding(.vertical, 12)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { rail.columnSize = $0 }
                        .transition(.asymmetric(
                            insertion: .modifier(active: SurfaceFX(opacity: 0, scale: 0.97, y: 0, blur: 4), identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0))
                                .combined(with: .offset(x: reduce ? 0 : 18)),
                            removal: .opacity.combined(with: .offset(x: reduce ? 0 : 12))))
                }
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(rail.visible ? Motion.enter : Motion.exit, value: rail.visible)
        .animation(Motion.spring, value: Rail.active(store.state.agents).map(\.pane))
        // One look whether or not the rail has the keys: it takes them while the
        // pointer is over it, and glass would otherwise change as they come and go.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { Rail.key($0) }
        .onChange(of: rail.visible) { _, open in
            if !open { rail.panel = .auto; rail.hoverDot = nil; rail.filter = ""; rail.stateFilter = nil }
        }
    }

    // MARK: Column

    private func open(_ row: RailDot) {
        if case .state(let s, _) = row {
            // Straight to that state's agents; the same row again puts them away.
            if side == .agents && rail.stateFilter == s { toggleAgents(); return }
            rail.stateFilter = s
            if side != .agents { toggleAgents() }
            return
        }
        rail.stateFilter = nil
        toggleAgents()
    }

    private func accessibility(_ row: RailDot) -> String {
        switch row {
        case .agent(let a): return "\(a.kind) in \(a.folder), \(StatusPill.word(a.status))"
        case .state(let s, let n): return "\(n) agents \(StatusPill.word(s).lowercased())"
        }
    }

    private func toggleAgents() {
        if inbox.shown { InboxModel.shared.shown = false }
        let next: RailModel.Panel = side == .agents ? .auto : .agents
        // The pill goes at once, unanimated, so it never sits over the list
        // as the list comes in; then the list animates in on its own.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { rail.hoverDot = nil }
        DispatchQueue.main.async { rail.panel = next }
    }

    private var column: some View {
        VStack(spacing: 10) {
            RoundButton(help: "Inbox", action: openInbox) {
                Image(systemName: "tray").font(.system(size: 15)).foregroundStyle(Ink.text)
            }
            .overlay(alignment: .topTrailing) {
                if store.state.inbox.count > 0 {
                    Text("\(min(store.state.inbox.count, 99))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Tone.blocked, in: Circle())
                        .offset(x: 4, y: -4)
                        .contentTransition(.numericText(value: Double(store.state.inbox.count)))
                }
            }

            if !store.state.agents.isEmpty {
                // The dots: click for every agent's details, click again to put them away.
                // Up to 8, one dot per agent; past that, one row per state with
                // its count — click it for the list, filtered to that state.
                VStack(spacing: 0) {
                    ForEach(Rail.dots(store.state.agents, limit: Rail.dotLimit)) { row in
                        Button { open(row) } label: {
                            Group {
                                switch row {
                                case .agent(let a):
                                    AgentGlyph(status: a.status, size: 12, pulse: store.pulses[a.pane] ?? 0)
                                case .state(let s, let n):
                                    VStack(spacing: 0) {
                                        AgentGlyph(status: s, size: 10)
                                        Text(verbatim: "\(n)").font(.system(size: 9, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Ink.dim).contentTransition(.numericText(value: Double(n)))
                                    }
                                }
                            }
                            .frame(width: 40, height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(Pressable())
                        .onHover { h in
                            if h {
                                rail.hoverDot = row.id
                            } else {
                                // A beat before letting go: sliding to the next dot
                                // moves the pill instead of dropping and redrawing it.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                    if rail.hoverDot == row.id { rail.hoverDot = nil }
                                }
                            }
                        }
                        .accessibilityLabel(accessibility(row))
                    }
                }
                .padding(.vertical, 6)
                .raySurface(Capsule())
                .help(side == .agents ? "Hide agents" : "Show agents")
            }

            VStack(spacing: 0) {
                PillButton(symbol: "sparkle", help: "Ask (⌥⌥)") { openBar(nil) }
                PillButton(symbol: "gearshape", help: "Settings", action: openSettings)
            }
            .padding(.vertical, 4)
            .raySurface(Capsule())

            Menu {
                Button("Take Reflex with You…", systemImage: "iphone", action: openPhone)
                Divider()
                Button("Restart reflexd", action: restart)
                Button("Open log", action: openLog)
                Divider()
                Button("Quit Reflex", action: quit)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.dim)
                    .frame(width: 40, height: 40)
                    .raySurface(Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }
}


/// The edge tab, in its own window that stays where it is: opening the rail
/// at another height fades the tab out here and the rail in there — nothing
/// slides or jumps across the screen.
struct RailTab: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var rail = RailModel.shared
    @ObservedObject var settings = Settings.shared
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Anchored(y: rail.tabAnchor) {
            ZStack(alignment: .trailing) {
                if !rail.visible && !Rail.active(store.state.agents).isEmpty && settings.showStrip {
                    tab.transition(.opacity.combined(with: .offset(x: reduce ? 0 : 14)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(rail.visible ? Motion.exit : Motion.enter, value: rail.visible)
        .animation(Motion.spring, value: Rail.active(store.state.agents).map(\.pane))
    }

    private var tab: some View {
        VStack(spacing: 11) {
            ForEach(Rail.dots(Rail.active(store.state.agents), limit: Rail.tabLimit)) { row in
                switch row {
                case .agent(let a):
                    AgentGlyph(status: a.status, size: 11, pulse: store.pulses[a.pane] ?? 0)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                case .state(let s, let n):
                    // Many agents: the state, and how many are in it.
                    VStack(spacing: 1) {
                        AgentGlyph(status: s, size: 11)
                        Text(verbatim: "\(n)").font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Ink.dim).contentTransition(.numericText(value: Double(n)))
                    }
                    .frame(height: 23)
                    .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 9 + 12)
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .raySurface(EdgeTabShape())
    }

}

/// Beside the column, in its own window: the question card, the agent list,
/// or a hovered dot's pill. Only this animates when it changes.
struct RailSide: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var archive = SessionArchive.shared
    @ObservedObject var rail = RailModel.shared
    @ObservedObject var inbox = InboxModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    var openAgent: (AgentInfo) -> Void
    var openBar: (AgentInfo?) -> Void
    var reveal: (AgentInfo) -> Void

    private var mode: RailSideMode { Rail.side(rail, store, inboxShown: inbox.shown) }
    private var questions: [ItemInfo] { Rail.questions(store.state.inbox) }

    var body: some View {
        Anchored(y: rail.anchor) {
            ZStack(alignment: .trailing) {
                content
                    // 12 pt to the column; the same vertical margins as the column.
                    .padding(.trailing, 12)
                    .padding(.vertical, 12)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { rail.sideSize = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.enter, value: mode)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { Rail.key($0) }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .question:
            if let q = Rail.card(rail, store.state.inbox) {
                VStack(spacing: 10) {
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
        case .pill(let i, let status, let label, let word):
            // Level with its dot: the same height as the column, pill at the dot's row.
            VStack(spacing: 0) {
                Color.clear.frame(height: max(0, Rail.dotCenter(i) - 13))
                StatusPill(status: status, label: label, word: word).fixedSize().frame(height: 26)
                Spacer(minLength: 0)
            }
            .frame(height: max(26, rail.columnSize.height - 24), alignment: .top)
            .transition(.asymmetric(
                insertion: .modifier(active: SurfaceFX(opacity: 0, scale: 0.96, y: 0, blur: 3), identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0))
                    .combined(with: .offset(x: reduce ? 0 : 6)),
                removal: .opacity.animation(Motion.exit)))
            .animation(Motion.swap, value: i)
        case .none:
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

/// getone-style: hovering a dot names its state beside it.
private struct StatusPill: View {
    var status: String
    var label: String
    var word: String

    static func word(_ status: String) -> String {
        switch status {
        case "working": return "Working"
        case "blocked": return "Needs you"
        case "done": return "Done"
        default: return "Idle"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Tone.of(status)).frame(width: 6, height: 6)
            Text(label).foregroundStyle(Ink.dim)
            Text(word).foregroundStyle(Ink.text)
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .raySurface(Capsule())
    }
}

// MARK: - Agents at a glance

/// Every agent, grouped by project: what it is doing, and one click to its
/// terminal, a message, or herdr.
private struct AgentList: View {
    var agents: [AgentInfo]
    var pulses: [String: Int]
    var waiting: Int
    /// `claude --bg` sessions, running or stopped: one click brings them here.
    var background: [PastSession] = []
    var open: (AgentInfo) -> Void
    var ask: (AgentInfo) -> Void
    var reveal: (AgentInfo) -> Void
    var showQuestion: () -> Void
    @State private var rowsHeight: CGFloat = 0
    @ObservedObject private var rail = RailModel.shared
    private var query: String { rail.filter }

    /// Past this many agents a filter appears; the list is built for dozens.
    static let filterAt = 12

    @State private var expanded: Set<String> = []
    /// A project shows this many sessions, then "Show N more".
    static let groupLimit = 5

    private var shown: [AgentInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let inState = rail.stateFilter.map { s in agents.filter { Rail.norm($0.status) == s } } ?? agents
        guard !q.isEmpty else { return inState }
        return inState.filter { a in
            [a.title, a.folder, a.kind, a.status].contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
            .foregroundStyle(Ink.dim.opacity(0.75))
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 1)
    }

    /// States present, with counts: the chips that narrow the list.
    private var chips: [(String, Int)] {
        Rail.states.compactMap { s in
            let n = agents.filter { Rail.norm($0.status) == s }.count
            return n > 0 ? (s, n) : nil
        }
    }

    private func chip(_ label: String, _ on: Bool, _ tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let tint { Circle().fill(tint).frame(width: 5, height: 5) }
                Text(label)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(on ? Ink.text : Ink.dim)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.primary.opacity(on ? 0.14 : 0.05), in: Capsule())
            .fixedSize()
        }
        .buttonStyle(Pressable())
    }

    /// Folders in order of first appearance, waiting agents' folders first.
    private var groups: [(String, [AgentInfo])] {
        let rank: [String: Int] = ["blocked": 0, "working": 1, "done": 2]
        var order: [String] = []
        var by: [String: [AgentInfo]] = [:]
        _ = rank
        for a in Rail.ordered(shown) {
            if by[a.folder] == nil { order.append(a.folder) }
            by[a.folder, default: []].append(a)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    private var summary: String {
        let w = agents.filter { $0.status == "working" }.count
        let b = agents.filter { $0.status == "blocked" }.count
        var parts = [agents.count == 1 ? "1 agent" : "\(agents.count) agents"]
        if w > 0 { parts.append("\(w) working") }
        if b > 0 { parts.append("\(b) waiting") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(summary).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.dim)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                Spacer(minLength: 4)
                if waiting > 0 {
                    Button(action: showQuestion) {
                        HStack(spacing: 4) {
                            Circle().fill(Tone.blocked).frame(width: 5, height: 5)
                            Text(waiting == 1 ? "1 question" : "\(waiting) questions")
                            Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Ink.text)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Tone.blocked.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(Pressable())
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 3)

            // Many agents: narrow by state.
            if agents.count > Rail.dotLimit {
                HStack(spacing: 4) {
                    chip("All \(agents.count)", rail.stateFilter == nil, nil) { withAnimation(Motion.swap) { rail.stateFilter = nil } }
                    ForEach(chips, id: \.0) { s, n in
                        chip("\(StatusPill.word(s)) \(n)", rail.stateFilter == s, Tone.of(s)) {
                            withAnimation(Motion.swap) { rail.stateFilter = rail.stateFilter == s ? nil : s }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
            // Type while the pointer is on the list to filter it (no field to click).
            if agents.count > AgentList.filterAt || !query.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.dim)
                    if query.isEmpty {
                        Text("Type to filter \(agents.count) agents").foregroundStyle(Ink.dim)
                    } else {
                        Text(query).foregroundStyle(Ink.text)
                        Text("· esc to clear").foregroundStyle(Ink.dim)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .padding(.horizontal, 8).padding(.bottom, 3)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // A project gets a header only when it holds two or more
                    // agents; one-agent projects stay a flat list that names
                    // each folder — under "Other" only when real groups are above.
                    let multi = groups.filter { $0.1.count > 1 }
                    let singles = Rail.ordered(groups.filter { $0.1.count == 1 }.flatMap(\.1))
                    ForEach(multi, id: \.0) { folder, list in
                        header(folder)
                        // A big project shows its first few; the rest one click away.
                        let folded = query.isEmpty && list.count > AgentList.groupLimit + 1 && !expanded.contains(folder)
                        ForEach(folded ? Array(list.prefix(AgentList.groupLimit)) : list) { a in
                            AgentRow(agent: a, pulse: pulses[a.pane] ?? 0, showFolder: false,
                                     open: { open(a) }, ask: { ask(a) }, reveal: { reveal(a) })
                        }
                        if folded {
                            Button {
                                withAnimation(Motion.swap) { _ = expanded.insert(folder) }
                            } label: {
                                Text("Show \(list.count - AgentList.groupLimit) more")
                                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Ink.dim)
                                    .padding(.horizontal, 28).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(Pressable())
                        }
                    }
                    if !singles.isEmpty {
                        if !multi.isEmpty { header("Other") }
                        ForEach(singles) { a in
                            AgentRow(agent: a, pulse: pulses[a.pane] ?? 0, showFolder: true,
                                     open: { open(a) }, ask: { ask(a) }, reveal: { reveal(a) })
                        }
                    }
                    if !background.isEmpty && query.isEmpty {
                        header("Background")
                        ForEach(background) { p in BackgroundRow(session: p) }
                    }
                }
                .padding(.horizontal, 4).padding(.top, groups.contains { $0.1.count > 1 } ? 0 : 3).padding(.bottom, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            // As tall as the rows, up to a point; then it scrolls.
            .frame(height: min(max(rowsHeight, 30), 520))
        }
        .frame(width: 340)
        .raySurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A `claude --bg` session: running ones attach, stopped ones resume, into a
/// herdr workspace; its terminal opens once it is up.
private struct BackgroundRow: View {
    var session: PastSession
    @State private var hover = false
    @State private var busy = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.state == .running ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 9.5)).foregroundStyle(session.state == .running ? Tone.working : Ink.dim).frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                Text("\(session.agent) · \(session.folder) · " + (session.state == .running ? "running" : "stopped") + " · \(session.ago)")
                    .font(.system(size: 10.5)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if busy { ProgressView().controlSize(.mini) }
            if hover && session.agent == "claude" {
                CloseSessionButton(pane: "", size: 20, tint: Ink.dim, word: "Remove",
                                   help: session.state == .running ? "Stop and delete this background session…" : "Delete this background session…",
                                   confirm: { Sessions.removeBackground(session) })
                    .transition(.opacity)
            }
            Text(session.state == .running ? "Attach" : "Resume")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Ink.text)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.primary.opacity(hover ? 0.14 : 0.08), in: Capsule())
                .opacity(hover ? 1 : 0.6)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !busy else { return }
            busy = true
            Task {
                _ = try? await Sessions.resume(session, open: true)
                busy = false
            }
        }
        .onHover { h in withAnimation(Motion.micro) { hover = h } }
        .help(session.state == .running ? "Attach to it in herdr" : "Resume it in herdr")
    }
}

/// One line of title, one of state — about 30 pt, so dozens fit.
private struct AgentRow: View {
    var agent: AgentInfo
    var pulse: Int
    var showFolder = false
    var open: () -> Void
    var ask: () -> Void
    var reveal: () -> Void
    @State private var hover = false

    private var title: String { agent.title.isEmpty ? "\(agent.kind) · \(agent.folder)" : agent.title }

    private var subtitle: String {
        let state: String
        switch agent.status {
        case "working": state = "working"
        case "blocked": state = "needs you"
        case "done": state = "done, unread"
        default: state = "idle"
        }
        return ([agent.kind] + (showFolder ? [agent.folder] : []) + [state]).joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            AgentGlyph(status: agent.status, size: 9, pulse: pulse).frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Ink.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                action("terminal", "Open terminal", open)
                action("sparkle", "Message this agent", ask)
                action("arrow.up.forward.app", "Show in herdr", reveal)
                CloseSessionButton(pane: agent.pane)
            }
            .opacity(hover ? 1 : 0.45)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(Motion.micro) { hover = h } }
        .help("\(agent.kind) in \(agent.place)")
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Ink.text)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .help(help)
    }
}


// MARK: - Question card

/// The line just above a question's options: usually the question itself.
func questionLine(_ body: String) -> String? {
    let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard let first = lines.firstIndex(where: { $0.range(of: #"^[❯>›]?\s*1[.)]\s"#, options: .regularExpression) != nil }) else {
        return lines.last
    }
    return first > 0 ? lines[first - 1] : nil
}

private struct QuestionCard: View {
    var item: ItemInfo
    var count: Int
    var index: Int
    var agent: AgentInfo?
    var pending: PendingInfo?
    var openAgent: (AgentInfo) -> Void
    var showAgents: (() -> Void)?
    @State private var hoverKey: String?

    private var title: String {
        if item.kind == "route" { return "Where should this go?" }
        if let t = agent?.title, !t.isEmpty { return t }
        return "Needs you"
    }

    private var question: String {
        item.kind == "route" ? item.body : (questionLine(item.body) ?? "Waiting for your answer")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                Spacer()
                if count > 1 {
                    HStack(spacing: 4) {
                        ForEach(0..<min(count, 5), id: \.self) { i in
                            Capsule().fill(i == index ? Tone.working : Color.primary.opacity(0.25))
                                .frame(width: i == index ? 14 : 5, height: 5)
                        }
                    }
                    .onTapGesture { RailModel.shared.cardIndex = (index + 1) % count }
                    .help("⇥ next question")
                }
                if let showAgents {
                    Button(action: showAgents) {
                        Image(systemName: "list.bullet").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.dim)
                    }
                    .buttonStyle(.plain)
                    .help("All agents")
                }
                Button {
                    Task { await Client.local.dismiss(item.id); await Store.shared.refresh() }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.dim)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            HStack(spacing: 10) {
                AgentGlyph(status: item.kind == "route" ? "working" : "blocked", size: 14)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.agent).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(item.kind == "route" ? "Pick where your request goes" : "Waiting for your answer · \(agent?.folder ?? "")")
                        .font(.system(size: 11.5)).foregroundStyle(Ink.dim)
                }
            }
            Text(question).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(item.options) { o in
                    Button {
                        Task { await Client.local.answer(item: item.id, key: o.key); await Store.shared.refresh() }
                    } label: {
                        HStack(spacing: 10) {
                            Text(o.key).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Ink.dim)
                                .frame(width: 18, height: 18)
                                .background(Ink.hover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            Text(o.label.bare).font(.system(size: 13)).foregroundStyle(Ink.text)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(Color.primary.opacity(hoverKey == o.key ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Ink.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable())
                    .onHover { h in hoverKey = h ? o.key : (hoverKey == o.key ? nil : hoverKey) }
                    .disabled(pending != nil)
                    .opacity(pending != nil ? 0.5 : 1)
                }
            }
            if let p = pending {
                Label(p.label.bare, systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.dim).lineLimit(1)
                    .transition(.blurSwap)
            }
            if let a = agent {
                Button { openAgent(a) } label: {
                    Label("Open terminal", systemImage: "terminal").font(.system(size: 11.5)).foregroundStyle(Ink.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 340)
        .raySurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(Motion.enter, value: pending?.id)
    }
}

private struct KeyHint: View {
    var keys: [String]
    var body: some View {
        HStack(spacing: 6) {
            Text("Press").foregroundStyle(Ink.dim)
            ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                // The comma hugs its key ("1, 2 or 3"); "or" keeps normal spacing.
                HStack(spacing: 1) {
                    Text(k).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(Ink.text)
                        .frame(width: 17, height: 17)
                        .background(Ink.hover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    if i < keys.count - 2 { Text(",").foregroundStyle(Ink.dim) }
                }
                if i == keys.count - 2 { Text("or").foregroundStyle(Ink.dim) }
            }
            Text("to answer").foregroundStyle(Ink.dim)
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 14).padding(.vertical, 8)
        .raySurface(Capsule())
    }
}

// MARK: - Sliver

/// While the pointer rests on an empty edge, a thin line grows there for the
/// half second before the rail opens. It lives in its own fixed panel, so
/// nothing about the rail's layout can move it.
struct Sliver: View {
    @ObservedObject var rail = RailModel.shared
    var body: some View {
        ZStack(alignment: .trailing) {
            Capsule()
                .fill(Tone.working)
                .frame(width: 4, height: 16 + 64 * rail.dwell)
                .shadow(color: Tone.working.opacity(0.6 * rail.dwell), radius: 5)
                .opacity(rail.dwell > 0.12 && !rail.visible ? Double(0.4 + 0.6 * rail.dwell) : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 2)
        .animation(.linear(duration: 0.05), value: rail.dwell)
    }
}

// MARK: - Keys

/// An invisible window that holds the keyboard while the pointer is on the
/// rail, so the rail's own windows never become key — becoming key would
/// switch their glass to its darker active look instantly.
struct RailKeys: View {
    @FocusState private var focused: Bool
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { Rail.key($0) }
            .onAppear { focused = true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
    }
}
