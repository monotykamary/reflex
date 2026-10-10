import AppKit
import SwiftUI

// Sessions across Reflex: which were switched to most recently (for ⌘Tab-like
// ordering), and closing one — always on purpose, never by a stray click.

/// Panes most recently switched to, first. Touched when a terminal opens or
/// takes focus, and when a request is sent to a session.
@MainActor
final class Recents: ObservableObject {
    static let shared = Recents()
    @Published private(set) var order: [String]
    private let key = "recentPanes"

    private init() {
        order = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func touch(_ pane: String) {
        guard order.first != pane else { return }
        order.removeAll { $0 == pane }
        order.insert(pane, at: 0)
        if order.count > 60 { order.removeLast(order.count - 60) }
        UserDefaults.standard.set(order, forKey: key)
    }

    /// Lower is more recent; never-switched sessions come after all others.
    func rank(_ pane: String) -> Int { order.firstIndex(of: pane) ?? Int.max }

    /// Most recently switched first; the rest waiting, working, done, idle.
    func sorted(_ agents: [AgentInfo]) -> [AgentInfo] {
        let status = ["blocked": 0, "working": 1, "done": 2]
        return agents.sorted {
            let a = rank($0.pane), b = rank($1.pane)
            if a != b { return a < b }
            return (status[$0.status] ?? 3) < (status[$1.status] ?? 3)
        }
    }
}

enum Sessions {
    /// Bring an earlier session back; open its terminal once it has started
    /// when `open` is set. Returns the dispatch, or throws.
    @MainActor @discardableResult
    static func resume(_ p: PastSession, mode: String? = nil, text: String = "", open: Bool) async throws -> PendingInfo {
        let d = try await Client.local.resume(p, mode: mode ?? p.mode, text: text)
        if open { openWhenStarted(d.id) }
        return d
    }

    /// A new session's pane is known once it has started ("started rx1-42 in
    /// w7:p1", "resumed … in w7:p1"): open its terminal then. Gives up quietly
    /// after half a minute.
    @MainActor static func openWhenStarted(_ id: Int) {
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                await Store.shared.refresh()
                guard let r = Store.shared.state.receipts.first(where: { $0.id == id }) else { continue }
                if r.ok, let range = r.detail.range(of: " in ", options: .backwards) {
                    AppDelegate.current?.showPane(String(r.detail[range.upperBound...]).trimmingCharacters(in: .whitespaces))
                }
                return
            }
        }
    }

    /// End a session: herdr closes its pane and the agent in it; an open
    /// terminal window for it closes too.
    @MainActor static func close(_ pane: String) {
        Task {
            await Client.local.close(pane)
            AppDelegate.current?.closedSession(pane)
            await Store.shared.refresh()
        }
    }
}

/// × that closes a session in two steps: the first click arms it (a red
/// "Close" for three seconds), the second closes. A busy agent is never one
/// slip away from being killed.
struct CloseSessionButton: View {
    var pane: String
    var size: CGFloat = 22
    var tint: Color = Ink.text
    @State private var armed = false
    @State private var disarm: Task<Void, Never>?

    var body: some View {
        Button {
            if armed {
                disarm?.cancel()
                armed = false
                Sessions.close(pane)
            } else {
                withAnimation(Motion.micro) { armed = true }
                disarm?.cancel()
                disarm = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.exit) { armed = false }
                }
            }
        } label: {
            Group {
                if armed {
                    Text("Close")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: size - 4)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: size, height: size)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .help(armed ? "Click again to end this session" : "Close session…")
    }
}
