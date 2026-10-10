import SwiftUI

// What happened while you were elsewhere, as one list: questions first (they
// wait on you), then sessions that finished or answered — one line each, the
// gist of what they said underneath. Opening a session clears its rows.
// Keyboard first: ↑↓ move · ⏎ open · 1–9 answer · E clear · esc close.
// Selection moves instantly: it is driven by keys pressed many times a minute.

@MainActor
final class InboxModel: ObservableObject {
    static let shared = InboxModel()
    @Published var shown = false
    @Published var selected: Int?
    /// The inbox's measured size (the window is larger and clear; this is
    /// the part that takes the mouse).
    @Published var size: CGSize = .zero
    /// The tallest the list may grow before it scrolls.
    @Published var maxList: CGFloat = 560
}

/// The end of an agent's screen, as prose: no rules, prompts, status lines
/// or hard wraps.
enum InboxText {
    private static let rule = CharacterSet(charactersIn: "─━═—-_│┃╭╮╰╯┌┐└┘├┤┬┴┼ ")
    private static let status = try! NSRegularExpression(pattern: #"^[*✻✽✶✳✢·⏵⎿]\s*\S+ for \d|esc to interrupt|\? for shortcuts|^⏵⏵|bypass permissions|accept edits"#,
                                                         options: [.caseInsensitive])

    static func gist(_ body: String) -> String {
        var paragraphs: [String] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { paragraphs.append(t) }
            current = ""
        }
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\t", with: " ")
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.unicodeScalars.allSatisfy({ rule.contains($0) }) { flush(); continue }
            if ["❯", ">", "›", "$"].contains(t) || t.hasPrefix("❯ ") && t.count < 3 { flush(); continue }
            if status.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { flush(); continue }
            var text = t
            for mark in ["⏺ ", "● ", "• "] where text.hasPrefix(mark) { text.removeFirst(mark.count) }
            // A line that starts indented continues the one before (the
            // terminal wrapped it); otherwise it starts its own.
            if !current.isEmpty && (line.hasPrefix(" ") || !current.hasSuffix(".")) {
                current += " " + text
            } else {
                flush()
                current = text
            }
        }
        flush()
        return paragraphs.suffix(3).joined(separator: "\n")
    }
}

struct InboxView: View {
    static let width: CGFloat = 480

    @ObservedObject var store = Store.shared
    @ObservedObject var model = InboxModel.shared
    @ObservedObject var replies = Replies.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var rowsHeight: CGFloat = 0
    var openPane: (String) -> Void
    var close: () -> Void

    /// Questions first, then the rest; newest first within each.
    private var items: [ItemInfo] {
        let all = store.state.inbox.sorted { $0.at > $1.at }
        return all.filter(asks) + all.filter { !asks($0) }
    }
    private func asks(_ i: ItemInfo) -> Bool { !i.options.isEmpty }
    private var current: ItemInfo? { items.first(where: { $0.id == model.selected }) ?? items.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            list
            if !items.isEmpty {
                Divider().opacity(0.5)
                footer
            }
        }
        .raySurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.vertical, 16)
        .frame(width: InboxView.width)
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
        .onChange(of: model.shown, initial: true) { _, shown in
            if shown { replies.refresh(items, agents: store.state.agents) }
        }
        .onChange(of: items.map(\.id)) { _, _ in replies.refresh(items, agents: store.state.agents) }
    }

    private func reply(_ item: ItemInfo) -> String? {
        Replies.session(of: item, in: store.state.agents).flatMap { replies.text[$0.session] }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Text("Inbox").font(.system(size: 14, weight: .semibold))
            if !items.isEmpty {
                Text("\(items.count)").font(Type.count).foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(items.count)))
            }
            Spacer()
            if !store.state.herdr {
                Label("herdr unreachable", systemImage: "exclamationmark.triangle.fill")
                    .font(Type.meta).foregroundStyle(Tone.blocked)
            }
            if items.contains(where: { !asks($0) }) {
                Button("Clear updates", action: clearUpdates)
                    .buttonStyle(.plain)
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .rayPill(Capsule())
                    .help("Clear everything that is not a question")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    @ViewBuilder private var list: some View {
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Tone.done)
                Text("All clear").font(Type.title)
                Text("Nothing needs you right now.").font(Type.meta).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || asks(items[i - 1]) != asks(item) {
                                section(asks(item) ? "Needs you" : "Updates")
                            }
                            Row(item: item,
                                reply: reply(item),
                                selected: item.id == current?.id,
                                now: store.state.now,
                                pending: store.state.pending.first { $0.item == item.id },
                                answer: { answer(item, $0) },
                                dismiss: { dismiss(item) },
                                open: { if !item.pane.isEmpty { openPane(item.pane) } })
                                .id(item.id)
                                .onTapGesture { instantly { model.selected = item.id } }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    if !item.pane.isEmpty { openPane(item.pane) }
                                })
                                .transition(.opacity)
                        }
                    }
                    .padding(6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .scrollIndicators(.never)
                .frame(height: min(max(rowsHeight, 40), model.maxList))
                .onChange(of: model.selected) { _, id in
                    if let id { instantly { proxy.scrollTo(id) } }
                }
            }
            .animation(Motion.pick(Motion.spring, reduce: reduce), value: items.map(\.id))
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            ForEach(hints, id: \.0) { k, v in
                HStack(spacing: 4) {
                    Text(k).font(Type.count).foregroundStyle(.secondary)
                    Text(v).font(Type.meta).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var hints: [(String, String)] {
        var h = [("⏎", "open"), ("E", "clear")]
        if let c = current, asks(c) { h.insert(("1–\(c.options.count)", "answer"), at: 0) }
        return h
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

    private func clearUpdates() {
        let ids = items.filter { !asks($0) }.map(\.id)
        Task {
            for id in ids { await Client.local.dismiss(id) }
            await store.refresh()
        }
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
        default: break
        }
        switch press.characters.lowercased() {
        case "j": move(1)
        case "k": move(-1)
        case "e":
            if let c = current { move(1); dismiss(c) }
        case let d where d.count == 1 && "123456789".contains(d):
            if let c = current, c.options.contains(where: { $0.key == d }) { answer(c, d) }
        default:
            return .ignored
        }
        return .handled
    }
}

/// One row: who, what happened, when — and underneath, the gist of what
/// they said (more of it when selected), or the question's answers.
private struct Row: View {
    var item: ItemInfo
    /// What the session said last, from its own session file.
    var reply: String?
    var selected: Bool
    var now: Int
    var pending: PendingInfo?
    var answer: (String) -> Void
    var dismiss: () -> Void
    var open: () -> Void
    @State private var hover = false

    private var tone: Color { Tone.ofItem(item.kind) }
    private var gist: String { InboxText.gist(item.body) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(tone).frame(width: 7, height: 7)
                Text(item.agent).font(Type.title).lineLimit(1)
                Text(item.title).font(Type.meta).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                ZStack(alignment: .trailing) {
                    Text(ago).font(Type.meta).foregroundStyle(.tertiary).monospacedDigit()
                        .opacity(hover ? 0 : 1)
                    HStack(spacing: 2) {
                        if !item.pane.isEmpty { icon("arrow.up.forward", help: "Open (⏎)", action: open) }
                        icon("xmark", help: "Clear (E)", action: dismiss)
                    }
                    .opacity(hover ? 1 : 0)
                }
            }
            if let reply {
                // A reply reads from its start: that is where it says what it did.
                Text(reply)
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(selected ? 8 : 2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 15)
            } else if !gist.isEmpty {
                // A screen reads from its end: the latest is at the bottom.
                Text(gist)
                    .font(Type.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(selected ? 6 : 2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 15)
            }
            if let p = pending {
                Label(p.label.bare, systemImage: "arrow.turn.down.right").font(Type.meta).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 15)
            } else if !item.options.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.options) { o in
                        Button { answer(o.key) } label: {
                            HStack(spacing: 8) {
                                KeyCap(key: o.key, tint: tone)
                                Text(o.label).font(Type.body).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(Pressable())
                    }
                }
                .padding(.leading, 15)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(Selected(on: selected))
        .onHover { h in withAnimation(Motion.micro) { hover = h } }
        .animation(Motion.enter, value: pending?.id)
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 20)
                .rayPill(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var ago: String {
        let s = max(0, (now - item.at) / 1000)
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// Raycast selection: the row sits on the text colour at 10%; others are bare.
private struct Selected: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        content.background(Color.primary.opacity(on ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
