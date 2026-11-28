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

struct PastSession: Identifiable, Hashable, Codable {
    enum State: String, Codable { case past, background, running, elsewhere }
    var agent: String
    var id: String
    var cwd: String
    var title: String
    var last: String
    var modified: Date
    var state: State
    /// The harness profile it was saved in (`reflex profile`: claude[tom]), nil for your own.
    var profile: String? = nil

    /// How Reflex names its harness: "claude", or "claude[tom]" in a profile.
    var spec: String { Profiles.spec(agent, profile) }

    /// The profile a session file belongs to, from its path (…/.reflex/profiles/<harness>/<name>/…).
    static func profile(of path: String) -> String? {
        guard let r = path.range(of: "/.reflex/profiles/") else { return nil }
        let parts = path[r.upperBound...].split(separator: "/")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

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
    private var indexedSessionFolders: Set<String> = []

    static var file: URL { Settings.supportDir.appendingPathComponent("sessions.tsv") }
    /// Other machines' sessions as last read from each, so a machine that is
    /// paused, asleep or out of reach (or was when Reflex started) still lists
    /// its earlier sessions; resuming one wakes it first.
    static var remoteFile: URL { Settings.supportDir.appendingPathComponent("remote-sessions.json") }

    func start() {
        if let data = try? Data(contentsOf: Self.remoteFile),
           let saved = try? JSONDecoder().decode([String: [PastSession]].self, from: data) {
            remote = saved
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// This Mac's sessions, as last scanned, and each other Mac's.
    private var here: [PastSession] = []
    private var remote: [String: [PastSession]] = [:]

    /// A machine's sessions, read again.
    func setRemote(_ machine: String, _ found: [PastSession]) {
        guard remote[machine] != found else { return }
        remote[machine] = found.isEmpty ? nil : found
        saveRemote()
        publish()
    }

    /// Only these machines' sessions: any other was forgotten (removed from
    /// herdr or herdr-core), and its sessions go with it.
    func keepRemote(_ machines: Set<String>) {
        let gone = remote.keys.filter { !machines.contains($0) }
        guard !gone.isEmpty else { return }
        for m in gone { remote[m] = nil }
        saveRemote()
        publish()
    }

    private func saveRemote() {
        guard let data = try? JSONEncoder().encode(remote) else { return }
        try? data.write(to: Self.remoteFile, options: .atomic)
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let cached = cache
        let env = Daemon.shared.childEnvironment()
        Task {
            let (states, found, kept) = await Blocking.run {
                let states = SessionArchive.claudeAgents(env: env)
                var next = cached
                let found = SessionArchive.scan(cache: &next)
                return (states, found, next)
            }
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
            [s.agent, s.id, s.cwd, s.title, s.last, String(s.ageHours), s.state.rawValue, s.profile ?? ""].map(SessionArchive.clean).joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
        do {
            try tsv.write(to: SessionArchive.file, atomically: true, encoding: .utf8)
            let folders = Set(sessions.lazy.filter { $0.machine.isEmpty && $0.cwd.hasPrefix("/") }.map(\.cwd))
            if folders != indexedSessionFolders {
                indexedSessionFolders = folders
                Task { await Client.local.reindex() }
            }
        } catch { }
    }

    nonisolated static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: Matching (for the Ask bar)

    /// Sessions whose title, last prompt, folder, agent or Mac contain every
    /// word; only one Mac's ("@work") when `machine` is set.
    func matching(_ query: String, on machine: String? = nil, harness: String? = nil, limit: Int = 8) -> [PastSession] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(sessions.lazy.filter { s in
            if let machine, s.machine != machine { return false }
            if let harness, !Profiles.matches(harness, kind: s.agent, profile: s.profile) { return false }
            let hay = "\(s.title) \(s.last) \(s.folder) \(s.spec) \(s.machine)".lowercased()
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
        // Each profile's (reflex profile), read the same way.
        let profiles = home + "/.reflex/profiles"
        for (agent, sub, depth) in [("claude", "claude/projects", 2), ("pi", "pi/sessions", 2), ("codex", "codex/sessions", 4)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: "\(profiles)/\(agent)")) ?? []
            for n in names where !n.hasPrefix(".") {
                let dir = "\(profiles)/\(agent)/\(n)/\(sub)"
                // (A profile that adopted your own sessions links to them: read above.)
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: dir)) != nil { continue }
                collect(agent, dir, depth: depth)
            }
        }

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
        // agy's, opencode's and amp's, which keep theirs in a database or one file per thread.
        // Each harness scans only its own profile homes (another harness's profile home symlinks
        // unrelated config folders back to the real home).
        for h in [home] + profileHomes(profiles, for: "agy") {
            out += agy(h + "/.gemini/antigravity-cli/conversation_summaries.db", fallbackCwd: home)
        }
        for h in [home] + profileHomes(profiles, for: "opencode") {
            out += opencode(h + "/.local/share/opencode/opencode.db")
        }
        for h in [home] + profileHomes(profiles, for: "amp") {
            out += amp(h + "/.local/share/amp/threads", cache: &cache, seen: &seen)
        }
        cache = cache.filter { seen.contains($0.key) }
        return out
    }

    /// The homes of profiles for one harness (`reflex profile`: agy, opencode, amp).
    nonisolated static func profileHomes(_ root: String, for harness: String) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: "\(root)/\(harness)")) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { "\(root)/\(harness)/\($0)/home" }
    }

    /// Rows from a SQLite database, opened read-only (reading its WAL without
    /// writing or checkpointing; falling back to immutable when the folder is
    /// read-only). Fields split by U+001F. Empty when there is no database or
    /// no sqlite3.
    nonisolated static func rows(_ db: String, _ sql: String) -> [[String]] {
        guard FileManager.default.fileExists(atPath: db) else { return [] }
        if let r = query(db, sql) { return r }
        let uri = "file:" + (db.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db) + "?immutable=1"
        return query(uri, sql) ?? []
    }

    nonisolated private static func query(_ target: String, _ sql: String) -> [[String]]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-cmd", ".timeout 500", "-separator", "\u{1F}", "-newline", "\u{1E}", target, sql]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: d, as: UTF8.self).split(separator: "\u{1E}", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
    }

    /// agy's conversations (not the ones its agents started).
    /// agy sometimes clears `workspace_uris` on longer sessions; fall back to
    /// `history.jsonl`, the conversation DB's `executor_metadata`, and finally
    /// the real home directory so sessions aren't silently dropped.
    nonisolated static func agy(_ db: String, fallbackCwd: String = NSHomeDirectory()) -> [PastSession] {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime, .withFractionalSeconds, .withTimeZone]
        let isoWhole = ISO8601DateFormatter()
        isoWhole.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime, .withTimeZone]
        let profile = PastSession.profile(of: db)
        let agyDir = (db as NSString).deletingLastPathComponent
        var history: [String: String]? = nil
        func historyCwd(_ id: String) -> String? {
            if history == nil { history = agyHistory(agyDir + "/history.jsonl") }
            return history?[id]
        }
        return rows(db, "select conversation_id, title, preview, workspace_uris, last_modified_time from conversation_summaries where parent_conversation_id = '' and killed = 0 and (title != '' or preview != '') and last_modified_time > '0001-01-02' order by last_modified_time desc limit 150").compactMap { r in
            guard r.count == 5, !r[0].isEmpty else { return nil }
            let id = r[0]
            let title = clean(r[1].isEmpty ? r[2] : r[1])
            guard !title.isEmpty else { return nil }
            let uris = (try? JSONSerialization.jsonObject(with: Data(r[3].utf8)) as? [String]) ?? []
            var cwd = uris.first.flatMap { URL(string: $0)?.path } ?? ""
            if cwd.isEmpty { cwd = historyCwd(id) ?? "" }
            if cwd.isEmpty { cwd = agyConversationWorkspace(agyDir + "/conversations/\(id).db") ?? "" }
            if cwd.isEmpty { cwd = fallbackCwd }
            guard !cwd.isEmpty else { return nil }
            let modified = isoFrac.date(from: r[4]) ?? isoWhole.date(from: r[4]) ?? .distantPast
            return PastSession(agent: "agy", id: id, cwd: cwd, title: String(title.prefix(120)), last: String(clean(r[2]).prefix(300)),
                               modified: modified, state: .past, profile: profile)
        }
    }

    /// Map conversationId -> latest workspace path from agy's history.jsonl.
    nonisolated static func agyHistory(_ path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        var out: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = j["conversationId"] as? String, !id.isEmpty,
                  let ws = j["workspace"] as? String, ws.hasPrefix("/") else { continue }
            out[id] = ws
        }
        return out
    }

    /// Recover a workspace path from a conversation DB's `executor_metadata`
    /// protobuf when `conversation_summaries.workspace_uris` was cleared.
    nonisolated static func agyConversationWorkspace(_ convDb: String) -> String? {
        guard FileManager.default.fileExists(atPath: convDb) else { return nil }
        let rs = rows(convDb, "select hex(data) from executor_metadata where instr(data, X'66696c653a2f2f2f') > 0 order by idx asc limit 3")
        for r in rs {
            guard let hex = r.first, !hex.isEmpty else { continue }
            if let path = agyProtobufURI(hexData(hex)) { return path }
        }
        return nil
    }

    /// First workspace `file:///` URI stored as a length-delimited protobuf
    /// string in `data`, skipping agy's own config/skill folders.
    nonisolated static func agyProtobufURI(_ data: Data) -> String? {
        let needle = Data("file:///".utf8)
        var at = data.startIndex
        while let r = data.range(of: needle, in: at..<data.endIndex) {
            at = r.upperBound
            var lens: [Int] = []
            if r.lowerBound >= 2, data[r.lowerBound - 2] >= 0x80, data[r.lowerBound - 1] < 0x80 {
                lens.append(Int(data[r.lowerBound - 2] & 0x7f) | (Int(data[r.lowerBound - 1]) << 7))
            }
            if r.lowerBound >= 1, data[r.lowerBound - 1] < 0x80 {
                lens.append(Int(data[r.lowerBound - 1]))
            }
            for len in lens {
                guard len > needle.count, r.lowerBound + len <= data.endIndex,
                      let uri = String(data: data[r.lowerBound..<(r.lowerBound + len)], encoding: .utf8),
                      let path = URL(string: uri)?.path,
                      path.hasPrefix("/"),
                      !path.contains("/.gemini/"), !path.contains("/.agents/"), !path.contains("/.reflex/") else { continue }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return path }
            }
        }
        return nil
    }

    nonisolated private static func hexData(_ hex: String) -> Data {
        let bytes = Array(hex.utf8)
        guard bytes.count >= 2 else { return Data() }
        func nib(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        var out = Data()
        out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            if let hi = nib(bytes[i]), let lo = nib(bytes[i + 1]) { out.append((hi << 4) | lo) }
            i += 2
        }
        return out
    }

    /// opencode's sessions (not its subagents').
    nonisolated static func opencode(_ db: String) -> [PastSession] {
        let profile = PastSession.profile(of: db)
        return rows(db, "select id, directory, title, time_updated from session where parent_id is null and time_archived is null and directory != '/' and title not like 'New session - %' order by time_updated desc limit 150").compactMap { r in
            guard r.count == 4, !r[0].isEmpty, !r[1].isEmpty else { return nil }
            let modified = Date(timeIntervalSince1970: (Double(r[3]) ?? 0) / 1000)
            return PastSession(agent: "opencode", id: r[0], cwd: r[1], title: String(clean(r[2]).prefix(120)), last: "",
                               modified: modified, state: .past, profile: profile)
        }
    }

    /// amp's threads, one JSON file each: read again only when one changes.
    nonisolated static func amp(_ dir: String, cache: inout [String: (Date, PastSession?)], seen: inout Set<String>) -> [PastSession] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let files = names.filter { $0.hasSuffix(".json") }.compactMap { n -> (String, Date)? in
            let path = dir + "/" + n
            guard let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
            return (path, m)
        }.sorted { $0.1 > $1.1 }.prefix(150)
        var out: [PastSession] = []
        for (path, m) in files {
            seen.insert(path)
            if let (cm, s) = cache[path], cm == m { if let s { out.append(s) }; continue }
            let s = ampThread(path, modified: m)
            cache[path] = (m, s)
            if let s { out.append(s) }
        }
        return out
    }

    nonisolated static func ampThread(_ path: String, modified: Date) -> PastSession? {
        guard let d = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = j["id"] as? String else { return nil }
        let trees = ((j["env"] as? [String: Any])?["initial"] as? [String: Any])?["trees"] as? [[String: Any]]
        guard let uri = trees?.first?["uri"] as? String, let cwd = URL(string: uri)?.path, !cwd.isEmpty else { return nil }
        let msgs = (j["messages"] as? [[String: Any]]) ?? []
        let prompts = msgs.filter { $0["role"] as? String == "user" }.compactMap { prompt(text($0["content"])) }
        let title = (j["title"] as? String).map(clean) ?? prompts.first ?? ""
        guard !title.isEmpty || !prompts.isEmpty else { return nil }
        return PastSession(agent: "amp", id: id, cwd: cwd, title: String(title.prefix(120)), last: prompts.last ?? "",
                           modified: modified, state: .past, profile: PastSession.profile(of: path))
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
        var s: PastSession?
        switch agent {
        case "claude": s = claude(url: url, head: headLines, tail: tailLines, modified: modified)
        case "pi": s = pi(head: headLines, tail: tailLines, modified: modified)
        default: s = codex(head: headLines, tail: tailLines, modified: modified)
        }
        s?.profile = PastSession.profile(of: url.path)
        return s
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
