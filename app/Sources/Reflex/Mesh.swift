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

    /// One listener per machine that's up (and this Mac).
    private func refresh() {
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
    }

    private func listen(_ m: String) async {
        while !Task.isCancelled {
            guard let out = try? await Boat.reflex(["bus", "listen", m, "60"], timeout: 120) else {
                try? await Task.sleep(for: .seconds(15))
                continue
            }
            for line in out.split(separator: "\n") {
                guard let r = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else { continue }
                await handle(m, r)
            }
        }
    }

    private func handle(_ m: String, _ r: Request) async {
        let local = r.pane ?? ""
        let pane = local.isEmpty ? "" : m == Boat.here ? local : "\(m)/\(local)"
        let origin = (r.origin ?? "").isEmpty ? Boat.here : r.origin!
        switch r.op {
        case "move":
            let to = r.to ?? ""
            if MoveRequests.shared.add(pane: pane, id: r.id, to: to, paths: r.paths ?? []) {
                await Boat.reply(m, r.id, ok: true, message: "Reflex has it: the user approves the move, and it happens once this turn ends. End your turn now.")
            } else {
                await Boat.reply(m, r.id, ok: false, message: "No machine called \(to) here (reflex home machines lists them; \"here\" is the Mac Reflex runs on).")
            }
        case "fetch", "ls":
            FileRequests.shared.add(.init(id: r.id, machine: m, pane: pane, op: r.op, paths: r.paths ?? [], origin: origin))
        case "machines":
            let up = CoreMachines.known.filter { $0.state == "connected" }.map(\.name)
            let list = (["here (\(Host.current().localizedName ?? "this Mac"), where Reflex runs)"] + up.map { $0 + (Boat.made($0) ? " (boat sandbox)" : "") })
            await Boat.reply(m, r.id, ok: true, message: "Machines Reflex reaches:", output: list.joined(separator: "\n"))
        default:
            await Boat.reply(m, r.id, ok: false, message: "Reflex doesn't know \(r.op)")
        }
    }
}

/// A session elsewhere asking this Mac for files (`reflex home fetch`) or
/// what's in a folder (`reflex home ls`): yours to allow, unless Settings
/// allows it. The files go to the same ~ path there.
@MainActor
final class FileRequests: ObservableObject {
    static let shared = FileRequests()

    struct Request: Identifiable, Equatable {
        let id: String
        /// The machine that asked ("." for this Mac).
        let machine: String
        let pane: String
        let op: String
        let paths: [String]
        /// Where the files are, as this Reflex names it.
        let origin: String

        var what: String {
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
            if !r.pane.isEmpty { AppDelegate.current?.showPane(r.pane) }
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func allowed(_ r: Request) -> Bool {
        switch Settings.shared.fileApproval {
        case "always": return true
        case "made": return Boat.made(r.machine)
        default: return false
        }
    }

    func request(for pane: String) -> Request? { pending.first { $0.pane == pane } }

    func approve(_ r: Request) {
        pending.removeAll { $0.id == r.id }
        Task { await serve(r) }
    }

    func decline(_ r: Request) {
        pending.removeAll { $0.id == r.id }
        Task { await Boat.reply(r.machine, r.id, ok: false, message: "The user didn't send it.") }
    }

    func dismissNote(_ pane: String) { notes[pane] = nil }

    private func serve(_ r: Request) async {
        let from = r.origin == Boat.here ? "this Mac" : r.origin
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
