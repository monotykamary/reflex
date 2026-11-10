import Foundation

// A finished session's last reply, read from the agent's own session file
// instead of its screen: the inbox shows what it said, as prose, without the
// terminal around it. Claude (~/.claude/projects/*/<id>.jsonl) and pi
// (~/.pi/agent/sessions/*/<time>_<id>.jsonl); other agents keep the screen.
//
// The file is on the Mac the agent runs on: this one's read here, another's
// through herdr-core there (machine.exec), its tail only when it changed. A
// pi started outside Reflex (no session label) is found by its folder's
// session directory and the name it reports (pi's 7501 message is its
// session name, which its file records in `session_info`).

@MainActor
final class Replies: ObservableObject {
    static let shared = Replies()

    /// Inbox item → the reply it finished with, as plain text. Per item, not
    /// per session: a session's next "finished" never shows the reply before.
    @Published private(set) var text: [Int: String] = [:]
    /// Where each agent's file was found (pane → path on its Mac).
    private var paths: [String: String] = [:]
    /// The file's modified time when its reply was last read (as its Mac says it).
    private var read: [Int: String] = [:]
    private var busy: Set<Int> = []

    static let kinds: Set<String> = ["claude", "pi"]

    /// The session behind an inbox item, when its reply can be read: one with
    /// a session, or a pi in herdr-core, found by its folder and name.
    static func session(of item: ItemInfo, in agents: [AgentInfo]) -> AgentInfo? {
        guard item.kind == "ready", let a = agents.first(where: { $0.pane == item.pane }),
              kinds.contains(a.kind) else { return nil }
        guard a.session.isEmpty else { return a }
        return a.kind == "pi" && HerdrCore.isCore(a.pane) && !a.cwd.isEmpty ? a : nil
    }

    /// Read (again, when the file changed) the replies these items need. The
    /// agent can report done a moment before its last message reaches the
    /// file, so the inbox asks again while it is open.
    func refresh(_ items: [ItemInfo], agents: [AgentInfo]) {
        let live = Set(items.map(\.id))
        for gone in text.keys where !live.contains(gone) { text[gone] = nil; read[gone] = nil }
        for item in items {
            guard let a = Replies.session(of: item, in: agents), !busy.contains(item.id) else { continue }
            // pi's session is its file's path (as herdr reports it) or its id;
            // Claude's an id; none, a pi found by its folder and name.
            let want = Want(kind: a.kind, id: a.session, cwd: a.cwd, pane: a.pane, known: paths[a.pane] ?? "",
                            since: read[item.id] ?? "",
                            // Unnamed, it is the newest file in its folder: only when no other pi works there.
                            alone: !agents.contains { $0.pane != a.pane && $0.kind == "pi" && $0.machine == a.machine && $0.cwd == a.cwd })
            let key = item.id, machine = a.machine
            busy.insert(key)
            Task {
                let got = await Blocking.run { machine.isEmpty ? Replies.readHere(want) : Replies.readThere(machine, want) }
                await MainActor.run {
                    self.busy.remove(key)
                    guard let got else { return }
                    self.paths[want.pane] = got.path
                    guard let modified = got.modified else { return }
                    self.read[key] = modified
                    // No reply to the latest prompt yet: the screen, not the one before.
                    if self.text[key] != got.reply { self.text[key] = got.reply }
                }
            }
        }
    }

    /// What to read: the session (`id`: a path, an id, or none) and what
    /// was read before (`known` path, `since` modified time).
    struct Want: Sendable {
        let kind, id, cwd, pane, known, since: String
        let alone: Bool
    }

    /// The file found, and — when it changed since `since` — its time and reply.
    struct Got: Sendable {
        let path: String
        let modified: String?
        let reply: String?
    }

    // MARK: This Mac

    nonisolated static func readHere(_ w: Want) -> Got? {
        let fm = FileManager.default
        var url: URL?
        if !w.known.isEmpty, fm.fileExists(atPath: w.known) { url = URL(fileURLWithPath: w.known) }
        else if w.id.hasPrefix("/"), fm.fileExists(atPath: w.id) { url = URL(fileURLWithPath: w.id) }
        else if !w.id.isEmpty { url = locate(kind: w.kind, id: w.id) }
        else if let name = name(of: w) { url = piFile(cwd: w.cwd, needle: name) }
        guard let url else { return nil }
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        let modified = String(Int(date.timeIntervalSince1970))
        guard modified != w.since else { return Got(path: url.path, modified: nil, reply: nil) }
        return Got(path: url.path, modified: modified, reply: lastReply(url))
    }

    /// The newest session file in pi's folder for `cwd` holding `needle`
    /// (its name's `session_info`), or the newest one when there is no needle.
    nonisolated static func piFile(cwd: String, needle: String) -> URL? {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/.pi/agent/sessions/" + piFolder(cwd))
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return nil }
        let newest = files.filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.prefix(20).map(\.0)
        guard !needle.isEmpty else { return newest.first }
        let n = Data(needle.utf8)
        return newest.first { (try? Data(contentsOf: $0, options: .alwaysMapped))?.range(of: n) != nil }
    }

    /// pi's own name for a folder's session directory (its session-manager's
    /// getDefaultSessionDirPath): the path without its leading slash, every
    /// slash, backslash and colon a dash, between double dashes.
    nonisolated static func piFolder(_ cwd: String) -> String {
        var p = cwd
        if p.hasPrefix("/") || p.hasPrefix("\\") { p.removeFirst() }
        return "--" + String(p.map { "/\\:".contains($0) ? "-" : $0 }) + "--"
    }

    /// What to look for in a pi's files when it has no session: its name as
    /// its file records it (`"name":"…"`), "" for the newest file (only
    /// when it is alone in its folder), nil when it can't be told apart.
    nonisolated static func name(of w: Want) -> String? {
        guard w.kind == "pi", w.id.isEmpty else { return nil }
        let t = try? HerdrCore.callSync("terminal.get", ["terminal": w.pane])
        let msg = ((t?["status"] as? [String: Any])?["msg"] as? String) ?? ""
        if msg.isEmpty { return w.alone ? "" : nil }
        guard let d = try? JSONSerialization.data(withJSONObject: [msg], options: .withoutEscapingSlashes) else { return nil }
        // ["…"] → "…": the string as pi's JSON.stringify writes it.
        return "\"name\":" + String(decoding: d.dropFirst().dropLast(), as: UTF8.self)
    }

    // MARK: Another Mac

    /// The same, on the Mac the agent runs on: one shell there finds the file
    /// and prints its path, its modified time and, when that changed, its
    /// last 512 KiB.
    nonisolated static func readThere(_ machine: String, _ w: Want) -> Got? {
        guard let needle = w.id.isEmpty ? name(of: w) : "" else { return nil }
        let args = [w.kind, w.id, w.cwd, needle, w.known, w.since, piFolder(w.cwd)].map(quoted).joined(separator: " ")
        guard let out = CoreMachines.exec(machine, "sh -s " + args, input: findScript, timeout: 20) else { return nil }
        let data = Data(out.utf8)
        // path \n modified|same \n tail…
        let lines = data.split(separator: 0x0a, maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return nil }
        let path = String(decoding: lines[0], as: UTF8.self), stamp = String(decoding: lines[1], as: UTF8.self)
        guard path.hasPrefix("/") else { return nil }
        if stamp == "same" { return Got(path: path, modified: nil, reply: nil) }
        let tail = lines.count > 2 ? Data(lines[2]) : Data()
        return Got(path: path, modified: stamp, reply: lastReply(tail, partial: true))
    }

    nonisolated private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// $1 kind, $2 id, $3 cwd, $4 needle, $5 known path, $6 modified before, $7 pi's folder.
    nonisolated private static let findScript = #"""
    kind=$1 id=$2 needle=$4 known=$5 since=$6 dir="$HOME/.pi/agent/sessions/$7"
    f=
    [ -n "$known" ] && [ -f "$known" ] && f=$known
    case "$id" in /*) [ -z "$f" ] && [ -f "$id" ] && f=$id ;; esac
    if [ -z "$f" ] && [ -n "$id" ]; then
      if [ "$kind" = claude ]; then set -- "$HOME"/.claude/projects/*/"$id".jsonl
      else set -- "$HOME"/.pi/agent/sessions/*/*_"$id".jsonl; fi
      [ -f "$1" ] && f=$1
    fi
    if [ -z "$f" ] && [ -z "$id" ] && [ "$kind" = pi ] && [ -d "$dir" ]; then
      f=$(ls -t "$dir" | grep '\.jsonl$' | head -20 | while IFS= read -r n; do
        if [ -z "$needle" ] || grep -qF -- "$needle" "$dir/$n"; then echo "$dir/$n"; break; fi
      done)
    fi
    [ -n "$f" ] || exit 1
    m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")
    printf '%s\n' "$f"
    if [ "$m" = "$since" ]; then echo same; exit 0; fi
    printf '%s\n' "$m"
    tail -c 524288 "$f"
    """#

    nonisolated static func locate(kind: String, id: String) -> URL? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let root = kind == "claude" ? home + "/.claude/projects" : home + "/.pi/agent/sessions"
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for d in dirs {
            let dir = root + "/" + d
            if kind == "claude" {
                let p = dir + "/" + id + ".jsonl"
                if fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
            } else if let names = try? fm.contentsOfDirectory(atPath: dir),
                      let n = names.first(where: { $0.hasSuffix("_" + id + ".jsonl") }) {
                return URL(fileURLWithPath: dir + "/" + n)
            }
        }
        return nil
    }

    /// The last assistant message with text, from the end of the file: the
    /// reply to the latest prompt, or nil while that reply is not written yet
    /// (never the one before it). Claude also copies earlier messages into
    /// `api-request-blob` lines; only its own `assistant` lines count.
    nonisolated static func lastReply(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let from = size > 512 * 1024 ? size - 512 * 1024 : 0
        try? h.seek(toOffset: from)
        return lastReply((try? h.readToEnd()) ?? Data(), partial: from > 0)
    }

    /// The same from a file's last bytes (`partial`: its first line may be cut).
    nonisolated static func lastReply(_ data: Data, partial: Bool) -> String? {
        for line in SessionArchive.lines(data, dropFirst: partial).reversed() {
            if (line["isSidechain"] as? Bool) == true { continue }
            // Claude's own lines are "assistant" and "user"; pi's are "message".
            let type = line["type"] as? String
            guard type == "assistant" || type == "user" || type == "message",
                  let m = line["message"] as? [String: Any] else { continue }
            let role = m["role"] as? String
            if role == "user", (line["isMeta"] as? Bool) != true,
               SessionArchive.prompt(SessionArchive.text(m["content"])) != nil { return nil }
            guard role == "assistant",
                  let t = SessionArchive.text(m["content"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { continue }
            return plain(t)
        }
        return nil
    }

    /// Markdown as prose: no code blocks, tables, rules or emphasis marks;
    /// list items on their own lines, paragraphs joined.
    nonisolated static func plain(_ md: String) -> String {
        var out: [String] = []
        var para = ""
        var code = false
        func flush() {
            if !para.isEmpty { out.append(para) }
            para = ""
        }
        for raw in md.components(separatedBy: .newlines) {
            var t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { code.toggle(); flush(); continue }
            if code { continue }
            if t.isEmpty || t.hasPrefix("|") || t.allSatisfy({ "-*_=".contains($0) }) { flush(); continue }
            while t.hasPrefix("#") || t.hasPrefix(">") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            for mark in ["**", "__", "`"] { t = t.replacingOccurrences(of: mark, with: "") }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.first?.isNumber == true && t.contains(". ") && t.prefix(4).contains(".") {
                flush()
                para = t.hasPrefix("- ") || t.hasPrefix("* ") ? "• " + t.dropFirst(2) : t
                continue
            }
            para += para.isEmpty ? t : " " + t
        }
        flush()
        return String(out.joined(separator: "\n").prefix(1200))
    }
}
