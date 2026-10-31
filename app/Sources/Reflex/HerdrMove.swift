import Combine
import Foundation

/// Moving agents from herdr to herdr-core. A running program can't change
/// terminals, but its conversation can: between turns, Reflex ends the agent
/// in herdr and resumes the same session in herdr-core, in the same folder,
/// on the same Mac (once that Mac's herdr-core is connected). Nothing is lost
/// if a step fails: the conversation stays on disk, in Recent sessions.
@MainActor
final class HerdrMove: ObservableObject {
    static let shared = HerdrMove()

    /// Agents on their way.
    @Published private(set) var moving: Set<String> = []
    /// Agents asked to move while mid-turn: each goes once it's done.
    @Published private(set) var queued: Set<String> = []
    /// What went wrong with the last move that didn't finish.
    @Published private(set) var problem: String?
    /// Other Macs whose herdr-core is connected: their agents can move there.
    @Published private(set) var reachable: Set<String> = []

    enum Readiness: Equatable {
        case ready
        /// Mid-turn, or waiting on you: it moves once it's done.
        case busy
        /// herdr never told Reflex its session id (no integration).
        case noSession
        /// An agent Reflex can't resume (it has no resume of its own).
        case kind
        /// Its Mac has no connected herdr-core.
        case machine
    }

    /// The agents Reflex resumes by id (Route.bend's resume_args).
    static let kinds: Set = ["claude", "pi", "codex"]

    static func inHerdr(_ a: AgentInfo) -> Bool { !HerdrCore.isCore(a.pane) }

    func readiness(_ a: AgentInfo) -> Readiness {
        if !Self.kinds.contains(a.kind) { return .kind }
        if a.session.isEmpty { return .noSession }
        if a.remote && !reachable.contains(a.machine) { return .machine }
        return ["idle", "done"].contains(a.status) ? .ready : .busy
    }

    func refresh() {
        Task {
            let up = await CoreMachines.list().filter { $0.state == "connected" }.map(\.name)
            if reachable != Set(up) { reachable = Set(up) }
        }
    }

    private var watch: AnyCancellable?

    /// Moves `agents`, one at a time: those between turns now, the busy ones
    /// as each finishes its turn.
    func move(_ agents: [AgentInfo]) {
        problem = nil
        queued.formUnion(agents.filter { readiness($0) == .busy }.map(\.pane))
        go(agents)
        guard watch == nil else { return }
        watch = Store.shared.$state.sink { [weak self] state in
            // (sink runs on the main thread, where the store publishes)
            MainActor.assumeIsolated { self?.check(state.agents) }
        }
    }

    /// Stops waiting for the busy ones.
    func cancel() { queued = [] }

    private func check(_ agents: [AgentInfo]) {
        queued.formIntersection(agents.map(\.pane))
        if queued.isEmpty { watch = nil; return }
        go(agents.filter { queued.contains($0.pane) })
    }

    private var running = false

    private func go(_ agents: [AgentInfo]) {
        let ready = agents.filter { readiness($0) == .ready && !moving.contains($0.pane) }
        guard !ready.isEmpty else { return }
        queued.subtract(ready.map(\.pane))
        moving.formUnion(ready.map(\.pane))
        Task {
            // One at a time, across calls too: each close waits for its pane.
            while running { try? await Task.sleep(for: .milliseconds(200)) }
            running = true
            defer { running = false }
            for a in ready { await move(a) }
        }
    }

    private func move(_ a: AgentInfo) async {
        defer { moving.remove(a.pane) }
        let name = "\(a.kind) in \(a.folder)"
        // A turn may have started since the button was pressed.
        guard let now = Store.shared.state.agents.first(where: { $0.pane == a.pane }), readiness(now) == .ready else {
            problem = "\(name) started working: move it once it's done."
            return
        }
        await Client.local.close(a.pane)
        guard await until(seconds: 10, { !Store.shared.state.agents.contains { $0.pane == a.pane } }) else {
            problem = "herdr didn't close \(name): it's still there, unmoved."
            return
        }
        do {
            _ = try await Client.local.resume(cwd: Place.on(a.machine, a.cwd), kind: a.kind, session: a.session,
                                              label: "move \(a.kind) · \(a.folder)")
        } catch {
            problem = "reflexd didn't take \(name): resume it from Recent sessions."
            return
        }
        guard await until(seconds: 30, { Store.shared.state.agents.contains { HerdrCore.isCore($0.pane) && $0.session == a.session } }) else {
            problem = "\(name) didn't come up in herdr-core: resume it from Recent sessions."
            return
        }
    }

    private func until(seconds: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return done()
    }
}
