import SwiftUI

// The rail, at the right edge of the screen.
//
//   tab       While an agent is active, a small dark tab grows out of the edge:
//             a spinning ring per working agent, amber for waiting, green for
//             done. Hover it to open the rail.
//   rail      A column of dark round buttons — inbox, agents, Ask / Settings /
//             Guide, more — and, when something waits on you, its question as
//             a card you answer with 1, 2 or 3.
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
}

// MARK: - Shared pieces

enum Ink {
    static let surface = Color(hex: "#0f0f11")
    static let raised = Color(hex: "#1a1a1d")
    static let hover = Color(hex: "#242428")
    static let line = Color.white.opacity(0.09)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.55)
}

/// An agent's state, the way the tab and rail draw it.
struct AgentGlyph: View {
    var status: String
    var size: CGFloat = 12
    var pulse: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var spin = false

    var body: some View {
        ZStack {
            switch status {
            case "working":
                Circle().stroke(Tone.working.opacity(0.25), lineWidth: 1.6)
                Circle().trim(from: 0, to: 0.72)
                    .stroke(Tone.working, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(reduce ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            case "blocked":
                Circle().fill(Tone.blocked).frame(width: size * 0.62, height: size * 0.62)
            case "done":
                Circle().fill(Tone.done).frame(width: size * 0.62, height: size * 0.62)
            default:
                Circle().fill(Color.white.opacity(0.28)).frame(width: size * 0.5, height: size * 0.5)
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
        .onAppear { spin = true }
    }
}

/// The tab's outline: rounded on the screen side, with concave "ears" where it
/// meets the screen edge, so it reads as growing out of the edge.
struct EdgeTabShape: Shape {
    var ear: CGFloat = 9
    var radius: CGFloat = 12
    func path(in r: CGRect) -> Path {
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

/// Plain Liquid Glass: grey and frosted, the desktop showing through.
extension Glass {
    static var rail: Glass { .regular }
}

private struct RoundButton<Label: View>: View {
    var help: String
    var action: () -> Void
    @ViewBuilder var label: Label
    var body: some View {
        Button(action: action) {
            label
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .glassEffect(.rail.interactive(), in: Circle())
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

struct Rail: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var rail = RailModel.shared
    @ObservedObject var settings = Settings.shared
    @ObservedObject var inbox = InboxModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var glass
    /// The dot under the pointer, which shows its status beside it.
    @State private var hoverDot: String?
    var openInbox: () -> Void
    var openAgent: (AgentInfo) -> Void
    /// Open the command bar, pinned to an agent when one is given.
    var openBar: (AgentInfo?) -> Void
    var reveal: (AgentInfo) -> Void
    var openSettings: () -> Void
    var restart: () -> Void
    var openLog: () -> Void
    var quit: () -> Void

    static func active(_ agents: [AgentInfo]) -> [AgentInfo] {
        agents.filter { ["working", "blocked", "done"].contains($0.status) }
    }

    static func questions(_ inbox: [ItemInfo]) -> [ItemInfo] {
        inbox.filter { ($0.kind == "ask" || $0.kind == "route") && !$0.options.isEmpty }
    }

    private var questions: [ItemInfo] { Rail.questions(store.state.inbox) }

    private var card: ItemInfo? {
        questions.indices.contains(rail.cardIndex) ? questions[rail.cardIndex] : questions.first
    }

    /// What sits beside the buttons: the waiting question, or — only once you
    /// click the dots — every agent. Nothing while the inbox is open beside it.
    private var showing: RailModel.Panel {
        if inbox.shown { return .auto }
        switch rail.panel {
        case .agents where !store.state.agents.isEmpty: return .agents
        default: return card != nil ? .question : .auto
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            ZStack(alignment: .trailing) {
                if rail.visible {
                    open
                        .transition(.asymmetric(
                            insertion: .modifier(active: SurfaceFX(opacity: 0, scale: 0.97, y: 0, blur: 4), identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0))
                                .combined(with: .offset(x: reduce ? 0 : 18)),
                            removal: .opacity.combined(with: .offset(x: reduce ? 0 : 12))))
                } else if !Rail.active(store.state.agents).isEmpty && settings.showStrip {
                    tab.transition(.opacity.combined(with: .offset(x: reduce ? 0 : 14)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(rail.visible ? Motion.enter : Motion.exit, value: rail.visible)
        .animation(Motion.spring, value: Rail.active(store.state.agents).map(\.pane))
        .animation(Motion.enter, value: showing)
        .environment(\.colorScheme, .dark)
        // One look whether or not the rail has the keys: it takes them while the
        // pointer is over it, and glass would otherwise change as they come and go.
        .environment(\.controlActiveState, .inactive)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in key(press) }
        .onChange(of: rail.visible) { _, open in if !open { rail.panel = .auto } }
    }

    /// With the pointer over the rail, 1–9 answer the card; ⇥ shows the next one.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard rail.visible else { return .ignored }
        if press.characters.lowercased() == "u", let p = store.state.pending.last {
            Task { await Client.local.cancel(p.id); await Store.shared.refresh() }
            return .handled
        }
        guard showing == .question else { return .ignored }
        if press.key == .tab, questions.count > 1 {
            rail.cardIndex = (rail.cardIndex + 1) % questions.count
            return .handled
        }
        guard let c = card, press.characters.count == 1, c.options.contains(where: { $0.key == press.characters }) else {
            return .ignored
        }
        Task { await Client.local.answer(item: c.id, key: press.characters); await Store.shared.refresh() }
        return .handled
    }

    // MARK: Tab

    private var tab: some View {
        VStack(spacing: 11) {
            ForEach(Rail.active(store.state.agents).prefix(8)) { a in
                AgentGlyph(status: a.status, size: 11, pulse: store.pulses[a.pane] ?? 0)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.vertical, 9 + 12)
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .glassEffect(.rail, in: EdgeTabShape())
        .glassEffectID("agents", in: glass)
    }

    // MARK: Open rail

    private var open: some View {
        HStack(alignment: .center, spacing: 12) {
            switch showing {
            case .question:
                if let q = card {
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
                          open: openAgent, ask: { openBar($0) }, reveal: reveal,
                          showQuestion: { rail.panel = .question })
                    .transition(.surface(reduce: reduce))
            case .auto:
                EmptyView()
            }
            column
        }
        .padding(.trailing, 10)
    }

    private func toggleAgents() {
        if inbox.shown { InboxModel.shared.shown = false }
        rail.panel = showing == .agents ? .auto : .agents
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
                VStack(spacing: 2) {
                    ForEach(store.state.agents.prefix(10)) { a in
                        Button(action: toggleAgents) {
                            AgentGlyph(status: a.status, size: 12, pulse: store.pulses[a.pane] ?? 0)
                                .frame(width: 40, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Pressable())
                        .onHover { h in hoverDot = h ? a.pane : (hoverDot == a.pane ? nil : hoverDot) }
                        .overlay(alignment: .trailing) {
                            if hoverDot == a.pane && showing != .agents {
                                StatusPill(agent: a)
                                    .fixedSize()
                                    .offset(x: -48)
                                    .transition(.opacity.combined(with: .offset(x: 6)))
                                    .allowsHitTesting(false)
                            }
                        }
                        .animation(Motion.micro, value: hoverDot)
                        .accessibilityLabel("\(a.kind) in \(a.folder), \(StatusPill.word(a.status))")
                    }
                }
                .padding(.vertical, 6)
                .glassEffect(.rail.interactive(), in: Capsule())
                .glassEffectID("agents", in: glass)
                .help(showing == .agents ? "Hide agents" : "Show agents")
            }

            VStack(spacing: 0) {
                PillButton(symbol: "sparkle", help: "Ask (⌥⌥)") { openBar(nil) }
                PillButton(symbol: "gearshape", help: "Settings", action: openSettings)
            }
            .padding(.vertical, 4)
            .glassEffect(.rail, in: Capsule())

            Menu {
                Button("Restart reflexd", action: restart)
                Button("Open log", action: openLog)
                Divider()
                Button("Quit Reflex", action: quit)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.dim)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassEffect(.rail.interactive(), in: Circle())
            .help("More")
        }
    }
}

/// getone-style: hovering a dot names its state beside it.
private struct StatusPill: View {
    var agent: AgentInfo

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
            Circle().fill(Tone.of(agent.status)).frame(width: 6, height: 6)
            Text(agent.folder).foregroundStyle(Ink.dim)
            Text(StatusPill.word(agent.status)).foregroundStyle(Ink.text)
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.rail, in: Capsule())
    }
}

// MARK: - Agents at a glance

/// Every agent, grouped by project: what it is doing, and one click to its
/// terminal, a message, or herdr.
private struct AgentList: View {
    var agents: [AgentInfo]
    var pulses: [String: Int]
    var waiting: Int
    var open: (AgentInfo) -> Void
    var ask: (AgentInfo) -> Void
    var reveal: (AgentInfo) -> Void
    var showQuestion: () -> Void
    @State private var rowsHeight: CGFloat = 0

    /// Folders in order of first appearance, waiting agents' folders first.
    private var groups: [(String, [AgentInfo])] {
        let rank: [String: Int] = ["blocked": 0, "working": 1, "done": 2]
        var order: [String] = []
        var by: [String: [AgentInfo]] = [:]
        for a in agents.sorted(by: { (rank[$0.status] ?? 3) < (rank[$1.status] ?? 3) }) {
            if by[a.folder] == nil { order.append(a.folder) }
            by[a.folder, default: []].append(a)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    private var summary: String {
        let w = agents.filter { $0.status == "working" }.count
        let b = agents.filter { $0.status == "blocked" }.count
        var parts: [String] = []
        if w > 0 { parts.append("\(w) working") }
        if b > 0 { parts.append("\(b) waiting") }
        return parts.isEmpty ? (agents.count == 1 ? "1 agent" : "\(agents.count) agents") : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Agents").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text)
                Text(summary).font(.system(size: 11.5)).foregroundStyle(Ink.dim)
                    .contentTransition(.numericText())
                Spacer(minLength: 4)
                if waiting > 0 {
                    Button(action: showQuestion) {
                        HStack(spacing: 4) {
                            Circle().fill(Tone.blocked).frame(width: 6, height: 6)
                            Text(waiting == 1 ? "1 question" : "\(waiting) questions")
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.text)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Tone.blocked.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(Pressable())
                    .fixedSize()
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.0) { folder, list in
                        Text(folder.uppercased())
                            .font(.system(size: 10, weight: .semibold)).tracking(0.9)
                            .foregroundStyle(Ink.dim.opacity(0.8))
                            .lineLimit(1)
                            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
                        ForEach(list) { a in
                            AgentRow(agent: a, pulse: pulses[a.pane] ?? 0,
                                     open: { open(a) }, ask: { ask(a) }, reveal: { reveal(a) })
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            // As tall as the rows, up to a point; then it scrolls.
            .frame(height: min(max(rowsHeight, 44), 500))
        }
        .frame(width: 356)
        .glassEffect(.rail, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct AgentRow: View {
    var agent: AgentInfo
    var pulse: Int
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
        case "done": state = "done"
        default: state = "idle"
        }
        return "\(agent.kind) · \(state) · \(agent.place)"
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentGlyph(status: agent.status, size: 12, pulse: pulse).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.text).lineLimit(1)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Ink.dim).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                action("terminal", "Open terminal", open)
                action("sparkle", "Message this agent", ask)
                action("arrow.up.forward.app", "Show in herdr", reveal)
            }
            .opacity(hover ? 1 : 0.55)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hover ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(Motion.micro) { hover = h } }
        .help("\(agent.kind) in \(agent.place)")
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.text)
                .frame(width: 26, height: 26)
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
                            Capsule().fill(i == index ? Tone.working : Color.white.opacity(0.25))
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
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                        .background(Color.white.opacity(hoverKey == o.key ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(p.label.bare).font(.system(size: 11.5)).foregroundStyle(Ink.dim).lineLimit(1)
                        Spacer()
                        Text("U to undo").font(.system(size: 11.5)).foregroundStyle(Ink.dim)
                    }
                    CountdownLine(duration: Double(p.left) / 1000, tint: Tone.working).id(p.id)
                }
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
        .glassEffect(.rail, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .glassEffect(.rail, in: Capsule())
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
