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
    /// What each agent said its work needs besides its project.
    private var bring: [String: [String]] = [:]

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
        /// (No longer used: agents move from any machine.)
        case notHere
    }

    /// The agents Reflex resumes by id (Route.bend's resume_args).
    static let kinds: Set = ["claude", "pi", "codex"]

    static func inHerdr(_ a: AgentInfo) -> Bool { !HerdrCore.isCore(a.pane) }

    func readiness(_ a: AgentInfo, to target: String? = nil) -> Readiness {
        if !Self.kinds.contains(a.kind) { return .kind }
        if a.session.isEmpty { return .noSession }
        if let target, target != Boat.name(a.machine) {
            // To another machine, from wherever it is: through this Mac.
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
    func move(_ agents: [AgentInfo], to machine: String? = nil, with paths: [String] = []) {
        problem = nil
        for a in agents {
            targets[a.pane] = machine
            notes[a.pane] = nil
            bring[a.pane] = paths
        }
        for a in agents { NSLog("Reflex: move %@ (%@, %@) to %@: %@", a.pane, a.kind, a.status, machine ?? "herdr-core", String(describing: readiness(a, to: machine))) }
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

    /// The window's button, to another machine: the agent copies what its
    /// work needs there (the reflex skill) and asks to move; pressing the
    /// button approved that already.
    func prepare(_ a: AgentInfo, to m: String) {
        problem = nil
        Boat.install()
        MoveRequests.shared.expect(a.pane, to: m)
        notes[a.pane] = "\(a.kind) is getting what this work needs to \(m)…"
        Task {
            do {
                _ = try await Client.local.send(pane: a.pane, text: Boat.movePrompt(m, made: Boat.made(m)), label: "move to \(m)")
            } catch {
                MoveRequests.shared.forget(a.pane)
                fail(a.pane, "reflexd didn't take it: \(error.localizedDescription)")
            }
        }
    }

    /// The window's button: a new boat machine. From your template when you
    /// have one; otherwise the agent builds it with the reflex skill first.
    /// Either way the agent moves itself (prepare). `rebuild`: build it again.
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
                    _ = await CoreMachines.list(fresh: 0)
                    prepare(a, to: m)
                } catch {
                    fail(a.pane, "No boat machine: \(error.localizedDescription)")
                }
                return
            }
            Boat.install()
            MoveRequests.shared.expect(a.pane, to: nil)
            let prompt: String
            if case .stale(_, let changed) = t { prompt = Boat.rebuildPrompt(changed) } else { prompt = Boat.buildPrompt }
            do {
                _ = try await Client.local.send(pane: a.pane, text: prompt, label: "build the boat template")
                notes[a.pane] = "\(a.kind) is building your boat template, then moves…"
            } catch {
                MoveRequests.shared.forget(a.pane)
                fail(a.pane, "reflexd didn't take it: \(error.localizedDescription)")
            }
        }
    }

    /// × on its note: it stops waiting too (a later request is asked again).
    func dismissNote(_ pane: String) {
        notes[pane] = nil
        if !moving.contains(pane) { MoveRequests.shared.forget(pane) }
    }

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
                if let m = targets.removeValue(forKey: a.pane), m != Boat.name(a.machine) { await move(a, to: m) } else { await move(a) }
            }
        }
    }

    private func fail(_ pane: String, _ why: String) {
        NSLog("Reflex: move of %@ stopped: %@", pane, why)
        MachineNotes.post(pane, title: "didn't move", body: why)
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

    /// To another machine (`m`, "." for this Mac), from wherever it is. While
    /// it's still there: its project, what it said its work needs, logins (to
    /// a machine Reflex made) and its conversation (minutes, for a long one),
    /// all through this Mac. Then the close, the lines it wrote since, and
    /// the resume there. Its window says what's going on throughout and
    /// becomes the one there.
    private func move(_ a: AgentInfo, to m: String) async {
        defer { moving.remove(a.pane) }
        let name = "\(a.kind) in \(a.folder)"
        let src = Boat.name(a.machine)
        let place = m == Boat.here ? "this Mac" : m
        let paths = bring.removeValue(forKey: a.pane) ?? []
        do {
            notes[a.pane] = "Copying \(a.folder) to \(place)…"
            _ = try await Boat.sync(m, a.cwd, from: src)
            if !paths.isEmpty {
                notes[a.pane] = "Copying what it needs to \(place) (\(paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) items"))…"
                try await Boat.bring(m, paths, from: src)
            }
            if Boat.made(m) {
                notes[a.pane] = "Copying your logins to \(place)…"
                try await Boat.creds(m)
            }
            notes[a.pane] = "Copying this conversation to \(place)…"
            _ = try await Boat.session(m, kind: a.kind, session: a.session, cwd: a.cwd, from: src)
        } catch {
            return fail(a.pane, "Not moved: \(error.localizedDescription)")
        }
        // A turn may have started while the files went: again once it's done
        // (what's copied stays; the next copy is what it adds).
        guard let now = Store.shared.state.agents.first(where: { $0.pane == a.pane }), readiness(now, to: m) == .ready else {
            targets[a.pane] = m
            queued.insert(a.pane)
            notes[a.pane] = "Moves to \(place) once this turn ends"
            return
        }
        notes[a.pane] = "Moving \(a.kind) to \(place)…"
        await Client.local.close(a.pane)
        guard await until(seconds: 10, { !Store.shared.state.agents.contains { $0.pane == a.pane } }) else {
            return fail(a.pane, "\(name) didn't close: it's still there, unmoved.")
        }
        let there: (cwd: String, session: String)
        do {
            there = try await Boat.session(m, kind: a.kind, session: a.session, cwd: a.cwd, from: src)
        } catch {
            await back(a, "Not moved (\(error.localizedDescription)): \(a.kind) is back where it was.")
            return
        }
        notes[a.pane] = "Starting \(a.kind) on \(place)…"
        do {
            _ = try await Client.local.resume(cwd: m == Boat.here ? there.cwd : Place.on(m, there.cwd), kind: a.kind, session: there.session,
                                              label: "move \(a.kind) · \(a.folder) → \(place)")
        } catch {
            await back(a, "reflexd didn't start it on \(place): \(a.kind) is back where it was.")
            return
        }
        let arrived = { Store.shared.state.agents.first { Boat.name($0.machine) == m && $0.session == there.session } }
        guard await until(seconds: 60, { arrived() != nil }) else {
            return fail(a.pane, "\(name) didn't come up on \(place): resume it from Recent sessions.")
        }
        notes[a.pane] = nil
        if let moved = arrived() {
            MachineNotes.post(moved.pane, title: "moved to \(place)", body: "From \(src == Boat.here ? "this Mac" : src), with its project\(paths.isEmpty ? "" : " and \(paths.count) more") and this conversation.")
            // Its window is the one there now.
            AppDelegate.current?.closedSession(a.pane)
            AppDelegate.current?.showPane(moved.pane)
        }
    }

    /// A move that failed after the close: the session again, here, in its
    /// window, which says why.
    private func back(_ a: AgentInfo, _ why: String) async {
        fail(a.pane, why)
        _ = try? await Client.local.resume(cwd: a.remote ? Place.on(a.machine, a.cwd) : a.cwd, kind: a.kind, session: a.session, label: "resume \(a.kind) · \(a.folder)")
        let here = { Store.shared.state.agents.first { $0.machine == a.machine && $0.session == a.session && $0.pane != a.pane } }
        guard await until(seconds: 30, { here() != nil }), let b = here() else { return }
        notes[a.pane] = nil
        notes[b.pane] = why
        AppDelegate.current?.closedSession(a.pane)
        AppDelegate.current?.showPane(b.pane)
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
