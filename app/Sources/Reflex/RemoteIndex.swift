import Foundation

// Other Macs' folders and earlier sessions, for the Ask bar's search, /resume
// and "@machine" requests. For each machine with a tunnel up (Machines), over
// ssh, with your own config, keys and agent, and nothing installed there:
//
// - folders: scripts/reflex-scan.sh runs there, under the same roots as here
//   relative to its home (~/VCS here is ~/VCS there). Written, as
//   "<machine>:<path>", to machines/<machine>.folders, which reflexd merges
//   into its index. Every 15 minutes, and when a machine comes up.
// - sessions: scripts/reflex-remote.sh lists the session files there; the
//   ones not yet read at that mtime come back as their start and end, read
//   with SessionArchive's own code. Every minute; a session open in a
//   terminal there forks (never two writers), and `claude --bg` sessions stay
//   on their own Mac.
final class RemoteIndex: @unchecked Sendable {
    static let shared = RemoteIndex()

    // Everything below runs on `q`.
    private let q = DispatchQueue(label: "reflex.remote-index", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Per machine: each session file read, at its mtime ("" for one that
    /// isn't a session worth offering).
    private var read: [String: [String: (mtime: String, session: PastSession?)]] = [:]
    private var sessionsAt: [String: Date] = [:]
    private var foldersAt: [String: Date] = [:]
    private var busy = Set<String>()
    private var known = Set<String>()

    @MainActor func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 8, repeating: 20)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// A machine's folders and sessions, again now (Settings, a reconnect).
    func refresh() {
        q.async {
            self.sessionsAt = [:]
            self.foldersAt = [:]
            self.tick()
        }
    }

    private func tick() {
        let (machines, env) = Machines.shared.reachable()
        let keys = Set(machines.map(\.key))
        // A machine that went away: its sessions can't be brought back from here.
        for gone in known.subtracting(keys) {
            read[gone] = nil
            sessionsAt[gone] = nil
            foldersAt[gone] = nil
            DispatchQueue.main.async { SessionArchive.shared.setRemote(gone, []) }
        }
        known = keys
        let now = Date()
        for m in machines where !busy.contains(m.key) {
            let sessions = now.timeIntervalSince(sessionsAt[m.key] ?? .distantPast) >= 60
            let folders = now.timeIntervalSince(foldersAt[m.key] ?? .distantPast) >= 900
            guard sessions || folders else { continue }
            busy.insert(m.key)
            if sessions { sessionsAt[m.key] = now }
            if folders { foldersAt[m.key] = now }
            let cached = read[m.key] ?? [:]
            DispatchQueue.global(qos: .utility).async {
                let s = sessions ? Self.sessions(m, env: env, cached: cached) : nil
                if folders { Self.folders(m, env: env) }
                self.q.async {
                    self.busy.remove(m.key)
                    guard let s, self.known.contains(m.key) else { return }
                    self.read[m.key] = s.read
                    let found = s.found
                    DispatchQueue.main.async { SessionArchive.shared.setRemote(m.key, found) }
                }
            }
        }
    }

    // MARK: Sessions

    private static func sessions(_ m: Machines.Reach, env: [String: String],
                                 cached: [String: (mtime: String, session: PastSession?)]) -> (read: [String: (mtime: String, session: PastSession?)], found: [PastSession])? {
        guard let script = script("reflex-remote.sh") else { return nil }
        let knownLines = cached.map { "\($0.value.mtime)\t\($0.key)" }.joined(separator: "\n")
        let input = script + (script.hasSuffix("\n") ? "" : "\n") + knownLines + "\n"
        guard let out = ssh(m.target, #"f=$(mktemp -t reflex); cat > "$f"; sh "$f" "$f"; rm -f "$f""#, input: input, env: env, timeout: 90) else { return nil }
        var next: [String: (mtime: String, session: PastSession?)] = [:]
        var open = Set<String>()
        var background = Set<String>()
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "A", f.count >= 2 {
                // Claude's own word on its sessions there.
                let list = (try? JSONSerialization.jsonObject(with: Data(f[1].utf8)) as? [[String: Any]]) ?? []
                for a in list {
                    guard let sid = a["sessionId"] as? String else { continue }
                    if a["kind"] as? String == "background" { background.insert(sid) } else if a["pid"] != nil { open.insert(sid) }
                }
                continue
            }
            guard f.first == "F", f.count >= 6 else { continue }
            let (agent, mtime, path) = (f[1], f[2], f[3])
            if f[4].isEmpty, let c = cached[path], c.mtime == mtime {
                next[path] = c
                continue
            }
            let head = Data(base64Encoded: f[4]) ?? Data()
            let tail = Data(base64Encoded: f[5]) ?? Data()
            let modified = Date(timeIntervalSince1970: TimeInterval(mtime) ?? 0)
            var s = SessionArchive.read(agent: agent, url: URL(fileURLWithPath: path), head: head, tail: tail, modified: modified)
            if let cwd = s?.cwd { s?.cwd = Place.on(m.key, cwd) }
            next[path] = (mtime, s)
        }
        let found = next.values.compactMap(\.session).filter { !background.contains($0.id) }.map { s -> PastSession in
            var s = s
            s.state = open.contains(s.id) ? .elsewhere : .past
            return s
        }
        return (next, found)
    }

    // MARK: Folders

    private static func folders(_ m: Machines.Reach, env: [String: String]) {
        guard let script = script("reflex-scan.sh") else { return }
        // This Mac's roots, as the same places under that Mac's home.
        let home = NSHomeDirectory()
        let roots = (env["REFLEX_ROOTS"] ?? home + "/VCS").split(separator: ":").compactMap { r -> String? in
            let r = String(r)
            guard r == home || r.hasPrefix(home + "/") else { return nil }
            return "$HOME" + r.dropFirst(home.count)
        }
        let list = roots.isEmpty ? "$HOME/VCS" : roots.joined(separator: ":")
        let cmd = #"f=$(mktemp -t reflex-scan); cat > "$f"; chmod +x "$f"; REFLEX_ROOTS="\#(list)" "$f"; rm -f "$f""#
        guard let out = ssh(m.target, cmd, input: script, env: env, timeout: 240) else { return }
        // How often sessions started in each of its folders, from here.
        let usage = (try? String(contentsOf: Settings.supportDir.appendingPathComponent("usage.tsv"), encoding: .utf8)) ?? ""
        var uses: [String: Int] = [:]
        for l in usage.split(separator: "\n") where Place.machine(String(l)) == m.key { uses[String(l), default: 0] += 1 }
        let lines = out.split(separator: "\n").compactMap { l -> String? in
            var f = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, f[0].hasPrefix("/") else { return nil }
            f[0] = Place.on(m.key, f[0])
            if let n = uses[f[0]] { f[4] = String(n) }
            return f.joined(separator: "\t")
        }
        let file = Machines.dir.appendingPathComponent("\(m.key).folders")
        let text = lines.joined(separator: "\n") + "\n"
        guard (try? String(contentsOf: file, encoding: .utf8)) != text else { return }
        try? text.write(to: file, atomically: true, encoding: .utf8)
        Task { await Client.local.reindexMachines() }
    }

    // MARK: ssh

    private static func script(_ name: String) -> String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("scripts/\(name)") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// stdout of `command` run on `target` with `input` on its stdin, if it
    /// succeeded within `timeout` seconds.
    private static func ssh(_ target: String, _ command: String, input: String, env: [String: String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "Compression=yes",
                       "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", target, command]
        p.environment = env
        let stdin = Pipe(), out = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else {
            NSLog("Reflex: machine %@: remote index failed (%d)", target, p.terminationStatus)
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
