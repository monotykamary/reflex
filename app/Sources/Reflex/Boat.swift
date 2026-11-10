import AppKit
import Combine
import Foundation

/// Other machines for a session: boat.dev sandboxes Reflex makes, or any
/// machine herdr-core has added. The steps are scripts/reflex.sh's, the
/// `reflex` command the reflex skill uses too: make a machine, copy the
/// project, the logins and the session there. HerdrMove closes the agent here
/// and resumes it there.
@MainActor
enum Boat {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// "@boat", and the move menu's new boat machine.
    static let key = "boat"

    static var script: String { Daemon.resources.appendingPathComponent("scripts/reflex.sh").path }
    static var skill: URL { Daemon.resources.appendingPathComponent("integrations/skills/reflex/SKILL.md") }

    /// What the button says to an agent when there's no template yet.
    static let buildPrompt = "Use the reflex skill to build my boat template, then move this session to boat, with everything this work needs."
    static func rebuildPrompt(_ changed: [String]) -> String {
        "Use the reflex skill to rebuild my boat template (changed here: \(changed.joined(separator: ", "))), then move this session to boat, with everything this work needs."
    }
    /// The window's button: only the agent knows what its work needs (other
    /// repositories, worktrees, files from Downloads), so it says, and Reflex
    /// copies them from wherever the agent is. The button was the OK.
    static func movePrompt(_ machine: String, made: Bool) -> String {
        let what = machine == here ? "this Mac, where Reflex runs" : made ? "a new boat machine made from my template" : "my machine \(machine)"
        return "Move this session to \(machine == here ? "here" : machine) (\(what)) with the reflex skill: work out everything this work needs besides this project, then reflex move self --to \(machine == here ? "here" : machine) PATH..."
    }

    /// This Mac, as a place to move to (reflex's ".").
    nonisolated static let here = "."
    /// A machine as reflex names it: "." for this Mac ("" in AgentInfo).
    static func name(_ machine: String) -> String { machine.isEmpty ? here : machine }

    private nonisolated(unsafe) static var boatFound: (at: Date, yes: Bool) = (.distantPast, false)
    /// The boat CLI is on the login PATH (looked for at most every 30 s).
    static var hasBoat: Bool {
        if Date().timeIntervalSince(boatFound.at) > 30 {
            let path = Daemon.shared.childEnvironment()["PATH"] ?? ""
            boatFound = (Date(), path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/boat") })
        }
        return boatFound.yes
    }

    /// hc's environment (this core's session, the login PATH), and where
    /// Reflex keeps its machines.
    private static func environment() -> [String: String] {
        var env = HerdrCore.environment()
        env["REFLEX_DATA"] = Settings.supportDir.path
        if let path = Daemon.shared.childEnvironment()["PATH"] { env["PATH"] = path }
        return env
    }

    /// `reflex <args>`: what it printed, or its last complaint.
    static func reflex(_ args: [String], timeout: TimeInterval = 600) async throws -> String {
        let env = environment(), exe = script
        let r = await Task.detached { MachineSetup.run(env, "/bin/sh", [exe] + args, timeout: timeout) }.value
        guard r.status == 0 else {
            let why = r.err.split(separator: "\n").last { !$0.isEmpty }.map(String.init) ?? "reflex \(args.first ?? "") failed (\(r.status))"
            throw Failure(message: why.replacingOccurrences(of: "reflex: ", with: ""))
        }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The boat machines Reflex made (and may delete).
    static func made(_ machine: String) -> Bool { CoreMachines.madeByReflex(machine) }

    static func newMachine(template: Bool) async throws -> String {
        try await reflex(["machine", "new"] + (template ? ["--template"] : []), timeout: 300)
    }

    /// The project around `dir` (on `from`), at the same ~ path there: that path.
    static func sync(_ machine: String, _ dir: String, from: String = here) async throws -> String {
        try await reflex(["sync", machine, dir, "--from", from], timeout: 3600)
    }

    /// What an agent said its work needs, from where it is.
    static func bring(_ machine: String, _ paths: [String], from: String) async throws {
        guard !paths.isEmpty else { return }
        _ = try await reflex(["bring", machine] + paths + ["--from", from], timeout: 3600)
    }

    static func copy(_ machine: String, _ paths: [String], from: String) async throws -> String {
        try await reflex(["copy", machine] + paths + ["--from", from], timeout: 3600)
    }

    static func list(_ path: String, from: String) async throws -> String {
        try await reflex(["list", path, "--from", from], timeout: 60)
    }

    /// The answer to a request asked on `machine` (reflex home).
    static func reply(_ machine: String, _ id: String, ok: Bool, message: String, output: String = "") async {
        let body: [String: Any] = ["ok": ok ? 1 : 0, "message": message, "output": output]
        guard let data = try? JSONSerialization.data(withJSONObject: body), let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await reflex(["bus", "reply", machine, id, json], timeout: 60)
    }

    static func creds(_ machine: String) async throws { _ = try await reflex(["creds", machine]) }

    /// The session file there, its cwd fields mapped: the folder and the
    /// session to resume there. Again later: only what it wrote since (a
    /// long session is copied while the agent is still here; after its
    /// close, the last lines).
    static func session(_ machine: String, kind: String, session: String, cwd: String, from: String = here) async throws -> (cwd: String, session: String) {
        let out = try await reflex(["session", machine, kind, session, cwd, "--from", from], timeout: 3600)
        let parts = out.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw Failure(message: "reflex session said \(out)") }
        return (parts[0], parts[1])
    }

    /// The machine and its sandbox, gone.
    static func remove(_ machine: String) async throws {
        _ = try await reflex(["machine", "rm", machine], timeout: 60)
        _ = await CoreMachines.list(fresh: 0)
    }

    // MARK: The skill and the command

    private static let harnesses = [".claude", ".codex", ".pi/agent"]

    /// Where the skill goes for each harness this Mac has.
    static var skillTargets: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return harnesses.map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { $0.appendingPathComponent("skills/reflex/SKILL.md") }
    }

    /// Every harness here has this version of the skill.
    static var skillInstalled: Bool {
        guard let want = try? Data(contentsOf: skill) else { return false }
        let targets = skillTargets
        return !targets.isEmpty && targets.allSatisfy { (try? Data(contentsOf: $0)) == want }
    }

    /// At launch: the skill in each harness here, and the link (`reflex` on
    /// PATH always: other machines' sessions reach it).
    static func updateInstalled() {
        linkCommand()
        // Every harness here (claude, codex, pi) has this version: a session
        // here may move, or be asked to.
        guard !skillTargets.isEmpty, !skillInstalled else { return }
        install()
    }

    /// The skill in each harness, and `reflex` on PATH (~/.local/bin).
    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default
        var ok = true
        for t in skillTargets {
            try? fm.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: t)
            if (try? fm.copyItem(at: skill, to: t)) == nil { ok = false }
        }
        return linkCommand() && ok
    }

    /// ~/.local/bin/reflex, this version's.
    @discardableResult
    static func linkCommand() -> Bool {
        let fm = FileManager.default
        let bin = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin")
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("reflex")
        guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) != script else { return true }
        try? fm.removeItem(at: link)
        return (try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: script)) != nil
    }
}

/// The user's boat template: a saved snapshot in their own boat account, built
/// by an agent with the reflex skill, and the files here it was built from
/// (stale once one of them changes).
@MainActor
final class BoatTemplate: ObservableObject {
    static let shared = BoatTemplate()

    enum State: Equatable {
        case unknown
        case none
        case current(built: String)
        case stale(built: String, changed: [String])
    }

    @Published private(set) var state: State = .unknown
    private var at = Date.distantPast

    var exists: Bool {
        switch state {
        case .current, .stale: return true
        case .none, .unknown: return false
        }
    }

    private struct Reply: Decodable {
        let state: String
        let at: String?
        let changed: [String]?
    }

    /// Read again when older than `fresh` seconds.
    func refresh(fresh: TimeInterval = 20) async {
        guard Date().timeIntervalSince(at) > fresh else { return }
        at = Date()
        let env = ["REFLEX_DATA": Settings.supportDir.path, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let exe = Boat.script
        let r = await Task.detached { MachineSetup.run(env, "/bin/sh", [exe, "template", "--json"], timeout: 10) }.value
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(r.out.utf8)) else { return }
        let built = reply.at ?? ""
        switch reply.state {
        case "current": state = .current(built: built)
        case "stale": state = .stale(built: built, changed: reply.changed ?? [])
        default: state = .none
        }
    }
}

/// `reflex move self --to M`: an agent asking to be moved. Each waits for
/// your OK here, unless Settings → Machines approves it for you.
@MainActor
final class MoveRequests: ObservableObject {
    static let shared = MoveRequests()

    struct Request: Identifiable, Equatable {
        let id: String
        let pane: String
        /// Where to, as this Reflex names it ("." for this Mac).
        let to: String
        /// To a machine Reflex made (a boat sandbox).
        let made: Bool
        /// What the agent said its work needs besides its project.
        var paths: [String] = []
    }

    @Published private(set) var pending: [Request] = []
    /// Agents asked to move by the window's button: their request is
    /// already approved. To that machine, or (nil) to the boat machine it
    /// makes while building the template.
    private var expected: [String: (to: String?, at: Date)] = [:]

    func expect(_ pane: String, to machine: String?) { expected[pane] = (machine, Date()) }
    func forget(_ pane: String) { expected[pane] = nil }

    /// A move an agent asked for (through the bus): this Reflex's to serve
    /// when it knows the machine. "here" / "home" is this Mac.
    func add(pane: String, id: String, to raw: String, paths: [String]) -> Bool {
        let to = ["here", "home", ".", "this mac"].contains(raw.lowercased()) ? Boat.here : raw
        guard to == Boat.here || CoreMachines.known.contains(where: { $0.name == to && $0.state == "connected" }) else { return false }
        guard Store.shared.state.agents.contains(where: { $0.pane == pane }) else {
            NSLog("Reflex: move request from %@ to %@: no such agent here", pane, to)
            return true
        }
        let r = Request(id: id, pane: pane, to: to, made: Boat.made(to), paths: paths)
        NSLog("Reflex: %@ asks to move to %@ (%d paths)", pane, to, paths.count)
        if autoApproved(r) {
            approve(r)
        } else {
            pending.removeAll { $0.pane == pane }
            pending.append(r)
            // Seen where it's asked: its terminal, in front.
            AppDelegate.current?.showPane(r.pane)
            NSApp.requestUserAttention(.informationalRequest)
        }
        return true
    }

    /// An agent that went away takes its question with it.
    func prune() {
        let live = Set(Store.shared.state.agents.map(\.pane))
        pending.removeAll { !live.contains($0.pane) }
    }

    private func autoApproved(_ r: Request) -> Bool {
        if let e = expected[r.pane], Date().timeIntervalSince(e.at) < 3 * 3600, e.to == r.to || (e.to == nil && r.made) {
            expected[r.pane] = nil
            return true
        }
        switch Settings.shared.moveApproval {
        case "always": return true
        case "made": return r.made
        default: return false
        }
    }

    func request(for pane: String) -> Request? { pending.first { $0.pane == pane } }

    func approve(_ r: Request) {
        pending.removeAll { $0.id == r.id }
        guard let a = Store.shared.state.agents.first(where: { $0.pane == r.pane }) else { return }
        HerdrMove.shared.move([a], to: r.to, with: r.paths)
    }

    func decline(_ r: Request) { pending.removeAll { $0.id == r.id } }
}

/// How long Reflex's boat machines stay up. Each starts with an hour; while
/// an agent there works (or waits on you), Reflex keeps renewing it, so the
/// hour only runs once the machine is idle (or Reflex isn't watching: quit,
/// asleep). A machine boat stopped is shown as stopped, with Resume: its
/// disk is kept, and its kept terminals start their agents again (same
/// sessions, same terminals), so their windows reattach.
@MainActor
final class BoatLifetime: ObservableObject {
    static let shared = BoatLifetime()
    static let hour = 3600

    /// Machines boat stopped, with their agents as last seen.
    @Published private(set) var down: [String: [AgentInfo]] = [:]
    @Published private(set) var resuming: Set<String> = []
    /// Why the last resume of a machine didn't work.
    @Published private(set) var problem: [String: String] = [:]
    /// When each machine last came back (windows on it reattach).
    @Published private(set) var back: [String: Date] = [:]

    private var seen: [String: [AgentInfo]] = [:]
    private var working: [String: Bool] = [:]
    private var renewed: [String: Date] = [:]
    private var asked: [String: Date] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { BoatLifetime.shared.tick() }
        }
        tick()
    }

    /// The machines Reflex made (their records).
    private var made: [String] {
        let dir = Settings.supportDir.appendingPathComponent("boat/machines")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    static func isWorking(_ a: AgentInfo) -> Bool { ["working", "blocked", "busy"].contains(a.status) }

    private func tick() {
        let machines = made
        let agents = Store.shared.state.agents
        let up = Set(CoreMachines.known.filter { $0.state == "connected" }.map(\.name))
        for m in machines where down[m] == nil && !resuming.contains(m) && up.contains(m) {
            let here = agents.filter { $0.machine == m }
            if !here.isEmpty { seen[m] = here }
            let now = here.contains(where: Self.isWorking)
            if now {
                // Never near the end while it works.
                if Date().timeIntervalSince(renewed[m] ?? .distantPast) > 600 { extend(m, "an agent works there") }
            } else if working[m] != false {
                // Just went idle (or first seen idle): the hour starts now.
                extend(m, "idle from now")
            }
            working[m] = now
        }
        for m in Array(down.keys) where !machines.contains(m) { down[m] = nil }
        Task { await checkDown(machines) }
    }

    private func extend(_ m: String, _ why: String) {
        NSLog("Reflex: %@ stays up another hour (%@)", m, why)
        renewed[m] = Date()
        Task { _ = try? await Boat.reflex(["machine", "extend", m, String(Self.hour)], timeout: 60) }
    }

    /// One herdr-core can't reach: boat's word on it (a minute apart).
    private func checkDown(_ machines: [String]) async {
        let states = Dictionary(await CoreMachines.list().map { ($0.name, $0.state) }, uniquingKeysWith: { a, _ in a })
        for m in machines where states[m] != "connected" && states[m] != "connecting" && down[m] == nil && !resuming.contains(m) {
            guard Date().timeIntervalSince(asked[m] ?? .distantPast) > 60 else { continue }
            asked[m] = Date()
            guard let s = try? await Boat.reflex(["machine", "state", m], timeout: 30) else { continue }
            if ["stopped", "stopping", "archived", "suspended"].contains(s), down[m] == nil {
                down[m] = seen[m] ?? []
                working[m] = nil
                NSLog("Reflex: boat stopped %@ (%@), %d agents there", m, s, down[m]?.count ?? 0)
                if !(seen[m] ?? []).isEmpty { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
    }

    func isDown(_ machine: String) -> Bool { down[machine] != nil }

    /// Up again: boat resumes it from its disk, herdr-core reconnects, and its
    /// agents start again in the same terminals.
    func resume(_ m: String) {
        guard !resuming.contains(m) else { return }
        resuming.insert(m)
        problem[m] = nil
        Task {
            defer { resuming.remove(m) }
            do {
                _ = try await Boat.reflex(["machine", "resume", m], timeout: 300)
                NSLog("Reflex: %@ resumed", m)
                down[m] = nil
                working[m] = nil
                renewed[m] = Date()
                _ = await CoreMachines.list(fresh: 0)
                // (Its kept terminals take a moment to start their agents.)
                try? await Task.sleep(for: .seconds(3))
                back[m] = Date()
            } catch {
                problem[m] = error.localizedDescription
            }
        }
    }
}
