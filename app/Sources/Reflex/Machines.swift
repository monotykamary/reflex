import Foundation

// Other Macs' herdr — herdr's saved machines (`herdr machine add <host>`) —
// seen from here. For each enabled machine Reflex keeps one SSH tunnel that
// forwards its herdr's two sockets into <support>/machines: `<key>.sock` (the
// API, which reflexd polls) and `<key>-client.sock` (terminals: herdr derives
// it from HERDR_SOCKET_PATH). `list` there names the machines with a tunnel,
// and an agent on one has the pane "<key>/<pane>" (see daemon/Herdr.bend).
// SSH is yours: your ~/.ssh/config, keys and agent; nothing is stored here.

/// What the UI shows of each herdr machine: Settings → Machines lists them,
/// agents on one wear its name, and dim while its tunnel is down.
@MainActor
final class MachinesModel: ObservableObject {
    static let shared = MachinesModel()

    enum Link: Equatable {
        case connected, connecting, off
        case down(String)
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let key: String
        let label: String
        let target: String
        let session: String
        let link: Link
    }

    @Published var rows: [Row] = []
    /// `herdr machine list` answered at least once.
    @Published var loaded = false

    func row(_ key: String) -> Row? { rows.first { $0.key == key } }

    /// Its agents' screens are the last ones seen: the tunnel is down.
    func away(_ key: String) -> Bool {
        guard let r = row(key) else { return false }
        return r.link != .connected
    }
}

final class Machines: @unchecked Sendable {
    static let shared = Machines()
    static var dir: URL { Settings.supportDir.appendingPathComponent("machines") }

    /// A pane on another machine: its socket here, and its id in that herdr.
    static func route(_ pane: String) -> (sock: String, pane: String)? {
        let parts = pane.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (dir.appendingPathComponent("\(parts[0]).sock").path, String(parts[1]))
    }

    /// The machine a pane is on, "" for this Mac.
    static func machine(of pane: String) -> String {
        let parts = pane.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[0]) : ""
    }

    private struct Profile: Decodable, Equatable {
        let id: String
        let label: String
        let target: String
        let session: String
        let enabled: Bool
    }

    private final class Tunnel {
        let key: String
        let profile: Profile
        var process: Process?
        var started = Date.distantPast
        var failures = 0
        var nextTry = Date.distantPast
        /// The machine's herdr sockets (API, client), once asked.
        var remote: (String, String)?
        /// Last seen up: its agents stay listed for a while after a drop.
        var lastUp = Date.distantPast
        var problem = ""
        init(key: String, profile: Profile) { self.key = key; self.profile = profile }
        var running: Bool { process?.isRunning == true }
    }

    // Everything below runs on `q`.
    private let q = DispatchQueue(label: "reflex.machines")
    private var tunnels: [String: Tunnel] = [:]
    private var timer: DispatchSourceTimer?
    private var env: [String: String] = [:]
    private var listed = ""
    private var all: [Profile] = []
    /// How long a machine whose tunnel dropped stays in `list`: reflexd keeps
    /// its agents meanwhile, so a blip (sleep, Wi-Fi) isn't agents vanishing
    /// and coming back as new.
    private static let grace: TimeInterval = 180

    @MainActor func start() {
        var env = Daemon.shared.childEnvironment()
        env["HERDR_SESSION"] = nil
        q.async {
            self.env = env
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            Self.endOrphans()
            self.tick()
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Try a machine again now (Settings → Machines).
    func reconnect(_ key: String) {
        q.async {
            guard let t = self.tunnels[key] else { return }
            t.remote = nil
            t.failures = 0
            t.nextTry = .distantPast
            if t.running { self.close(t) }
            self.open(t)
            self.publish()
        }
    }

    /// Ask herdr for its machines now.
    func refresh() { q.async { self.tick() } }

    /// A machine with its tunnel up: its key (in pane ids and places) and
    /// how ssh reaches it.
    struct Reach: Hashable {
        let key: String
        let target: String
    }

    /// The machines whose tunnel is up now, and the environment ssh runs in
    /// (your agent, your config): RemoteIndex reads their folders and
    /// sessions the same way.
    func reachable() -> (machines: [Reach], env: [String: String]) {
        q.sync {
            let up = tunnels.values.filter { $0.running && Date().timeIntervalSince($0.started) > 3 }
            return (up.map { Reach(key: $0.key, target: $0.profile.target) }.sorted { $0.key < $1.key }, env)
        }
    }

    /// The tunnels' ssh processes, readable off `q`: quitting must not wait
    /// behind a slow probe of a machine that's away.
    private let lock = NSLock()
    private var pids: [String: pid_t] = [:]

    private func track(_ key: String, _ pid: pid_t?) {
        lock.lock()
        pids[key] = pid
        lock.unlock()
    }

    /// Close every tunnel (Reflex is quitting).
    func stop() {
        lock.lock()
        let running = Array(pids.values)
        pids = [:]
        lock.unlock()
        for pid in running { kill(pid, SIGTERM) }
        try? "".write(to: Self.dir.appendingPathComponent("list"), atomically: true, encoding: .utf8)
        // No socket file outlives its tunnel: one left would look connected.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: Self.dir.path)) ?? [] where name.hasSuffix(".sock") {
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(name))
        }
    }

    /// herdr's machines, again: a new one gets a tunnel, a removed or disabled
    /// one loses its own, a tunnel that dropped comes back (sooner after a
    /// blip, every two minutes at most while the machine is away).
    private func tick() {
        guard let profiles = profiles() else { return }
        all = profiles
        var want: [String: Profile] = [:]
        for p in profiles where p.enabled { want[Self.key(p, taken: want)] = p }
        for (key, t) in tunnels where want[key] != t.profile {
            close(t)
            tunnels[key] = nil
        }
        for (key, p) in want where tunnels[key] == nil { tunnels[key] = Tunnel(key: key, profile: p) }
        for t in tunnels.values {
            if t.running {
                t.lastUp = Date()
                if Date().timeIntervalSince(t.started) > 60 { t.failures = 0; t.problem = "" }
            } else if Date() >= t.nextTry {
                open(t)
            }
        }
        writeList()
        publish()
    }

    private func publish() {
        let rows = all.map { p -> MachinesModel.Row in
            let t = tunnels.values.first { $0.profile.id == p.id }
            let link: MachinesModel.Link
            if !p.enabled || t == nil {
                link = .off
            } else if t!.running {
                // A fresh tunnel may still be failing to forward: give it a moment.
                link = Date().timeIntervalSince(t!.started) > 3 ? .connected : .connecting
            } else {
                link = t!.problem.isEmpty ? .connecting : .down(t!.problem)
            }
            return .init(id: p.id, key: t?.key ?? Self.key(p, taken: [:]), label: p.label, target: p.target,
                         session: p.session, link: link)
        }
        DispatchQueue.main.async {
            let m = MachinesModel.shared
            if m.rows != rows { m.rows = rows }
            if !m.loaded { m.loaded = true }
        }
    }

    private func profiles() -> [Profile]? {
        guard let out = run("/bin/sh", ["-c", "herdr machine list --json"], timeout: 10) else { return nil }
        return try? JSONDecoder().decode([Profile].self, from: Data(out.utf8))
    }

    /// Lowercase letters, digits, '.', '_' and '-' (it names files and sits
    /// in pane ids), short enough for a socket path.
    private static func key(_ p: Profile, taken: [String: Profile]) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        var k = String(p.label.lowercased().map { allowed.contains($0) ? $0 : "-" }.prefix(20))
        k = k.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if k.isEmpty { k = String(p.id.prefix(8)) }
        if taken[k] != nil { k += "-" + p.id.prefix(4) }
        return k
    }

    private func open(_ t: Tunnel) {
        let api = Self.dir.appendingPathComponent("\(t.key).sock").path
        let client = Self.dir.appendingPathComponent("\(t.key)-client.sock").path
        guard client.utf8.count < 104 else {
            NSLog("Reflex: machine %@: socket path too long (%@)", t.key, client)
            t.problem = "Its name is too long for a socket path; rename it in herdr."
            backOff(t)
            return
        }
        if t.remote == nil { t.remote = remoteSockets(t.profile) }
        guard let (rApi, rClient) = t.remote else {
            NSLog("Reflex: machine %@: couldn't reach its herdr over ssh (%@)", t.key, t.profile.target)
            t.problem = "Can't reach herdr on it over ssh (asleep, offline, or herdr isn't running)."
            backOff(t)
            return
        }
        // A socket file left from before (a crash) would pass for this tunnel.
        try? FileManager.default.removeItem(atPath: api)
        try? FileManager.default.removeItem(atPath: client)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                       "-o", "StreamLocalBindUnlink=yes", "-o", "StreamLocalBindMask=0177",
                       "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                       "-o", "ConnectTimeout=15", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                       "-L", "\(api):\(rApi)", "-L", "\(client):\(rClient)", t.profile.target]
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self, weak t] proc in
            self?.q.async {
                guard let self, let t, t.process === proc else { return }
                NSLog("Reflex: machine %@: tunnel closed (%d)", t.key, proc.terminationStatus)
                t.process = nil
                self.track(t.key, nil)
                t.lastUp = Date()
                // Its herdr may have moved (a restart, another session).
                t.remote = nil
                t.problem = "The connection dropped; reconnecting."
                self.backOff(t)
                self.writeList()
                self.publish()
            }
        }
        do {
            try p.run()
            t.process = p
            track(t.key, p.processIdentifier)
            t.started = Date()
            NSLog("Reflex: machine %@: tunnel to %@", t.key, t.profile.target)
        } catch {
            NSLog("Reflex: machine %@: ssh didn't start: %@", t.key, error.localizedDescription)
            t.problem = "ssh didn't start: \(error.localizedDescription)"
            backOff(t)
        }
    }

    private func backOff(_ t: Tunnel) {
        t.failures += 1
        t.nextTry = Date().addingTimeInterval(min(120, 5 * pow(2, Double(t.failures - 1))))
    }

    private func close(_ t: Tunnel) {
        guard let p = t.process else { return }
        t.process = nil
        track(t.key, nil)
        p.terminate()
        for name in ["\(t.key).sock", "\(t.key)-client.sock"] {
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(name))
        }
    }

    /// Where the machine's herdr listens, from its own `herdr status server`
    /// (it knows its session and config folder); the client socket sits next
    /// to the API's, as herdr names it.
    private func remoteSockets(_ p: Profile) -> (String, String)? {
        let session = p.session.isEmpty || p.session == "default" ? "" : " --session '\(p.session.replacingOccurrences(of: "'", with: ""))'"
        let cmd = "PATH=\"$HOME/.local/bin:$PATH\"; herdr\(session) status server --json"
        guard let out = run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", p.target, cmd], timeout: 30),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let sock = json["socket"] as? String, sock.hasSuffix(".sock")
        else { return nil }
        return (sock, String(sock.dropLast(5)) + "-client.sock")
    }

    private func writeList() {
        let keys = tunnels.values.filter { $0.running || Date().timeIntervalSince($0.lastUp) < Self.grace }
            .map(\.key).sorted().joined(separator: "\n")
        guard keys != listed else { return }
        listed = keys
        try? (keys.isEmpty ? "" : keys + "\n").write(to: Self.dir.appendingPathComponent("list"), atomically: true, encoding: .utf8)
    }

    /// Tunnels a Reflex left behind (killed, crashed): their parent is launchd.
    private static func endOrphans() {
        guard let out = Machines.shared.run("/bin/ps", ["-axo", "pid=,ppid=,command="], timeout: 5) else { return }
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, f[1] == "1", let pid = Int32(f[0]),
                  f[2].hasPrefix("/usr/bin/ssh -N "), f[2].contains(" -L \(dir.path)/") else { continue }
            NSLog("Reflex: ending a tunnel left behind (%d)", pid)
            kill(pid, SIGTERM)
        }
    }

    /// stdout of a command that succeeded within `timeout` seconds.
    private func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
