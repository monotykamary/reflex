import AppKit
import Foundation

// Earlier agent sessions that could be resumed: Claude's, pi's and Codex's
// saved sessions (read from their own session files), and Claude's
// background sessions (`claude agents --json --all`) — this Mac's, and those
// on the other Macs with a tunnel (RemoteIndex reads theirs over ssh; their
// cwd is "<machine>:<path>", see Place). Sessions already live in herdr are
// left out. Written to sessions.tsv for reflexd, which offers the relevant
// few to Jev, and shown in the Ask bar's search and the rail.
//
// Each file is read only at its start and end, and again only when it
// changes, so even thousands of sessions stay cheap.

struct PastSession: Identifiable, Hashable {
    enum State: String { case past, background, running, elsewhere }
    var agent: String
    var id: String
    var cwd: String
    var title: String
    var last: String
    var modified: Date
    var state: State

    var folder: String { (Place.path(cwd) as NSString).lastPathComponent }
    /// The Mac it was saved on, "" for this one.
    var machine: String { Place.machine(cwd) }
    var ageHours: Int { max(0, Int(Date().timeIntervalSince(modified) / 3600)) }

    /// How ⏎ brings it back: attach a running background session, fork one
    /// open in another terminal (never two writers), else resume.
    var mode: String {
        switch state {
        case .running: return "attach"
        case .elsewhere: return "fork"
        default: return "resume"
        }
    }

    var ago: String {
        let s = Date().timeIntervalSince(modified)
        if s < 3600 { return "\(max(1, Int(s / 60))) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }
}

@MainActor
final class SessionArchive: ObservableObject {
    static let shared = SessionArchive()
    @Published private(set) var sessions: [PastSession] = []

    /// Out of the list now (it was deleted); the next scan agrees.
    func forget(_ id: String) { sessions.removeAll { $0.id == id } }
    private var cache: [String: (Date, PastSession?)] = [:]
    private var background: [String: PastSession.State] = [:]
    private var timer: Timer?
    private var scanning = false

    static var file: URL { Settings.supportDir.appendingPathComponent("sessions.tsv") }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// This Mac's sessions, as last scanned, and each other Mac's.
    private var here: [PastSession] = []
    private var remote: [String: [PastSession]] = [:]

    /// A machine's sessions, read again (or [] once it is gone).
    func setRemote(_ machine: String, _ found: [PastSession]) {
        guard remote[machine] != found else { return }
        remote[machine] = found.isEmpty ? nil : found
        publish()
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let cached = cache
        let env = Daemon.shared.childEnvironment()
        Task.detached(priority: .utility) {
            let states = SessionArchive.claudeAgents(env: env)
            var next = cached
            let found = SessionArchive.scan(cache: &next)
            let kept = next
            await MainActor.run {
                self.cache = kept
                self.background = states
                self.here = found
                self.publish()
                self.scanning = false
            }
        }
    }

    /// Merge background states, drop sessions live in herdr, write the file.
    private func publish() {
        let live = Set(Store.shared.state.agents.map(\.session).filter { !$0.isEmpty })
        var out: [PastSession] = []
        for var s in here where !live.contains(s.id) {
            if let st = background[s.id] { s.state = st }
            out.append(s)
        }
        for s in remote.values.joined() where !live.contains(s.id) { out.append(s) }
        out.sort { $0.modified > $1.modified }
        sessions = Array(out.prefix(400))
        let tsv = sessions.map { s in
            [s.agent, s.id, s.cwd, s.title, s.last, String(s.ageHours), s.state.rawValue].map(SessionArchive.clean).joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
        try? tsv.write(to: SessionArchive.file, atomically: true, encoding: .utf8)
    }

    nonisolated static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: Matching (for the Ask bar)

    /// Sessions whose title, last prompt, folder, agent or Mac contain every
    /// word; only one Mac's ("@work") when `machine` is set.
    func matching(_ query: String, on machine: String? = nil, limit: Int = 8) -> [PastSession] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(sessions.lazy.filter { s in
            if let machine, s.machine != machine { return false }
            let hay = "\(s.title) \(s.last) \(s.folder) \(s.agent) \(s.machine)".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }.prefix(limit))
    }

    /// Running or stopped `claude --bg` sessions, for the rail.
    var backgroundSessions: [PastSession] { sessions.filter { $0.state == .running || $0.state == .background } }

    // MARK: Scanning

    nonisolated static func scan(cache: inout [String: (Date, PastSession?)]) -> [PastSession] {
        let home = NSHomeDirectory()
        var files: [(agent: String, url: URL, modified: Date)] = []
        func collect(_ agent: String, _ dir: String, depth: Int) {
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else { return }
            var mine: [(String, URL, Date)] = []
            for case let u as URL in e {
                if e.level > depth { e.skipDescendants(); continue }
                guard u.pathExtension == "jsonl",
                      let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                mine.append((agent, u, m))
            }
            // The most recent of each agent's sessions are the ones worth offering.
            files += mine.sorted { $0.2 > $1.2 }.prefix(150).map { (agent: $0.0, url: $0.1, modified: $0.2) }
        }
        collect("claude", home + "/.claude/projects", depth: 2)
        collect("pi", home + "/.pi/agent/sessions", depth: 2)
        collect("codex", home + "/.codex/sessions", depth: 4)

        var out: [PastSession] = []
        var seen = Set<String>()
        for f in files {
            let key = f.url.path
            seen.insert(key)
            if let (m, s) = cache[key], m == f.modified {
                if let s { out.append(s) }
                continue
            }
            let s = read(agent: f.agent, url: f.url, modified: f.modified)
            cache[key] = (f.modified, s)
            if let s { out.append(s) }
        }
        cache = cache.filter { seen.contains($0.key) }
        return out
    }

    nonisolated static func read(agent: String, url: URL, modified: Date) -> PastSession? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 96 * 1024)) ?? Data()
        let size = (try? h.seekToEnd()) ?? 0
        var tail = Data()
        if size > 96 * 1024 {
            let from = size > 256 * 1024 ? size - 256 * 1024 : 96 * 1024
            try? h.seek(toOffset: from)
            tail = (try? h.readToEnd()) ?? Data()
        }
        return read(agent: agent, url: url, head: head, tail: tail, modified: modified)
    }

    /// A session file's start and end (`tail` empty when the start is all
    /// of it): read the same here and from another Mac.
    nonisolated static func read(agent: String, url: URL, head: Data, tail: Data, modified: Date) -> PastSession? {
        let headLines = lines(head, dropFirst: false)
        let tailLines = tail.isEmpty ? headLines : lines(tail, dropFirst: true)
        switch agent {
        case "claude": return claude(url: url, head: headLines, tail: tailLines, modified: modified)
        case "pi": return pi(head: headLines, tail: tailLines, modified: modified)
        default: return codex(head: headLines, tail: tailLines, modified: modified)
        }
    }

    nonisolated static func lines(_ d: Data, dropFirst: Bool) -> [[String: Any]] {
        var parts = d.split(separator: UInt8(ascii: "\n"))
        if dropFirst, !parts.isEmpty { parts.removeFirst() }
        return parts.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    nonisolated static func text(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { ($0["type"] as? String).map { ["text", "input_text"].contains($0) } == true ? $0["text"] as? String : nil }
                .joined(separator: " ")
        }
        return nil
    }

    /// A real prompt, not tool output, a compaction summary or injected context.
    nonisolated static func prompt(_ s: String?) -> String? {
        guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        // A quoted message ("> Hi …") reads better without its quote marker.
        while t.hasPrefix(">") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("<") || t.hasPrefix("This session is being continued") || t.hasPrefix("Caveat:") { return nil }
        return String(t.prefix(300))
    }

    nonisolated static func claude(url: URL, head: [[String: Any]], tail: [[String: Any]], modified: Date) -> PastSession? {
        let id = url.deletingPathExtension().lastPathComponent
        guard let cwd = head.lazy.compactMap({ $0["cwd"] as? String }).first else { return nil }
        if head.contains(where: { ($0["isSidechain"] as? Bool) == true && ($0["type"] as? String) == "user" }) { return nil }
        let all = head + tail
        let title = all.last { ($0["type"] as? String) == "custom-title" }.flatMap { $0["customTitle"] as? String }
            ?? all.last { ($0["type"] as? String) == "ai-title" }.flatMap { $0["aiTitle"] as? String }
        let last = tail.last { ($0["type"] as? String) == "last-prompt" }.flatMap { $0["lastPrompt"] as? String }
            ?? tail.reversed().lazy.filter { ($0["type"] as? String) == "user" }
                .compactMap { prompt(text(($0["message"] as? [String: Any])?["content"])) }.first
        let first = head.lazy.filter { ($0["type"] as? String) == "user" }
            .compactMap { prompt(text(($0["message"] as? [String: Any])?["content"])) }.first
        guard let name = title ?? first ?? last else { return nil }
        return PastSession(agent: "claude", id: id, cwd: cwd, title: String(name.prefix(120)), last: last ?? "", modified: modified, state: .past)
    }

    nonisolated static func pi(head: [[String: Any]], tail: [[String: Any]], modified: Date) -> PastSession? {
        guard let meta = head.first(where: { ($0["type"] as? String) == "session" }),
              let id = meta["id"] as? String, let cwd = meta["cwd"] as? String else { return nil }
        func userText(_ l: [String: Any]) -> String? {
            guard (l["type"] as? String) == "message", let m = l["message"] as? [String: Any], (m["role"] as? String) == "user" else { return nil }
            return prompt(text(m["content"]))
        }
        let name = head.first { ($0["type"] as? String) == "session_info" }.flatMap { $0["name"] as? String }
        guard let first = head.lazy.compactMap(userText).first else { return nil }
        let last = tail.reversed().lazy.compactMap(userText).first ?? first
        return PastSession(agent: "pi", id: id, cwd: cwd, title: String((name ?? first).prefix(120)), last: last, modified: modified, state: .past)
    }

    nonisolated static func codex(head: [[String: Any]], tail: [[String: Any]], modified: Date) -> PastSession? {
        guard let meta = head.first(where: { ($0["type"] as? String) == "session_meta" })?["payload"] as? [String: Any],
              let id = meta["id"] as? String, let cwd = meta["cwd"] as? String else { return nil }
        func userText(_ l: [String: Any]) -> String? {
            guard let p = l["payload"] as? [String: Any], (p["role"] as? String) == "user" else { return nil }
            return prompt(text(p["content"]))
        }
        guard let first = head.lazy.compactMap(userText).first else { return nil }
        let last = tail.reversed().lazy.compactMap(userText).first ?? first
        return PastSession(agent: "codex", id: id, cwd: cwd, title: String(first.prefix(120)), last: last, modified: modified, state: .past)
    }

    /// Claude's own list: background sessions (running or stopped) and
    /// interactive ones open in other terminals.
    nonisolated static func claudeAgents(env: [String: String]) -> [String: PastSession.State] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "agents", "--json", "--all"]
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var states: [String: PastSession.State] = [:]
        for a in list {
            guard let sid = a["sessionId"] as? String else { continue }
            let kind = a["kind"] as? String
            let state = (a["state"] as? String) ?? (a["status"] as? String) ?? ""
            if kind == "background" {
                states[sid] = ["stopped", "completed", "done", "failed"].contains(state) ? .background : .running
            } else if a["pid"] != nil {
                states[sid] = .elsewhere
            }
        }
        return states
    }
}
