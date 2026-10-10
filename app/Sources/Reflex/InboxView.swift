import SwiftUI

// Every question, finished turn, side answer and routing choice, as a stack of
// glass cards that grows out of the rail. Keyboard first:
// J/K move · 1–9 answer · E clear · ⏎ open · U undo · ⇥ filter · esc close
// Selection moves instantly: it is driven by keys pressed many times a minute.

@MainActor
final class InboxModel: ObservableObject {
    static let shared = InboxModel()
    @Published var shown = false
    @Published var selected: Int?
    @Published var needsYouOnly = false
    /// The inbox's measured size; its window fits it.
    @Published var size: CGSize = .zero
    /// The tallest the card list may grow before it scrolls.
    @Published var maxList: CGFloat = 560
}

struct InboxView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var model = InboxModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var rowsHeight: CGFloat = 0
    var openPane: (String) -> Void
    var close: () -> Void

    private var items: [ItemInfo] {
        model.needsYouOnly ? store.state.inbox.filter { $0.kind == "ask" || $0.kind == "route" } : store.state.inbox
    }
    private var current: ItemInfo? { items.first(where: { $0.id == model.selected }) ?? items.first }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                header
                    .raySurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
                list
                footer
            }
        }
        .padding(16)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.size = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(model.shown ? 1 : 0)
        .scaleEffect(model.shown || reduce ? 1 : 0.97, anchor: .trailing)
        .offset(x: model.shown || reduce ? 0 : 14)
        .blur(radius: model.shown || reduce ? 0 : 3)
        .animation(model.shown ? Motion.enter : Motion.exit, value: model.shown)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { handle($0) }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Text("Inbox").font(.system(size: 15, weight: .semibold))
            Text("\(items.count)").font(Type.count).foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(items.count)))
            Spacer()
            if !store.state.herdr {
                Label("herdr unreachable", systemImage: "exclamationmark.triangle.fill")
                    .font(Type.meta).foregroundStyle(Tone.blocked)
            }
            Segmented(selection: $model.needsYouOnly, options: [("All", false), ("Needs you", true)])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var list: some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Tone.done)
                    .transition(.symbolEffect(.drawOn))
                Text("All clear").font(Type.title)
                Text("Nothing needs you right now.").font(Type.meta).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .raySurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .transition(.surface(reduce: reduce))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            Card(item: item,
                                 selected: item.id == current?.id,
                                 now: store.state.now,
                                 pending: store.state.pending.first { $0.item == item.id },
                                 answer: { answer(item, $0) },
                                 dismiss: { dismiss(item) },
                                 open: { if !item.pane.isEmpty { openPane(item.pane) } })
                                .id(item.id)
                                .onTapGesture { instantly { model.selected = item.id } }
                                .transition(.surface(reduce: reduce))
                        }
                    }
                    .padding(.vertical, 2)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .scrollIndicators(.never)
                .frame(height: min(max(rowsHeight, 60), model.maxList))
                .onChange(of: model.selected) { _, id in
                    if let id { instantly { proxy.scrollTo(id) } }
                }
            }
            .animation(Motion.pick(Motion.spring, reduce: reduce), value: items.map(\.id))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            ForEach([("J K", "move"), ("1–9", "answer"), ("E", "clear"), ("⏎", "open"), ("U", "undo"), ("⇥", "filter")], id: \.0) { k, v in
                HStack(spacing: 4) {
                    Text(k).font(Type.count).foregroundStyle(.secondary)
                    Text(v).font(Type.meta).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: Actions

    private func instantly(_ f: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, f)
    }

    private func answer(_ item: ItemInfo, _ key: String) {
        Task { await Client.local.answer(item: item.id, key: key); await store.refresh() }
    }

    private func dismiss(_ item: ItemInfo) {
        Task { await Client.local.dismiss(item.id); await store.refresh() }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let i = items.firstIndex(where: { $0.id == current?.id }) ?? 0
        instantly { model.selected = items[max(0, min(items.count - 1, i + delta))].id }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape: close(); return .handled
        case .return:
            if let c = current, !c.pane.isEmpty { openPane(c.pane) }
            return .handled
        case .downArrow: move(1); return .handled
        case .upArrow: move(-1); return .handled
        case .tab: model.needsYouOnly.toggle(); return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "j": move(1)
        case "k": move(-1)
        case "e":
            if let c = current { move(1); dismiss(c) }
        case "u":
            if let p = store.state.pending.last { Task { await Client.local.cancel(p.id); await store.refresh() } }
        case let d where d.count == 1 && "123456789".contains(d):
            if let c = current, c.options.contains(where: { $0.key == d }) { answer(c, d) }
        default:
            return .ignored
        }
        return .handled
    }
}

private struct Card: View {
    var item: ItemInfo
    var selected: Bool
    var now: Int
    var pending: PendingInfo?
    var answer: (String) -> Void
    var dismiss: () -> Void
    var open: () -> Void
    @State private var hover = false

    private var tone: Color { Tone.ofItem(item.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(tone).frame(width: 7, height: 7).shadow(color: tone.opacity(0.6), radius: 3)
                Text(item.agent).font(Type.title).lineLimit(1)
                Text(item.title).font(Type.meta).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text(ago).font(Type.meta).foregroundStyle(.tertiary).monospacedDigit()
                if hover || selected {
                    HStack(spacing: 2) {
                        if !item.pane.isEmpty {
                            Button(action: open) { Image(systemName: "arrow.up.forward") }.help("Open (⏎)")
                        }
                        Button(action: dismiss) { Image(systemName: "xmark") }.help("Clear (E)")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .transition(.opacity)
                }
            }
            if !item.body.isEmpty {
                Text(item.body)
                    .font(Type.mono)
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
                    .lineLimit(selected ? 16 : 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let p = pending {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(p.label).font(Type.meta).lineLimit(1)
                        Spacer()
                        Text("U to undo").font(Type.meta).foregroundStyle(.secondary)
                    }
                    CountdownLine(duration: Double(p.left) / 1000, tint: tone).id(p.id)
                }
                .transition(.blurSwap)
            } else if !item.options.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.options) { o in
                        Button { answer(o.key) } label: {
                            HStack(spacing: 10) {
                                KeyCap(key: o.key, tint: tone)
                                Text(o.label).font(Type.body).lineLimit(2)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(Pressable())
                    }
                }
                .transition(.blurSwap)
            }
        }
        .padding(14)
        .raySurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(selected ? tone.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(selected ? tone.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: selected ? 1 : 0.5))
        .shadow(color: .black.opacity(selected ? 0.18 : 0.08), radius: selected ? 14 : 6, y: 4)
        .onHover { h in withAnimation(Motion.micro) { hover = h } }
        .animation(Motion.enter, value: pending?.id)
    }

    private var ago: String {
        let s = max(0, (now - item.at) / 1000)
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
