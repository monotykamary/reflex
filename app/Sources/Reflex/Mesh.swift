import AppKit
import Combine
import Foundation

/// The line home. A session on another machine (a boat sandbox, another of
/// your Macs) can't reach this Mac; this Mac's herdr-core keeps an ssh line
/// to it. Reflex keeps a `reflex bus listen` waiting at the far end of each
/// line (and one here, for this Mac's own sessions), so what a session asks
/// with `reflex home …` or `reflex move self …` reaches Reflex at once, and
/// the answer goes back the same way. Requests name the Reflex that moved
/// the session; another Reflex takes one nobody answered in 20 s.
@MainActor
final class Bus {
    static let shared = Bus()

    private var listening: [String: Task<Void, Never>] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { Bus.shared.refresh() }
        }
        refresh()
    }

    /// One listener per machine that's up (and this Mac), from a list read
    /// now and then (not one only other screens refresh: just launched, it's
    /// empty).
    private func refresh() {
        Task { _ = await CoreMachines.list(fresh: 20) }
        MoveRequests.shared.prune()
        HomeRequests.shared.prune()
        let up = [Boat.here] + CoreMachines.known.filter { $0.state == "connected" }.map(\.name)
        for m in up where listening[m] == nil {
            listening[m] = Task { [weak self] in await self?.listen(m) }
        }
        for (m, t) in listening where !up.contains(m) {
            t.cancel()
            listening[m] = nil
        }
    }

    private struct Request: Decodable {
        let op: String
        let id: String
        let pane: String?
        let to: String?
        let paths: [String]?
        let origin: String?
        let command: String?
        let dir: String?
        let timeout: String?
        /// `reflex on NAME …`: that machine, not the session's origin.
        let on: String?
        /// When the asking session stops waiting.
        let until: Int?
    }

    private func listen(_ m: String) async {
        while !Task.isCancelled {
            guard let out = try? await Boat.reflex(["bus", "listen", m, "60"], timeout: 120) else {
                try? await Task.sleep(for: .seconds(15))
                continue
            }
            for line in out.split(separator: "\n") {
                guard let r = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else { continue }
                // Ours to answer only once claimed: another Reflex (or this
                // one, a moment ago) may have taken it.
                guard (try? await Boat.reflex(["bus", "claim", m, r.id], timeout: 30)) != nil else { continue }
                await handle(m, r)
            }
        }
    }

    private func handle(_ m: String, _ r: Request) async {
        let local = r.pane ?? ""
        let pane = local.isEmpty ? "" : m == Boat.here ? local : "\(m)/\(local)"
        var origin = (r.origin ?? "").isEmpty ? Boat.here : r.origin!
        if let on = r.on, !on.isEmpty {
            if ["here", "home", ".", "this mac"].contains(on.lowercased()) {
                origin = Boat.here
            } else if CoreMachines.known.contains(where: { $0.name == on && $0.state == "connected" }) {
                origin = on
            } else {
                await Boat.reply(m, r.id, ok: false, message: "No machine called \(on) here (reflex home machines lists them; \"here\" is the Mac Reflex runs on).")
                return
            }
        }
        switch r.op {
        case "move":
            let to = r.to ?? ""
            if MoveRequests.shared.add(pane: pane, id: r.id, to: to, paths: r.paths ?? [], until: r.until ?? 0) {
                await Boat.reply(m, r.id, ok: true, message: "Reflex has it: the user approves the move, and it happens once this turn ends. End your turn now.")
            } else {
                await Boat.reply(m, r.id, ok: false, message: "No machine called \(to) here (reflex home machines lists them; \"here\" is the Mac Reflex runs on).")
            }
        case "fetch", "ls":
            HomeRequests.shared.add(.init(id: r.id, machine: m, pane: pane, op: r.op, paths: r.paths ?? [], origin: origin, until: r.until ?? 0))
        case "run":
            HomeRequests.shared.add(.init(id: r.id, machine: m, pane: pane, op: "run", paths: [], origin: origin, until: r.until ?? 0,
                                          command: r.command ?? "", dir: r.dir ?? "~", timeout: Int(r.timeout ?? "") ?? 120))
        case "machines":
            let up = CoreMachines.known.filter { $0.state == "connected" }.map(\.name)
            let list = (["here (\(Host.current().localizedName ?? "this Mac"), where Reflex runs)"] + up.map { $0 + (Boat.made($0) ? " (boat sandbox)" : "") })
            await Boat.reply(m, r.id, ok: true, message: "Machines Reflex reaches:", output: list.joined(separator: "\n"))
        default:
            await Boat.reply(m, r.id, ok: false, message: "Reflex doesn't know \(r.op)")
        }
    }
}

/// A session elsewhere asking this Mac for files (`reflex home fetch`), what's
/// in a folder (`reflex home ls`), or to run a command (`reflex home run`):
/// yours to allow, unless Settings allows it. Files go to the same ~ path
/// there; a command's output and exit code go back. A boat sandbox's command
/// always asks: what it read could have been written by anyone.
@MainActor
final class HomeRequests: ObservableObject {
    static let shared = HomeRequests()

    struct Request: Identifiable, Equatable {
        let id: String
        /// The machine that asked ("." for this Mac).
        let machine: String
        let pane: String
        let op: String
        let paths: [String]
        /// Where the files are, as this Reflex names it.
        let origin: String
        /// When the asking session stops waiting (0: never said).
        var until = 0
        var command = ""
        var dir = "~"
        var timeout = 120

        var what: String {
            if op == "run" { return command }
            let names = paths.map { ($0 as NSString).lastPathComponent }
            return op == "ls" ? "what's in \(paths.first ?? "~")" : names.count == 1 ? names[0] : "\(names.count) items"
        }
    }

    @Published private(set) var pending: [Request] = []
    /// What a request is doing, by pane.
    @Published private(set) var notes: [String: String] = [:]

    func add(_ r: Request) {
        if allowed(r) {
            Task { await serve(r) }
        } else {
            pending.append(r)
            // (Its window shows it when open; the inbox and rail always. No
            // taking you away from what you're in.)
            NSApp.requestUserAttention(.informationalRequest)
            let from = r.origin == Boat.here ? "this Mac" : r.origin
            let title = r.op == "run" ? "asks to run a command on \(from)" : r.op == "ls" ? "asks what's in \(r.paths.first ?? "~") on \(from)" : "asks for \(r.what) from \(from)"
            MachineNotes.post(r.pane, title: title,
                              body: (r.op == "run" ? r.command : r.paths.joined(separator: "\n")) + "\n\n" + (r.op == "run" ? "Run" : r.op == "ls" ? "Show" : "Send") + " or Not Now in its window.",
                              needsYou: true)
        }
    }

    private func allowed(_ r: Request) -> Bool {
        if r.op == "run" {
            // Your other Macs, when Settings says so; a sandbox never.
            return Settings.shared.runApproval == "macs" && r.machine != Boat.here && !Boat.made(r.machine)
                && CoreMachines.known.first(where: { $0.name == r.machine })?.temporary == false
        }
        switch Settings.shared.fileApproval {
        case "always": return true
        case "made": return Boat.made(r.machine)
        default: return false
        }
    }

    func request(for pane: String) -> Request? { pending.first { $0.pane == pane } }

    func approve(_ r: Request) {
        pending.removeAll { $0.id == r.id }
        Task {
            // The session may have stopped waiting (interrupted, gone): then
            // there's nobody to send it to, and a command runs for no one.
            guard await Boat.asking(r.machine, r.id) else {
                if !r.pane.isEmpty { notes[r.pane] = "The session stopped waiting for this; nothing was \(r.op == "run" ? "run" : "sent")." }
                return
            }
            await serve(r)
        }
    }

    /// Requests whose session stopped waiting go.
    func prune() {
        let now = Int(Date().timeIntervalSince1970)
        pending.removeAll { $0.until > 0 && now > $0.until }
    }

    func decline(_ r: Request) {
        pending.removeAll { $0.id == r.id }
        Task { await Boat.reply(r.machine, r.id, ok: false, message: "The user didn't send it.") }
    }

    func dismissNote(_ pane: String) { notes[pane] = nil }

    private func serve(_ r: Request) async {
        let from = r.origin == Boat.here ? "this Mac" : r.origin
        if r.op == "run" {
            if !r.pane.isEmpty { notes[r.pane] = "Running it on \(from)…" }
            let (code, output) = await Boat.runAt(r.command, from: r.origin, dir: r.dir, timeout: r.timeout)
            notes[r.pane] = nil
            // (The end of a long output: the agent can ask for a file instead.)
            let tail = output.count > 200_000 ? "…\n" + String(output.suffix(200_000)) : output
            let body: [String: Any] = ["ok": 1, "code": Int(code), "message": "Ran on \(from) (exit \(code)):", "output": tail]
            await Boat.reply(r.machine, r.id, body)
            return
        }
        do {
            if r.op == "ls" {
                let out = try await Boat.list(r.paths.first ?? "~", from: r.origin)
                await Boat.reply(r.machine, r.id, ok: true, message: "\(r.paths.first ?? "~") on \(from):", output: out)
            } else {
                if !r.pane.isEmpty { notes[r.pane] = "Sending \(r.what) from \(from)…" }
                let out = try await Boat.copy(r.machine, r.paths, from: r.origin)
                notes[r.pane] = nil
                await Boat.reply(r.machine, r.id, ok: true, message: "Copied from \(from), each to the same path here:", output: out)
            }
        } catch {
            if !r.pane.isEmpty { notes[r.pane] = "Couldn't send \(r.what): \(error.localizedDescription)" }
            await Boat.reply(r.machine, r.id, ok: false, message: "Reflex couldn't send it: \(error.localizedDescription)")
        }
    }
}

/// Whether a Mac's herdr-core may read your protected folders (Downloads,
/// Desktop, Documents): what another machine fetches from there goes
/// through it. macOS grants that only to a person, in System Settings
/// (Full Disk Access) or its prompt; no ssh or script can. Reflex checks,
/// and opens the right pane with herdr-core shown in Finder to drag in, on
/// this Mac or another one's screen.
@MainActor
final class FileAccess: ObservableObject {
    static let shared = FileAccess()
    /// This Mac: nil until checked.
    @Published private(set) var granted: Bool?
    /// Other Macs, by machine name.
    @Published private(set) var remote: [String: Bool] = [:]
    private var checking = false

    nonisolated private static let probe = "for d in Downloads Desktop Documents; do ls \"$HOME/$d\" >/dev/null 2>&1 || exit 1; done"
    private static let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// Through this Mac's herdr-core (what reads them for other machines).
    func check() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            let env = HerdrCore.environment()
            guard let hc = HerdrCore.binary(env) else { return }
            let r = await Blocking.run { MachineSetup.run(env, hc, ["exec", "--timeout", "8", "--", "sh", "-c", Self.probe], timeout: 15) }
            granted = r.status == 0
        }
    }

    func check(_ machine: String) {
        Task {
            let (code, _) = await Boat.runAt(Self.probe, from: machine, dir: "~", timeout: 8)
            remote[machine] = code == 0
        }
    }

    /// Full Disk Access in System Settings, and herdr-core in Finder to drag
    /// into it; checked again for a minute.
    func allow() {
        if let url = URL(string: Self.pane) { NSWorkspace.shared.open(url) }
        if let bin = HerdrCore.binary() {
            let real = URL(fileURLWithPath: bin).resolvingSymlinksInPath()
            NSWorkspace.shared.activateFileViewerSelecting([real])
        }
        recheck { self.check() }
    }

    /// The same on another Mac's screen (someone there, or Parsec, clicks).
    func allow(on machine: String) {
        Task {
            _ = await Boat.runAt("open '\(Self.pane)'; b=$(command -v herdr-core || echo \"$HOME/.local/bin/herdr-core\"); open -R \"$(readlink -f \"$b\" 2>/dev/null || echo \"$b\")\"",
                                 from: machine, dir: "~", timeout: 15)
        }
        recheck { self.check(machine) }
    }

    private func recheck(_ again: @escaping () -> Void) {
        Task {
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(5))
                again()
            }
        }
    }
}

/// Machine events in the inbox (and on the phone): a session elsewhere asking
/// for something, a move done or stopped, a sandbox boat stopped. One that
/// needs you also slides the rail out, as a question does.
@MainActor
enum MachineNotes {
    static func post(_ pane: String, title: String, body: String = "", needsYou: Bool = false) {
        let a = Store.shared.state.agents.first { $0.pane == pane }
        let machine = Machines.machine(of: pane)
        let agent = a?.label ?? (machine.isEmpty ? "reflex" : machine)
        Task {
            await Client.local.note(pane: pane, agent: agent, title: title, body: body)
            await Store.shared.refresh()
            if needsYou, Settings.shared.surfaceQuestions { AppDelegate.current?.surfaceRail() }
        }
    }
}
