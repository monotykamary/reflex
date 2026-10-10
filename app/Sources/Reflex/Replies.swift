import Foundation

// A finished session's last reply, read from the agent's own session file
// instead of its screen: the inbox shows what it said, as prose, without the
// terminal around it. Claude (~/.claude/projects/*/<id>.jsonl) and pi
// (~/.pi/agent/sessions/*/<time>_<id>.jsonl); other agents keep the screen.

@MainActor
final class Replies: ObservableObject {
    static let shared = Replies()

    /// Session id → its last reply, as plain text.
    @Published private(set) var text: [String: String] = [:]
    private var paths: [String: URL] = [:]
    private var read: [String: Date] = [:]
    private var busy: Set<String> = []

    static let kinds: Set<String> = ["claude", "pi"]

    /// The session behind an inbox item, when its reply can be read.
    static func session(of item: ItemInfo, in agents: [AgentInfo]) -> AgentInfo? {
        guard item.kind == "ready", let a = agents.first(where: { $0.pane == item.pane }),
              kinds.contains(a.kind), !a.session.isEmpty else { return nil }
        return a
    }

    /// Read (again, when the file changed) the replies these items need.
    func refresh(_ items: [ItemInfo], agents: [AgentInfo]) {
        for item in items {
            guard let a = Replies.session(of: item, in: agents), !busy.contains(a.session) else { continue }
            let id = a.session, kind = a.kind, known = paths[id], last = read[id]
            busy.insert(id)
            Task.detached(priority: .utility) {
                let url = known ?? Replies.locate(kind: kind, id: id)
                let modified = url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                let fresh = modified != nil && modified != last
                let reply = fresh ? url.flatMap(Replies.lastReply) : nil
                await MainActor.run {
                    self.busy.remove(id)
                    if let url { self.paths[id] = url }
                    if fresh, let modified { self.read[id] = modified }
                    if let reply, self.text[id] != reply { self.text[id] = reply }
                }
            }
        }
    }

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

    /// The last assistant message with text, from the end of the file.
    nonisolated static func lastReply(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let from = size > 512 * 1024 ? size - 512 * 1024 : 0
        try? h.seek(toOffset: from)
        let data = (try? h.readToEnd()) ?? Data()
        for line in SessionArchive.lines(data, dropFirst: from > 0).reversed() {
            if (line["isSidechain"] as? Bool) == true { continue }
            guard let m = line["message"] as? [String: Any], (m["role"] as? String) == "assistant",
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
