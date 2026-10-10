import SwiftUI

// ⌥⌥ opens this bar — instantly: it is used all day, so it does not animate
// in. Motion is spent on what happens after ⏎: Jev thinking, where the request
// is going, the undo window draining, and the arrival.

@MainActor
final class CommandModel: ObservableObject {
    enum Phase: Equatable {
        case typing
        case routing
        case pending(PendingInfo)
        case sent(String)
        case choose(title: String, item: Int?, options: [OptionInfo])
        case failed(String)
    }

    @Published var text = ""
    @Published var phase: Phase = .typing
    @Published var focusTick = 0
    /// An agent picked with Tab: the request goes straight there, no routing.
    @Published var target: String?
    @Published var shake: CGFloat = 0
    @Published var arrivals = 0
    /// False while the bar animates away (it appears instantly: used all day).
    @Published var shown = true
    /// The bar's measured size; its window fits it.
    @Published var size: CGSize = .zero
    private var lastText = ""
    var close: () -> Void = {}
    var openSetup: (Onboarding.Step) -> Void = { _ in }

    func reset() {
        text = ""
        target = nil
        phase = .typing
        focusTick += 1
    }

    func cycle(_ agents: [AgentInfo], back: Bool) {
        guard !agents.isEmpty else { return }
        let panes = agents.map(\.pane)
        let i = target.flatMap { panes.firstIndex(of: $0) }
        switch (i, back) {
        case (nil, false): target = panes.first
        case (nil, true): target = panes.last
        case (let i?, false): target = i + 1 < panes.count ? panes[i + 1] : nil
        case (let i?, true): target = i > 0 ? panes[i - 1] : nil
        }
    }

    func submit(agents: [AgentInfo]) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, phase == .typing else { return }
        lastText = text
        phase = .routing
        let pinned = agents.first { $0.pane == target }
        Task {
            do {
                if let a = pinned {
                    if t.lowercased().hasPrefix("btw") || t.hasPrefix("/btw") {
                        apply(try await Client.local.side(pane: a.pane, text: t))
                    } else {
                        let p = try await Client.local.send(pane: a.pane, text: t, label: "\(a.kind) · \(a.folder)")
                        phase = .pending(p)
                        text = ""
                    }
                } else {
                    apply(try await Client.local.route(t))
                }
            } catch {
                fail("reflexd did not answer — \(error.localizedDescription)")
            }
        }
    }

    private func apply(_ r: RouteResponse) {
        guard let route = r.route else { return fail(r.error ?? "no route") }
        switch route.decision {
        case "go":
            if let d = r.dispatch {
                phase = .pending(d)
                text = ""
            } else {
                fail("routed, but nothing was queued")
            }
        case "choose":
            phase = .choose(title: route.title ?? "Where should this go?", item: r.posted?.item, options: route.options ?? [])
        default:
            fail(route.error ?? "could not route")
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        withAnimation(.linear(duration: 0.36)) { shake += 1 }
    }

    /// Esc: undo a pending send (and give the words back), else close.
    func escape() {
        switch phase {
        case .pending(let p):
            Task { await Client.local.cancel(p.id) }
            text = lastText
            phase = .typing
            focusTick += 1
        case .choose, .failed:
            text = lastText
            phase = .typing
            focusTick += 1
        default:
            close()
        }
    }

    func pick(_ key: String) {
        guard case .choose(_, let item, let options) = phase, options.contains(where: { $0.key == key }), let item else { return }
        Task {
            await Client.local.answer(item: item, key: key)
            await Store.shared.refresh()
            if let p = Store.shared.state.pending.first(where: { $0.item == item }) {
                phase = .pending(p)
                text = ""
            } else {
                close()
            }
        }
    }

    /// Watch the daemon: a pending send that ran becomes "sent", then the bar goes.
    func observe(_ s: StateInfo) {
        guard case .pending(let p) = phase, !s.pending.contains(where: { $0.id == p.id }) else { return }
        if let r = s.receipts.first(where: { $0.id == p.id }) {
            if r.ok {
                phase = .sent(p.label)
                arrivals += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                    if case .sent = self?.phase { self?.close() }
                }
            } else {
                fail(r.detail)
            }
        }
    }
}

struct CommandBar: View {
    @ObservedObject var model: CommandModel
    @ObservedObject var store = Store.shared
    @FocusState private var focused: Bool
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var pinned: AgentInfo? { store.state.agents.first { $0.pane == model.target } }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                field
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .glassEffectID("field", in: glass)
                    .modifier(Shake(animatableData: model.shake))
                tray
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .glassEffectID("tray", in: glass)
            }
        }
        .frame(width: 680)
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.size = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        // Leaves like the rail does — a short fade, settle and blur; arrives with none.
        .opacity(model.shown ? 1 : 0)
        .scaleEffect(model.shown || reduce ? 1 : 0.98, anchor: .top)
        .offset(y: model.shown || reduce ? 0 : -6)
        .blur(radius: model.shown || reduce ? 0 : 3)
        .animation(model.shown ? nil : Motion.exit, value: model.shown)
        .animation(Motion.pick(Motion.spring, reduce: reduce), value: model.phase)
        .animation(Motion.pick(Motion.swap, reduce: reduce), value: model.target)
        .onChange(of: model.focusTick) { _, _ in focused = true }
        .onChange(of: store.state.receipts) { _, _ in model.observe(store.state) }
        .onChange(of: store.state.pending) { _, _ in model.observe(store.state) }
        .onAppear { focused = true }
        .sensoryFeedback(.alignment, trigger: model.target)
        .sensoryFeedback(.levelChange, trigger: model.arrivals)
    }

    // MARK: Field

    private var field: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                leading
                TextField("", text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Type.field)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { model.submit(agents: store.state.agents) }
                    .onKeyPress(phases: .down) { press in key(press) }
                    // Our own placeholder, so a new one blurs in instead of cutting.
                    .background(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text(placeholder)
                                .font(Type.field)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .id(placeholder)
                                .transition(.blurSwap)
                                .allowsHitTesting(false)
                        }
                    }
                    .opacity(model.phase == .typing ? 1 : 0.45)
                trailing
            }
            // One line tall whether empty, typed in or pinned; only more lines grow it.
            .frame(minHeight: CommandBar.lineHeight)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            if model.phase == .routing {
                ThinkingLine().padding(.horizontal, 24).transition(.opacity)
            }
        }
    }

    /// The field's one-line height (Type.field), which the pin chip fits inside.
    static let lineHeight: CGFloat = 28

    private var placeholder: String {
        pinned.map { "Message \($0.kind) · \($0.folder)…" } ?? "Ask your agents…"
    }

    @ViewBuilder private var leading: some View {
        // One chip that stays put while ⇥ cycles: only its name crossfades.
        if let a = pinned {
            HStack(spacing: 6) {
                Bead(status: a.status, size: 7)
                Text(a.folder).font(Type.title).lineLimit(1)
                    .id(a.pane)
                    .transition(.blurSwap)
            }
            .padding(.horizontal, 10)
            .frame(height: CommandBar.lineHeight - 2)
            .glassEffect(.regular.tint(Tone.of(a.status).opacity(0.25)), in: Capsule())
            .glassEffectID("pin", in: glass)
            .transition(.surface(reduce: reduce))
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: model.phase == .routing && !reduce)
                .transition(.surface(reduce: reduce))
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.phase {
        case .routing:
            ProgressView().controlSize(.small).transition(.blurSwap)
        case .pending(let p):
            CountdownRing(duration: Double(p.left) / 1000, tint: Tone.working).transition(.blurSwap).id(p.id)
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Tone.done)
                .font(.system(size: 17))
                .transition(.symbolEffect(.drawOn))
        default:
            EmptyView()
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .tab, model.phase == .typing {
            model.cycle(store.state.agents, back: press.modifiers.contains(.shift))
            return .handled
        }
        if case .choose = model.phase {
            let c = press.characters
            if c.count == 1, "123456789".contains(c) { model.pick(c) }
            return .handled
        }
        if press.key == .delete, model.text.isEmpty, model.target != nil {
            model.target = nil
            return .handled
        }
        switch model.phase {
        case .typing, .failed: return .ignored
        default: return .handled
        }
    }

    // MARK: Tray

    @ViewBuilder private var tray: some View {
        Group {
            switch model.phase {
            case .typing, .routing:
                chips
            case .pending(let p):
                destination(p)
            case .sent(let label):
                HStack(spacing: 10) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(Tone.done)
                    Text("Sent").font(Type.title)
                    Text(label.bare).font(Type.body).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
            case .choose(let title, _, let options):
                choices(title, options)
            case .failed(let message):
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.blocked)
                    Text(message).font(Type.body).lineLimit(3)
                    Spacer()
                    if message.contains("provider key") || message.contains("CREDENTIAL") || message.lowercased().contains("credential") {
                        Button("Set up Jev") { model.close(); model.openSetup(.jev) }
                            .buttonStyle(.glassProminent).controlSize(.small)
                    } else if message.contains("no live sessions") {
                        Button("Set up") { model.close(); model.openSetup(.herdr) }
                            .buttonStyle(.glass).controlSize(.small)
                    }
                    Text("esc to edit").font(Type.meta).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.blurSwap)
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.state.agents.isEmpty {
                ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.state.agents) { a in
                            let on = a.pane == model.target
                            Button { model.target = on ? nil : a.pane; focused = true } label: {
                                HStack(spacing: 6) {
                                    Bead(status: a.status, size: 6)
                                    Text("\(a.kind) · \(a.folder)").font(Type.meta).lineLimit(1)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(on ? Tone.of(a.status).opacity(0.22) : Color.primary.opacity(0.05),
                                            in: Capsule())
                                .overlay(Capsule().strokeBorder(on ? Tone.of(a.status).opacity(0.55) : .clear, lineWidth: 1))
                            }
                            .buttonStyle(Pressable())
                            .id(a.pane)
                        }
                    }
                }
                .onChange(of: model.target) { _, t in
                    guard let t else { return }
                    withAnimation(Motion.pick(Motion.swap, reduce: reduce)) { proxy.scrollTo(t, anchor: .center) }
                }
                }
            }
            HStack(spacing: 14) {
                hint("⇥", pinned == nil ? "pick an agent" : "next agent")
                hint("btw", "side question")
                hint("⏎", pinned == nil ? "route with Jev" : "send")
                hint("esc", "close")
                Spacer()
                if !store.connected {
                    Label("reflexd offline", systemImage: "bolt.horizontal.circle").font(Type.meta).foregroundStyle(Tone.blocked)
                } else if store.state.inbox.count > 0 {
                    Text("\(store.state.inbox.count) in inbox").font(Type.meta).foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(store.state.inbox.count)))
                }
            }
        }
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(Type.count).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(what).font(Type.meta).foregroundStyle(.tertiary)
                .contentTransition(.interpolate)
        }
    }

    private func destination(_ p: PendingInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon(p.action.type)).foregroundStyle(Tone.working)
                Text(p.label.bare).font(Type.title).lineLimit(1)
                Spacer()
                Text("esc to undo").font(Type.meta).foregroundStyle(.secondary)
            }
            if let text = p.action.text, !text.isEmpty {
                Text(text).font(Type.body).foregroundStyle(.secondary).lineLimit(2)
            }
            CountdownLine(duration: Double(p.left) / 1000, tint: Tone.working).id(p.id)
        }
    }

    private func icon(_ type: String) -> String {
        switch type {
        case "spawn": return "plus.rectangle.on.rectangle"
        case "btw", "fork": return "bubble.left.and.text.bubble.right"
        case "press": return "keyboard"
        default: return "arrow.turn.down.right"
        }
    }

    private func choices(_ title: String, _ options: [OptionInfo]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Type.meta).foregroundStyle(.secondary)
            ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                Button { model.pick(o.key) } label: {
                    HStack(spacing: 10) {
                        KeyCap(key: o.key, tint: Tone.route)
                        Text(o.label).font(Type.body).lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
                .transition(.surface(reduce: reduce).animation(Motion.enter.delay(Double(i) * Motion.stagger)))
            }
        }
    }
}
