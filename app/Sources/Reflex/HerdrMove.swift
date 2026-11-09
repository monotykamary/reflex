import Combine
import Foundation

/// Moving agents: from herdr to herdr-core, or to another machine. A running
/// program can't change terminals, but its conversation can: between turns,
/// Reflex ends the agent and resumes the same session where it's going. To
/// herdr-core that's the same folder on the same Mac (once that Mac's
/// herdr-core is connected). To another machine (a boat sandbox, any machine
/// herdr-core has added) the project and the session file go first, to the
/// same ~ path there (Boat). Nothing is lost if a step fails: the
/// conversation stays on disk, in Recent sessions, and a move that fails
/// after the close resumes it here again.
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
    /// What a move is doing now, or why it stopped, by pane: shown in its
    /// terminal window.
    @Published private(set) var notes: [String: String] = [:]
    /// Where each queued or moving agent goes: another machine's name, or
    /// absent for herdr → herdr-core on its own Mac.
    private var targets: [String: String] = [:]

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
        /// To another machine: only this Mac's agents (their session files
        /// are here).
        case notHere
    }

    /// The agents Reflex resumes by id (Route.bend's resume_args).
    static let kinds: Set = ["claude", "pi", "codex"]

    static func inHerdr(_ a: AgentInfo) -> Bool { !HerdrCore.isCore(a.pane) }

    func readiness(_ a: AgentInfo, to target: String? = nil) -> Readiness {
        if !Self.kinds.contains(a.kind) { return .kind }
        if a.session.isEmpty { return .noSession }
        if let target, target != a.machine {
            if a.remote { return .notHere }
        } else if a.remote && !reachable.contains(a.machine) {
            return .machine
        }
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
    /// as each finishes its turn. `to`: another machine herdr-core reaches.
    func move(_ agents: [AgentInfo], to machine: String? = nil) {
        problem = nil
        for a in agents {
            targets[a.pane] = machine
            notes[a.pane] = nil
        }
        let busy = agents.filter { readiness($0, to: machine) == .busy }
        queued.formUnion(busy.map(\.pane))
        for a in busy where machine != nil { notes[a.pane] = "Moves to \(machine!) once this turn ends" }
        go(agents)
        guard watch == nil else { return }
        watch = Store.shared.$state.sink { [weak self] state in
            // (sink runs on the main thread, where the store publishes)
            MainActor.assumeIsolated { self?.check(state.agents) }
        }
    }

    /// The window's button: a new boat machine. From your template when you
    /// have one; otherwise the agent builds it with the reflex skill, and asks
    /// to move when it's done (you approve that). `rebuild`: build it again.
    func toBoat(_ a: AgentInfo, rebuild: Bool = false) {
        notes[a.pane] = "Checking your boat template…"
        problem = nil
        Task {
            await BoatTemplate.shared.refresh(fresh: 0)
            let t = BoatTemplate.shared.state
            if BoatTemplate.shared.exists && !rebuild {
                notes[a.pane] = "Starting a boat machine from your template…"
                do {
                    let m = try await Boat.newMachine(template: true)
                    notes[a.pane] = nil
                    _ = await CoreMachines.list(fresh: 0)
                    move([a], to: m)
                } catch {
                    fail(a.pane, "No boat machine: \(error.localizedDescription)")
                }
                return
            }
            Boat.install()
            let prompt: String
            if case .stale(_, let changed) = t { prompt = Boat.rebuildPrompt(changed) } else { prompt = Boat.buildPrompt }
            do {
                _ = try await Client.local.send(pane: a.pane, text: prompt, label: "build the boat template")
                notes[a.pane] = "\(a.kind) is building your boat template. You'll approve the move when it's ready."
            } catch {
                fail(a.pane, "reflexd didn't take it: \(error.localizedDescription)")
            }
        }
    }

    func dismissNote(_ pane: String) { notes[pane] = nil }

    /// Stops waiting for the busy ones.
    func cancel() {
        for p in queued { notes[p] = nil; targets[p] = nil }
        queued = []
    }

    private func check(_ agents: [AgentInfo]) {
        queued.formIntersection(agents.map(\.pane))
        if queued.isEmpty { watch = nil; return }
        go(agents.filter { queued.contains($0.pane) })
    }

    private var running = false

    private func go(_ agents: [AgentInfo]) {
        let ready = agents.filter { readiness($0, to: targets[$0.pane]) == .ready && !moving.contains($0.pane) }
        guard !ready.isEmpty else { return }
        queued.subtract(ready.map(\.pane))
        moving.formUnion(ready.map(\.pane))
        Task {
            // One at a time, across calls too: each close waits for its pane.
            while running { try? await Task.sleep(for: .milliseconds(200)) }
            running = true
            defer { running = false }
            for a in ready {
                // (A move that has to wait again sets its target again.)
                if let m = targets.removeValue(forKey: a.pane), m != a.machine { await move(a, to: m) } else { await move(a) }
            }
        }
    }

    private func fail(_ pane: String, _ why: String) {
        problem = why
        notes[pane] = why
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

    /// To another machine: the project and logins while it's still here, then
    /// the close, its session file, and the resume there.
    private func move(_ a: AgentInfo, to m: String) async {
        defer { moving.remove(a.pane) }
        let name = "\(a.kind) in \(a.folder)"
        do {
            notes[a.pane] = "Copying \(a.folder) to \(m)…"
            _ = try await Boat.sync(m, a.cwd)
            if Boat.made(m) {
                notes[a.pane] = "Copying your logins to \(m)…"
                try await Boat.creds(m)
            }
        } catch {
            return fail(a.pane, "Not moved: \(error.localizedDescription)")
        }
        // A turn may have started while the files went: again once it's done.
        guard let now = Store.shared.state.agents.first(where: { $0.pane == a.pane }), readiness(now, to: m) == .ready else {
            targets[a.pane] = m
            queued.insert(a.pane)
            notes[a.pane] = "Moves to \(m) once this turn ends"
            return
        }
        notes[a.pane] = "Moving \(a.kind) to \(m)…"
        await Client.local.close(a.pane)
        guard await until(seconds: 10, { !Store.shared.state.agents.contains { $0.pane == a.pane } }) else {
            return fail(a.pane, "\(name) didn't close: it's still here, unmoved.")
        }
        notes[a.pane] = nil
        let there: (cwd: String, session: String)
        do {
            there = try await Boat.session(m, kind: a.kind, session: a.session, cwd: a.cwd)
        } catch {
            problem = "\(name) wasn't moved (\(error.localizedDescription)): it's back here."
            await back(a)
            return
        }
        do {
            _ = try await Client.local.resume(cwd: Place.on(m, there.cwd), kind: a.kind, session: there.session,
                                              label: "move \(a.kind) · \(a.folder) → \(m)")
        } catch {
            problem = "reflexd didn't resume \(name) on \(m): it's back here."
            await back(a)
            return
        }
        guard await until(seconds: 60, { Store.shared.state.agents.contains { $0.machine == m && $0.session == there.session } }) else {
            problem = "\(name) didn't come up on \(m): resume it from Recent sessions."
            return
        }
        if let moved = Store.shared.state.agents.first(where: { $0.machine == m && $0.session == there.session }) {
            AppDelegate.current?.showPane(moved.pane)
        }
    }

    /// A move that failed after the close: the session again, here.
    private func back(_ a: AgentInfo) async {
        _ = try? await Client.local.resume(cwd: a.cwd, kind: a.kind, session: a.session, label: "resume \(a.kind) · \(a.folder)")
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
