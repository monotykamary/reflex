import Foundation

// Claude's background sessions (`claude --bg`) that no herdr pane shows.
// One attached in a pane is herdr's to report (working → done reaches the
// inbox as usual); one that isn't — started with --bg, or left running after
// its terminal closed — would finish unseen. This watches Claude's own list
// and posts a note when such a session stops working: "finished", or "needs
// you" when it waits on an answer. The note's pane is "bg:<session id>";
// opening it attaches the session in herdr.

@MainActor
final class BackgroundWatch {
    static let shared = BackgroundWatch()

    private struct Seen { var working: Bool }
    private var seen: [String: Seen] = [:]
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let busy = await self?.check() ?? false
                // Closely while something runs in the background, lazily otherwise.
                try? await Task.sleep(for: .seconds(busy ? 8 : 30))
            }
        }
    }

    struct Bg { var id: String; var cwd: String; var name: String; var state: String; var status: String }

    nonisolated static func list(env: [String: String]) -> [Bg] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "agents", "--json"]
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard (r["kind"] as? String) == "background", let id = r["sessionId"] as? String else { return nil }
            return Bg(id: id, cwd: r["cwd"] as? String ?? "", name: r["name"] as? String ?? "",
                      state: (r["state"] as? String ?? "").lowercased(), status: (r["status"] as? String ?? "").lowercased())
        }
    }

    static func isWorking(_ b: Bg) -> Bool { b.state == "working" || b.status == "busy" }
    static func needsYou(_ b: Bg) -> Bool {
        ["waiting", "blocked", "needs_input", "input", "permission"].contains { b.state.contains($0) || b.status.contains($0) }
    }

    /// One look; true while any background session is working.
    private func check() async -> Bool {
        let env = Daemon.shared.childEnvironment()
        let list = await Task.detached(priority: .utility) { BackgroundWatch.list(env: env) }.value
        let attached = Set(Store.shared.state.agents.map(\.session))
        var busy = false
        for b in list {
            let working = BackgroundWatch.isWorking(b)
            busy = busy || working
            let was = seen[b.id]?.working ?? false
            seen[b.id] = Seen(working: working)
            // Herdr reports the ones it shows; only a change from working counts.
            guard was, !working, !attached.contains(b.id) else { continue }
            await note(b)
        }
        return busy
    }

    private func note(_ b: Bg) async {
        let folder = (b.cwd as NSString).lastPathComponent
        // The last reply can reach the file a moment after the session stops.
        var reply: String?
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            reply = await Task.detached { Replies.locate(kind: "claude", id: b.id).flatMap(Replies.lastReply) }.value
            if reply != nil { break }
        }
        let title = BackgroundWatch.needsYou(b) ? "needs you (background)" : "finished in the background"
        let body = reply ?? (b.name.isEmpty ? "" : b.name)
        await Client.local.note(pane: "bg:" + b.id, agent: "claude · \(folder)", title: title, body: body)
        await Store.shared.refresh()
    }

    /// Open a background note: attach that session in herdr.
    static func open(_ pane: String) {
        let id = String(pane.dropFirst(3))
        Store.shared.seen(pane)
        let known = SessionArchive.shared.sessions.first { $0.id == id }
        let p = known ?? PastSession(agent: "claude", id: id, cwd: NSHomeDirectory(), title: "background session",
                                     last: "", modified: Date(), state: .running)
        Task { _ = try? await Sessions.resume(p, mode: "attach", text: "", open: true) }
    }
}
