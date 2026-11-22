import AppKit
import Combine
import Foundation

/// A service Reflex makes machines on: boat.dev's sandboxes, or instabox's
/// boxes (a box Reflex pauses when it's done keeps its programs, and comes
/// back as it was). scripts/reflex.sh tells a machine's by its id.
enum Sandbox: String, CaseIterable, Identifiable {
    case boat, instabox
    var id: String { rawValue }
    /// "@boat", "@instabox", and the move menu's section.
    var key: String { rawValue }
    var title: String { self == .boat ? "boat.dev" : "instabox" }
    /// What one machine of it is called: "a new boat machine".
    var noun: String { self == .boat ? "boat machine" : "instabox box" }
    var nouns: String { self == .boat ? "boat machines" : "instabox boxes" }
    var symbol: String { self == .boat ? "sailboat" : "cube" }

    @MainActor var size: String { self == .boat ? Settings.shared.boatType : Settings.shared.instaboxSize }
    /// The size Settings asks for ([] for the service's default).
    @MainActor var sizeArgs: [String] { size.isEmpty ? [] : ["--type", size] }

    private nonisolated(unsafe) static var found: [Sandbox: (at: Date, yes: Bool)] = [:]
    /// Its CLI is on the login PATH (looked for at most every 30 s).
    @MainActor var installed: Bool {
        if let f = Self.found[self], Date().timeIntervalSince(f.at) < 30 { return f.yes }
        let path = Daemon.shared.childEnvironment()["PATH"] ?? ""
        let yes = path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(rawValue)") }
        Self.found[self] = (Date(), yes)
        return yes
    }
    @MainActor static var available: [Sandbox] { allCases.filter(\.installed) }

    /// The service a machine Reflex made, or one shared with this Mac, is on:
    /// its record's id (bx_..., m_...), else how herdr-core reaches it.
    @MainActor static func of(_ machine: String) -> Sandbox? {
        let record = Settings.supportDir.appendingPathComponent("boat/machines/\(machine)")
        if let id = (try? String(contentsOf: record, encoding: .utf8))?.split(separator: "\n").first {
            return id.hasPrefix("m_") ? .instabox : .boat
        }
        let target = CoreMachines.known.first { $0.name == machine }?.target ?? ""
        if target.contains("instabox ssh m_") { return .instabox }
        if target.contains("boat ssh bx_") { return .boat }
        return nil
    }

    @MainActor var template: BoatTemplate { self == .boat ? .shared : .instabox }
}

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
    static func buildPrompt(_ p: Sandbox) -> String {
        "Use the reflex skill to build my \(p.rawValue) template\(flag(p)), then move this session to \(p.rawValue), with everything this work needs."
    }
    static func rebuildPrompt(_ p: Sandbox, _ changed: [String]) -> String {
        "Use the reflex skill to rebuild my \(p.rawValue) template\(flag(p)) (changed here: \(changed.joined(separator: ", "))), then move this session to \(p.rawValue), with everything this work needs."
    }
    /// (boat is the skill's default; instabox is named.)
    private static func flag(_ p: Sandbox) -> String { p == .boat ? "" : " (--provider \(p.rawValue) on reflex template and reflex machine new)" }
    /// The window's button: only the agent knows what its work needs (other
    /// repositories, worktrees, files from Downloads), so it says, and Reflex
    /// copies them from wherever the agent is. The button was the OK.
    static func movePrompt(_ machine: String, made: Bool) -> String {
        let what = machine == here ? "this Mac, where Reflex runs" : made ? "a new \((Sandbox.of(machine) ?? .boat).noun) made from my template" : "my machine \(machine)"
        return "Move this session to \(machine == here ? "here" : machine) (\(what)) with the reflex skill: work out everything this work needs besides this project, then reflex move self --to \(machine == here ? "here" : machine) PATH..."
    }

    /// This Mac, as a place to move to (reflex's ".").
    nonisolated static let here = "."
    /// A machine as reflex names it: "." for this Mac ("" in AgentInfo).
    static func name(_ machine: String) -> String { machine.isEmpty ? here : machine }

    /// The boat CLI is on the login PATH.
    static var hasBoat: Bool { Sandbox.boat.installed }
    /// Some service's CLI is: Reflex can make a machine.
    static var hasSandbox: Bool { !Sandbox.available.isEmpty }

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
        let r = await Blocking.run { MachineSetup.run(env, "/bin/sh", [exe] + args, timeout: timeout) }
        guard r.status == 0 else {
            let why = r.err.split(separator: "\n").last { !$0.isEmpty }.map(String.init) ?? "reflex \(args.first ?? "") failed (\(r.status))"
            throw Failure(message: why.replacingOccurrences(of: "reflex: ", with: ""))
        }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sandboxes Reflex made (and may delete).
    static func made(_ machine: String) -> Bool { CoreMachines.madeByReflex(machine) }

    /// The size Settings asks for a machine resumed ([] keeps its own; an
    /// instabox box keeps its own size).
    static func resumeArgs(_ machine: String) -> [String] { Sandbox.of(machine) == .boat ? Sandbox.boat.sizeArgs : [] }

    static func newMachine(template: Bool, on p: Sandbox = .boat) async throws -> String {
        try await reflex(["machine", "new", "--provider", p.rawValue] + (template ? ["--template"] : []) + p.sizeArgs, timeout: 300)
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

    /// A shell line on `from`: its output (stdout and stderr) and exit code.
    static func runAt(_ command: String, from: String, dir: String, timeout: Int) async -> (code: Int32, output: String) {
        let env = environment(), exe = script
        let args = [exe, "run-at", "--from", from, "--cwd", dir, "--timeout", String(timeout), "--", command]
        let r = await Blocking.run { MachineSetup.run(env, "/bin/sh", args, timeout: TimeInterval(timeout + 30)) }
        return (r.status, r.out + r.err)
    }

    static func list(_ path: String, from: String) async throws -> String {
        try await reflex(["list", path, "--from", from], timeout: 60)
    }

    /// The answer to a request asked on `machine` (reflex home).
    /// Whether the session that asked still waits for the answer.
    static func asking(_ machine: String, _ id: String) async -> Bool {
        (try? await reflex(["bus", "alive", machine, id], timeout: 20)) != nil
    }

    static func reply(_ machine: String, _ id: String, ok: Bool, message: String, output: String = "") async {
        await reply(machine, id, ["ok": ok ? 1 : 0, "message": message, "output": output])
    }

    static func reply(_ machine: String, _ id: String, _ body: [String: Any]) async {
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
    static let shared = BoatTemplate(.boat)
    static let instabox = BoatTemplate(.instabox)
    /// The service its snapshot is in (each has its own template).
    let provider: Sandbox
    private init(_ p: Sandbox) { provider = p }

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
        let args = [exe, "template", "--provider", provider.rawValue, "--json"]
        let r = await Blocking.run { MachineSetup.run(env, "/bin/sh", args, timeout: 10) }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(r.out.utf8)) else { return }
        apply(reply)
    }

    private func apply(_ reply: Reply) {
        let built = reply.at ?? ""
        switch reply.state {
        case "current": state = .current(built: built)
        case "stale": state = .stale(built: built, changed: reply.changed ?? [])
        default: state = .none
        }
    }

    /// What changed here doesn't matter to the template: it's current.
    func keep() {
        let env = ["REFLEX_DATA": Settings.supportDir.path, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let exe = Boat.script
        let args = [exe, "template", "--provider", provider.rawValue, "--keep"]
        Task {
            _ = await Blocking.run { MachineSetup.run(env, "/bin/sh", args, timeout: 10) }
            at = .distantPast
            await refresh(fresh: 0)
        }
    }

    /// An agent rebuilds it, in a new session of its own (no session moves),
    /// its window open to watch.
    func rebuild() {
        let changed: [String]
        if case .stale(_, let c) = state { changed = c } else { changed = [] }
        let home = NSHomeDirectory()
        let named = provider == .boat ? "" : " (--provider \(provider.rawValue) on reflex template and reflex machine new)"
        let prompt = "Use the reflex skill to rebuild my \(provider.rawValue) template\(named)" + (changed.isEmpty ? "" : " (changed here since it was built: \(changed.joined(separator: ", ")))")
            + ". Don't move this session afterwards; tell me when the new template is saved."
        Boat.install()
        Task {
            guard let p = try? await Client.local.spawn(cwd: home, kind: Settings.shared.harness, text: prompt) else { return }
            Sessions.watchStart(p.id, cwd: home, open: true)
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
        /// When the asking session stops waiting (0: never said).
        var until: Int = 0
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
    func add(pane: String, id: String, to raw: String, paths: [String], until: Int = 0) -> Bool {
        let to = ["here", "home", ".", "this mac"].contains(raw.lowercased()) ? Boat.here : raw
        guard to == Boat.here || CoreMachines.known.contains(where: { $0.name == to && $0.state == "connected" }) else { return false }
        guard Store.shared.state.agents.contains(where: { $0.pane == pane }) else {
            NSLog("Reflex: move request from %@ to %@: no such agent here", pane, to)
            return true
        }
        let r = Request(id: id, pane: pane, to: to, made: Boat.made(to), paths: paths, until: until)
        NSLog("Reflex: %@ asks to move to %@ (%d paths)", pane, to, paths.count)
        if autoApproved(r) {
            approve(r)
        } else {
            pending.removeAll { $0.pane == pane }
            pending.append(r)
            // Seen in its window when that's open, the inbox and the rail;
            // never by taking you away from what you're in.
            NSApp.requestUserAttention(.informationalRequest)
            MachineNotes.post(r.pane, title: "asks to move to \(to == Boat.here ? "this Mac" : to)",
                              body: paths.isEmpty ? "Move or Not Now in its window." : "With " + paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + ". Move or Not Now in its window.",
                              needsYou: true)
        }
        return true
    }

    /// An agent that went away, or stopped waiting, takes its question with it.
    func prune() {
        let live = Set(Store.shared.state.agents.map(\.pane))
        let now = Int(Date().timeIntervalSince1970)
        pending.removeAll { !live.contains($0.pane) || ($0.until > 0 && now > $0.until) }
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
/// asleep). One with a session's terminal window open on any of your Macs
/// never stops (it holds itself up while one does), nor one whose CPUs
/// work. A machine boat stopped is shown as stopped, with Resume: its
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
    /// Since when its agents have all been idle, and when it was last asked
    /// for work left running (`reflex machine busy`).
    private var quietSince: [String: Date] = [:]
    private var probedAt: [String: Date] = [:]
    /// Kept up by background work alone for `backgroundLimit`: no longer.
    private var capped: Set<String> = []
    /// How long work left running keeps a sandbox up while its agents are
    /// idle (a stray daemon shouldn't keep one up for good).
    static let backgroundLimit: TimeInterval = 12 * 3600
    private var timer: Timer?
    /// What this Mac last told each machine it holds (its open windows'
    /// panes there; [] let go), and when; a hold being sent.
    private var held: [String: [String]] = [:]
    private var heldAt: [String: Date] = [:]
    private var holding: Set<String> = []
    /// This Mac's name in holds (`reflex id`).
    private var holder: String?
    /// When a held machine boat stopped anyway was last resumed by itself.
    private var autoResumed: [String: Date] = [:]
    /// Why each machine is down: boat's word ("stopped", or "error" for one
    /// whose machine boat lost).
    @Published private(set) var downWhy: [String: String] = [:]
    /// Since when boat has called a machine `error` (lost): down past a grace.
    private var erroredAt: [String: Date] = [:]
    static let errorGrace: TimeInterval = 600
    /// The sessions each machine ran when last looked at (`reflex machine
    /// sessions`: whoever started them, an agent too), kept on disk: what one
    /// boat lost has again.
    struct Ran: Codable, Equatable { var kind: String; var cwd: String; var session: String }
    private struct Sessions: Decodable { var up: Int; var agents: [Ran] }
    private var ran: [String: [Ran]] = [:]
    private var ranAt: [String: Date] = [:]
    private var recording: Set<String> = []
    /// When each instabox box was last asked whether its time is up.
    private var lapsedAt: [String: Date] = [:]
    /// Being paused or turned off now (Settings → Machines).
    @Published private(set) var sleeping: Set<String> = []
    /// Paused or turned off by you: down until you resume it, even with a
    /// window open on it here, and when.
    @Published private(set) var putDown: [String: Date] = [:]

    /// Paused (an instabox box: its programs kept, only its disk costs) or
    /// turned off (stopped; a boat sandbox can only be this), now.
    func sleep(_ m: String, off: Bool) {
        guard !sleeping.contains(m), !resuming.contains(m), down[m] == nil else { return }
        sleeping.insert(m)
        problem[m] = nil
        Task {
            defer { sleeping.remove(m) }
            do {
                let s = try await Boat.reflex(["machine", off ? "off" : "pause", m], timeout: 600)
                putDown[m] = Date()
                down[m] = seen[m] ?? Store.shared.state.agents.filter { $0.machine == m }
                downWhy[m] = s == "paused" ? "suspended" : "stopped"
                working[m] = nil
                held[m] = nil
                NSLog("Reflex: %@ %@ (asked here)", m, s)
            } catch {
                problem[m] = error.localizedDescription
            }
        }
    }

    /// Every sandbox up, paused (boat's stopped): the quick way to stop paying for them.
    func sleepAll() {
        let up = Set(CoreMachines.known.filter { $0.state == "connected" }.map(\.name))
        for m in made + shared where up.contains(m) && down[m] == nil { sleep(m, off: Sandbox.of(m) == .boat) }
    }

    /// Up, and Reflex's or shared with this Mac: what Pause All would pause.
    var awake: [String] {
        let up = Set(CoreMachines.known.filter { $0.state == "connected" }.map(\.name))
        return (made + shared).filter { up.contains($0) && down[$0] == nil }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { BoatLifetime.shared.tick() }
        }
        tick()
    }

    /// The machines Reflex made here (their records).
    private var made: [String] {
        let dir = Settings.supportDir.appendingPathComponent("boat/machines")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// The boat sandboxes another Mac shared with this one. Looked after
    /// here too, so they stay up and come back with that Mac off (it takes
    /// a boat login here, which the mesh gives a Mac that has none).
    /// Renewing sets the hour again: two Macs doing it are the same as one.
    private var shared: [String] {
        let dir = Settings.supportDir.appendingPathComponent("boat/shared")
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") })
        return CoreMachines.known.filter { names.contains($0.name) && ($0.target.contains("boat ssh bx_") || $0.target.contains("instabox ssh m_")) }.map(\.name)
    }

    /// Whether the Mac that shared `m` is reachable (it says when it stops).
    private func ownerAround(_ m: String) -> Bool {
        func base(_ s: String) -> String { s.lowercased().replacingOccurrences(of: ".local", with: "") }
        guard let owner = CoreMachines.sharedFrom(m), !owner.isEmpty else { return false }
        return CoreMachines.known.contains { $0.state == "connected" && !$0.host.isEmpty && base($0.host) == base(owner) }
    }

    static func isWorking(_ a: AgentInfo) -> Bool { ["working", "blocked", "busy"].contains(a.status) }

    private func tick() {
        let machines = made + shared.filter { !made.contains($0) }
        let agents = Store.shared.state.agents
        let up = Set(CoreMachines.known.filter { $0.state == "connected" }.map(\.name))
        for m in machines where down[m] == nil && !resuming.contains(m) && up.contains(m) {
            let here = agents.filter { $0.machine == m }
            if !here.isEmpty { seen[m] = here }
            let now = here.contains(where: Self.isWorking)
            if now {
                // Never near the end while it works.
                if Date().timeIntervalSince(renewed[m] ?? .distantPast) > 600 { extend(m, "an agent works there") }
                quietSince[m] = nil
                capped.remove(m)
            } else {
                if working[m] != false {
                    // Just went idle (or first seen idle): the hour starts now.
                    extend(m, "idle from now")
                    quietSince[m] = Date()
                }
                // Agents idle isn't the sandbox idle: one may be waiting on
                // work it left running there.
                if Date().timeIntervalSince(probedAt[m] ?? .distantPast) > 300 { probe(m) }
                // An instabox box's time is Reflex's to end: past it, with no
                // window open on it on any Mac, it pauses (its programs kept).
                if Sandbox.of(m) == .instabox, Date().timeIntervalSince(lapsedAt[m] ?? .distantPast) > 120 { lapse(m) }
            }
            working[m] = now
            erroredAt[m] = nil
            record(m)
        }
        hold(machines, up: up)
        for m in Array(down.keys) where !machines.contains(m) { down[m] = nil; downWhy[m] = nil }
        // Back without Resume here (another Reflex, boat itself, a script):
        // not stopped any more, and its windows reattach. Its sessions again,
        // from the Mac that made it (one Mac, not each).
        for m in Array(down.keys) where up.contains(m) && !resuming.contains(m) {
            // (Just paused here: herdr-core takes a moment to see it gone.)
            if let at = putDown[m], Date().timeIntervalSince(at) < 120 { continue }
            putDown[m] = nil
            NSLog("Reflex: %@ is connected again", m)
            let were = down[m] ?? []
            down[m] = nil
            downWhy[m] = nil
            back[m] = Date()
            if made.contains(m) { Task { await bringBack(m, were: were) } }
        }
        Task { await checkDown(machines) }
    }

    /// Work an agent left running there (a waiter on a remote run, a build,
    /// a loop) keeps the hour renewed, as an agent working does, up to
    /// `backgroundLimit` after the agents went idle.
    private func probe(_ m: String) {
        probedAt[m] = Date()
        Task {
            guard let out = try? await Boat.reflex(["machine", "busy", m], timeout: 60) else {
                // No answer in time: a machine too busy to answer isn't idle
                // (a slow one is what full CPUs look like from here).
                guard working[m] == false, down[m] == nil else { return }
                if Date().timeIntervalSince(renewed[m] ?? .distantPast) > 600 { extend(m, "it didn't answer the check for work") }
                return
            }
            let lines = out.split(separator: "\n").map(String.init)
            guard let first = lines.first, first != "none", working[m] == false, down[m] == nil else { return }
            let quiet = Date().timeIntervalSince(quietSince[m] ?? Date())
            // Its CPUs working is never idle, however long.
            let cpu = lines.dropFirst().first?.hasPrefix("cpu:") == true
            if quiet < Self.backgroundLimit || cpu {
                if Date().timeIntervalSince(renewed[m] ?? .distantPast) > 600 {
                    extend(m, "background work: \(lines.dropFirst().first ?? first)".prefix(160).description)
                }
            } else if !capped.contains(m) {
                capped.insert(m)
                NSLog("Reflex: %@ kept up %d h by background work alone; the last hour starts", m, Int(quiet / 3600))
                MachineNotes.post(seen[m]?.first?.pane ?? "", title: "\(m) stops in an hour",
                                  body: "Its agents have been idle \(Int(quiet / 3600)) hours while work they left runs there. Reflex kept it up that long; it stops in an hour unless an agent works.")
            }
        }
    }

    /// A session there with its terminal window open here: the machine
    /// never stops. Renewed from here every 10 minutes, and held there too
    /// (`reflex machine hold`: the sandbox renews itself while any Mac holds
    /// it, so this Mac asleep still holds it). Stopped anyway (boat itself):
    /// resumed at once. A window closed lets go; a first pass after launch
    /// lets go of what an earlier run held.
    private func hold(_ machines: [String], up: Set<String>) {
        let open = Dictionary(grouping: AppDelegate.current?.openPanes ?? [], by: { Machines.machine(of: $0) })
        for m in machines {
            let panes = (open[m] ?? []).sorted()
            if !panes.isEmpty {
                if down[m] != nil {
                    // (One you paused stays paused: Resume brings it back.)
                    if putDown[m] == nil, !resuming.contains(m), Date().timeIntervalSince(autoResumed[m] ?? .distantPast) > 300 {
                        autoResumed[m] = Date()
                        NSLog("Reflex: %@ stopped with a window open on it here; resuming it", m)
                        resume(m)
                    }
                } else if up.contains(m), Date().timeIntervalSince(renewed[m] ?? .distantPast) > 600 {
                    extend(m, "a window is open on it here")
                }
            }
            guard up.contains(m), down[m] == nil, !holding.contains(m) else { continue }
            // (Changed, or again every 10 minutes while held: a restart there
            // ends its loop.)
            if held[m] == panes && (panes.isEmpty || Date().timeIntervalSince(heldAt[m] ?? .distantPast) < 600) { continue }
            holding.insert(m)
            Task {
                defer { holding.remove(m) }
                if holder == nil { holder = try? await Boat.reflex(["id"], timeout: 30) }
                guard let me = holder, !me.isEmpty else { return }
                do {
                    _ = try await Boat.reflex(["machine", "hold", m, me] + panes, timeout: 60)
                    if held[m] != panes { NSLog("Reflex: %@ %@", m, panes.isEmpty ? "let go (no window open on it here)" : "held by \(panes.count) open window(s) here") }
                    held[m] = panes
                    heldAt[m] = Date()
                } catch {
                    NSLog("Reflex: holding %@ didn't work: %@", m, error.localizedDescription)
                }
            }
        }
    }

    /// `reflex machine lapse`: paused when its time is up and nothing holds it.
    private func lapse(_ m: String) {
        lapsedAt[m] = Date()
        Task {
            guard let out = try? await Boat.reflex(["machine", "lapse", m], timeout: 60) else { return }
            if out == "paused" { NSLog("Reflex: %@ paused (an hour idle, no window open on it)", m) }
        }
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
            // boat lost its machine (unreachable): down once that lasts (it
            // can come back by itself), and brought back like a stopped one.
            if s == "error" {
                let since = erroredAt[m] ?? Date()
                erroredAt[m] = since
                guard Date().timeIntervalSince(since) >= Self.errorGrace else { continue }
            } else {
                erroredAt[m] = nil
            }
            if ["stopped", "stopping", "archived", "suspended", "error"].contains(s), down[m] == nil {
                down[m] = seen[m] ?? []
                downWhy[m] = s
                working[m] = nil
                let svc = Sandbox.of(m) ?? .boat
                NSLog("Reflex: %@ %@ %@ (%@), %d agents there", svc.rawValue, s == "error" ? "lost" : "stopped", m, s, down[m]?.count ?? 0)
                // (One Mac says so: the one that made it, else any that sees it.)
                guard made.contains(m) || !ownerAround(m) else { continue }
                if s == "error" {
                    MachineNotes.post(seen[m]?.first?.pane ?? "", title: "\(m) stopped answering",
                                      body: "\(svc.rawValue) lost the machine it runs on (unreachable for \(Int(Self.errorGrace / 60)) minutes). Its disk is kept: Resume in its window or Settings → Machines brings it back with its sessions.")
                } else if svc == .instabox && s == "suspended" {
                    MachineNotes.post(seen[m]?.first?.pane ?? "", title: "\(m) paused",
                                      body: "Reflex pauses an instabox box an hour after its agents go idle, with no window open on it. Its programs are kept as they were: Resume in its window or Settings → Machines carries on where it left off.")
                } else {
                    MachineNotes.post(seen[m]?.first?.pane ?? "", title: "\(m) stopped",
                                      body: "boat stops a sandbox after an hour idle. Its disk is kept 14 days: Resume in its window or Settings → Machines brings it back with its agents.")
                }
                if !(seen[m] ?? []).isEmpty { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
    }

    func isDown(_ machine: String) -> Bool { down[machine] != nil }

    private static func ranFile(_ m: String) -> URL {
        Settings.supportDir.appendingPathComponent("boat/sessions").appendingPathComponent(m + ".json")
    }

    /// What `m` last ran (from disk after a launch).
    private func lastRan(_ m: String) -> [Ran] {
        if let r = ran[m] { return r }
        let r = (try? Data(contentsOf: Self.ranFile(m))).flatMap { try? JSONDecoder().decode([Ran].self, from: $0) } ?? []
        ran[m] = r
        return r
    }

    /// Looked at every 2 minutes while it's up. Not in its first 10 minutes
    /// up: what it runs then isn't what it ran yet (its sessions are coming
    /// back), and the record stays.
    private func record(_ m: String) {
        guard !recording.contains(m), Date().timeIntervalSince(ranAt[m] ?? .distantPast) > 120 else { return }
        recording.insert(m)
        ranAt[m] = Date()
        Task {
            defer { recording.remove(m) }
            guard let s = await Self.sessions(on: m), s.up >= 600, s.agents != lastRan(m) else { return }
            ran[m] = s.agents
            let f = Self.ranFile(m)
            try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(s.agents).write(to: f, options: .atomic)
        }
    }

    private static func sessions(on m: String) async -> Sessions? {
        guard let out = try? await Boat.reflex(["machine", "sessions", m], timeout: 60) else { return nil }
        return try? JSONDecoder().decode(Sessions.self, from: Data(out.utf8))
    }

    /// Back after boat stopped or lost it: every session it ran that doesn't
    /// run there now starts again, in its conversation. What it ran is its
    /// last record (agents' own sessions too), else the agents last listed
    /// here; what runs now is what it says (asked while it starts), never the
    /// list here, which can still show them as they were.
    private func bringBack(_ m: String, were: [AgentInfo]) async {
        var want = lastRan(m)
        if want.isEmpty {
            want = were.filter { HerdrMove.kinds.contains($0.kind) && !$0.session.isEmpty }
                .map { Ran(kind: $0.kind, cwd: $0.cwd, session: $0.session) }
        }
        var once = Set<String>()
        want = want.filter { once.insert($0.kind + "\u{0}" + $0.session).inserted }
        guard !want.isEmpty else { return }
        var now: Set<String>?
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
            if let s = await Self.sessions(on: m) { now = Set(s.agents.map(\.session)); break }
        }
        guard let now else {
            NSLog("Reflex: %@ didn't say what it runs; its %d sessions weren't started again", m, want.count)
            return
        }
        // (A pi session is its id or its file's name, which ends with it.)
        func runs(_ s: String) -> Bool { now.contains { $0 == s || $0.hasSuffix(s) || s.hasSuffix($0) } }
        for r in want where !runs(r.session) {
            let folder = (r.cwd as NSString).lastPathComponent
            NSLog("Reflex: %@ in %@ on %@ didn't come back; resuming its session", r.kind, folder, m)
            do {
                _ = try await Client.local.resume(cwd: Place.on(m, r.cwd), kind: r.kind, session: r.session,
                                                  label: "resume \(r.kind) · \(folder) on \(m)")
            } catch {
                NSLog("Reflex: resuming %@'s session on %@ didn't work: %@", r.kind, m, error.localizedDescription)
            }
        }
    }

    /// Up again: boat resumes it from its disk, herdr-core reconnects, and its
    /// agents start again in the same terminals.
    func resume(_ m: String) {
        guard !resuming.contains(m) else { return }
        resuming.insert(m)
        problem[m] = nil
        Task {
            defer { resuming.remove(m) }
            let were = down[m] ?? []
            do {
                // (A lost machine's stop can take a while to give up.)
                _ = try await Boat.reflex(["machine", "resume", m] + Boat.resumeArgs(m), timeout: 2400)
                NSLog("Reflex: %@ resumed", m)
                putDown[m] = nil
                down[m] = nil
                downWhy[m] = nil
                erroredAt[m] = nil
                working[m] = nil
                renewed[m] = Date()
                _ = await CoreMachines.list(fresh: 0)
                // (Its kept terminals take a moment to start their agents.)
                try? await Task.sleep(for: .seconds(8))
                back[m] = Date()
                // Any that didn't come back (a stopped VM ran nothing on, so
                // its herdr-core starts empty): their sessions again, there.
                await bringBack(m, were: were)
            } catch {
                problem[m] = error.localizedDescription
            }
        }
    }
}
