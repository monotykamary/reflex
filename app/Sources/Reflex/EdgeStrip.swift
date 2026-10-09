import SwiftUI

// The rail: a sliver of liquid glass on the screen's edge. Agents are beads in
// it. Hover (with intent) and it widens into named rows; when an agent starts
// waiting for you, a bubble buds out of the glass beside its bead.

@MainActor
final class RailModel: ObservableObject {
    static let shared = RailModel()
    @Published var expanded = false
    /// The rail is hidden until summoned at the screen edge (or a question surfaces).
    @Published var visible = false
    /// 0…1 while the pointer rests on the edge: the sliver grows as it fills.
    @Published var dwell: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["REFLEX_DEBUG_DWELL"] ?? "") ?? 0)
    /// The panel must be wide while the rail is open or a peek is showing.
    @Published private(set) var wide = false
    private var intent: Task<Void, Never>?

    func hover(_ inside: Bool) {
        intent?.cancel()
        if inside {
            wide = true
            intent = Task { [weak self] in
                try? await Task.sleep(for: Motion.hoverIntent)
                guard !Task.isCancelled else { return }
                withAnimation(Motion.spring) { self?.expanded = true }
            }
        } else {
            withAnimation(Motion.exit) { expanded = false }
            settle()
        }
    }

    /// Narrow the panel again once nothing needs the width.
    func settle() {
        intent = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self else { return }
            if !self.expanded && (Store.shared.peek == nil || !self.visible) { self.wide = false }
        }
    }

    func needWide() { wide = true }
}

struct Rail: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var rail = RailModel.shared
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduce
    var openInbox: () -> Void
    var openAgent: (AgentInfo) -> Void
    var openBar: () -> Void

    private var waiting: Int { store.state.inbox.count }
    private var anyBlocked: Bool { store.state.agents.contains { $0.status == "blocked" } }

    var body: some View {
        ZStack(alignment: .trailing) {
            if !rail.visible && rail.dwell > 0.12 {
                sliver.transition(.opacity)
            }
            content
                .opacity(rail.visible ? 1 : 0)
                .offset(x: rail.visible || reduce ? 0 : 36)
                .blur(radius: rail.visible || reduce ? 0 : 4)
                .allowsHitTesting(rail.visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(rail.visible ? Motion.enter : Motion.exit, value: rail.visible)
    }

    /// The dwell indicator: a glass sliver on the edge that grows for the one
    /// second you rest there, so the gesture explains itself.
    private var sliver: some View {
        Capsule()
            .fill(Color.accentColor.opacity(0.35 + 0.5 * rail.dwell))
            .frame(width: 4, height: 18 + 70 * rail.dwell)
            .glassEffect(.regular.tint(Color.accentColor.opacity(0.3)), in: Capsule())
            .shadow(color: Color.accentColor.opacity(0.6 * rail.dwell), radius: 6)
            .padding(.trailing, 2)
            .animation(.linear(duration: 0.05), value: rail.dwell)
    }

    private var content: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                if let peek = store.peek, !rail.expanded {
                    PeekBubble(item: peek) { openInbox() }
                        .background(.thickMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .glassEffect(.regular.tint(Tone.blocked.opacity(0.16)).interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .glassEffectID("peek", in: glass)
                        .transition(.surface(reduce: reduce))
                }
                tube
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: rail.expanded ? 20 : 16, style: .continuous))
                    .glassEffectID("tube", in: glass)
            }
            .padding(.vertical, 8)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(Motion.pick(Motion.spring, reduce: reduce), value: store.peek?.id)
        .animation(Motion.pick(Motion.spring, reduce: reduce), value: store.state.agents.map(\.pane))
        .onChange(of: store.peek?.id) { _, id in
            if id != nil { rail.needWide() } else { rail.settle() }
        }
    }

    private var tube: some View {
        VStack(alignment: .trailing, spacing: rail.expanded ? 4 : 9) {
            Button(action: openInbox) {
                HStack(spacing: 10) {
                    if rail.expanded {
                        Spacer(minLength: 0)
                        Text(waiting == 0 ? "All clear" : "\(waiting) waiting")
                            .font(Type.meta).foregroundStyle(.secondary)
                            .fixedSize()
                            .transition(.fromBead)
                    }
                    Text(waiting == 0 ? "·" : "\(min(waiting, 99))")
                        .font(Type.count)
                        .contentTransition(.numericText(value: Double(waiting)))
                        .foregroundStyle(waiting == 0 ? Color.secondary : Color.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background((waiting == 0 ? Color.clear : (anyBlocked ? Tone.blocked : Color.accentColor)), in: Circle())
                }
                .padding(.horizontal, rail.expanded ? 10 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            .help("Inbox")

            ForEach(store.state.agents) { a in
                Button { openAgent(a) } label: {
                    HStack(spacing: 10) {
                        if rail.expanded {
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(a.kind) · \(a.folder)").font(Type.title).lineLimit(1)
                                Text(a.title.isEmpty ? a.status : a.title)
                                    .font(Type.meta).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .fixedSize()
                            .transition(.fromBead)
                        }
                        Bead(status: a.status, size: 8, pulse: store.pulses[a.pane] ?? 0)
                            .frame(width: 20, height: rail.expanded ? 30 : 12)
                    }
                    .padding(.horizontal, rail.expanded ? 10 : 0)
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
                .help(rail.expanded ? "" : "\(a.kind) · \(a.place) — \(a.status)")
                .transition(.surface(reduce: reduce))
            }

            Button(action: openBar) {
                HStack(spacing: 10) {
                    if rail.expanded {
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            Text("Ask").font(Type.meta).foregroundStyle(.secondary)
                            Text("⌥⌥").font(Type.count).foregroundStyle(.tertiary)
                        }
                        .fixedSize()
                        .transition(.fromBead)
                    }
                    Image(systemName: store.connected ? "sparkle" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(store.connected ? Color.secondary : Tone.blocked)
                        .frame(width: 20, height: 16)
                        .symbolEffect(.pulse, isActive: !store.connected && !reduce)
                }
                .padding(.horizontal, rail.expanded ? 10 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            .help(store.connected ? "Ask (⌥⌥)" : "reflexd is not reachable")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 5)
        .frame(width: rail.expanded ? 248 : 30, alignment: .trailing)
        // Labels slide out from behind the beads and never paint outside the glass.
        .clipShape(RoundedRectangle(cornerRadius: rail.expanded ? 20 : 16, style: .continuous))
        .onHover { rail.hover($0) }
    }
}

/// The bubble that buds from the rail when an agent starts waiting for you.
private struct PeekBubble: View {
    var item: ItemInfo
    var open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Tone.blocked).frame(width: 6, height: 6)
                    Text(item.agent).font(Type.title).lineLimit(1)
                    Text("needs you").font(Type.meta).foregroundStyle(.secondary)
                }
                if let q = question { Text(q).font(Type.meta).lineLimit(2).foregroundStyle(.primary.opacity(0.85)) }
                if !item.options.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.options.prefix(3)) { o in
                            HStack(spacing: 4) {
                                KeyCap(key: o.key, tint: Tone.blocked)
                                Text(o.label).font(Type.meta).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 250, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
    }

    /// The line just above the options: usually the question itself.
    private var question: String? {
        let lines = item.body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.firstIndex(where: { $0.range(of: #"^[❯>›]?\s*1[.)]\s"#, options: .regularExpression) != nil }) else {
            return lines.last
        }
        return first > 0 ? lines[first - 1] : nil
    }
}

extension AnyTransition {
    /// Rail labels emerge from behind the bead column (right), clipped by the glass.
    static var fromBead: AnyTransition {
        .asymmetric(insertion: .modifier(active: SurfaceFX(opacity: 0, scale: 1, y: 0, blur: 2), identity: SurfaceFX(opacity: 1, scale: 1, y: 0, blur: 0))
                        .combined(with: .offset(x: 18)),
                    removal: .opacity.combined(with: .offset(x: 10)))
    }
}
