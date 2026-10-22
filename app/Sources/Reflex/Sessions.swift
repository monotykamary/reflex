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
        var how = mode ?? p.mode
        // A stopped `claude --bg` session won't take --resume (Claude prints
        // "Resume this session with…" and exits): restart it, then attach.
        if p.agent == "claude", p.state == .background, how == "resume" {
            await respawn(p.id)
            how = "attach"
        }
        let d = try await Client.local.resume(p, mode: how, text: text)
        watchStart(d.id, cwd: p.cwd, open: open)
        return d
    }

    /// `claude respawn <id>`: restart a stopped background session.
    @MainActor static func respawn(_ id: String) async { await claude(["respawn", id]) }

    /// Delete a Claude background session (`claude rm`; its worktree too
    /// when that is safe). A running one is stopped first — rm only takes
    /// sessions that have exited. Gone from the list at once.
    @MainActor static func removeBackground(_ p: PastSession) {
        SessionArchive.shared.forget(p.id)
        Task {
            if p.state == .running { await claude(["stop", p.id]) }
            await claude(["rm", p.id])
            SessionArchive.shared.refresh()
        }
    }

    @MainActor private static func claude(_ args: [String]) async {
        let env = Daemon.shared.childEnvironment()
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["claude"] + args
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
        }.value
    }

    /// A new session's pane is known once it has started ("started rx1-42 in
    /// w7:p1", "resumed … in w7:p1"): open its terminal then. Gives up quietly
    /// after half a minute.
    /// A session being started (or brought back) for you. Its terminal opens
    /// as soon as its pane exists when you asked to watch (⌘⏎) — or, either
    /// way, the moment it stops to ask you something before it can take your
    /// request (Claude's "Do you trust this folder?"): your request waits on
    /// that answer. Watches as long as reflexd waits (about ten minutes).
    @MainActor static func watchStart(_ id: Int, cwd: String, open: Bool) {
        let before = Set(Store.shared.state.agents.map(\.pane))
        // A folder on another Mac starts there: its agent is that Mac's.
        let want = place(Place.machine(cwd), Place.path(cwd))
        Task {
            var shown = false
            for _ in 0..<1300 {
                try? await Task.sleep(for: .milliseconds(500))
                await Store.shared.refresh()
                let s = Store.shared.state
                if !shown, let a = s.agents.first(where: { !before.contains($0.pane) && place($0.machine, $0.cwd) == want }),
                   open || a.status == "blocked" {
                    AppDelegate.current?.showPane(a.pane)
                    shown = true
                }
                guard let r = s.receipts.first(where: { $0.id == id }) else { continue }
                // Started: if it was never seen as a new pane (another folder
                // spelling), the receipt still names it.
                if !shown, open, r.ok, let range = r.detail.range(of: " in ", options: .backwards) {
                    AppDelegate.current?.showPane(String(r.detail[range.upperBound...]).trimmingCharacters(in: .whitespaces))
                }
                return
            }
        }
    }

    /// One spelling per folder: symlinks resolved (/tmp is /private/tmp), no trailing slash.
    /// Where an agent runs: this Mac's paths resolved (symlinks, /tmp), another
    /// Mac's as it reports them.
    private static func place(_ machine: String, _ path: String) -> String {
        machine.isEmpty ? resolved(path) : Place.on(machine, path)
    }

    private static func resolved(_ path: String) -> String {
        var p = (path as NSString).resolvingSymlinksInPath
        if p.hasPrefix("/tmp/") || p == "/tmp" { p = "/private" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
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
    /// The confirmed word and what it does (default: end a live session).
    var word = "Close"
    var help = "Close session…"
    var confirm: (() -> Void)?
    @State private var armed = false
    @State private var disarm: Task<Void, Never>?

    var body: some View {
        Button {
            if armed {
                disarm?.cancel()
                armed = false
                if let confirm { confirm() } else { Sessions.close(pane) }
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
                    Text(word)
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
        .help(armed ? "Click again to \(word.lowercased()) it" : help)
    }
}
