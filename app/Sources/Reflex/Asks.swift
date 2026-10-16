import Foundation

// What a blocked agent is asking, for the question card. Claude writes the
// call it is waiting on (AskUserQuestion, or a tool that needs your OK) to its
// session file before it asks, so the card reads the whole question, each
// choice's description and the command's own one-line summary from there.
// The keys you press still come from the screen; when the two disagree, or
// for other agents, the card reads the screen as before.

/// One choice, as the card words it.
struct AskChoice: Equatable {
    var label: String
    var detail: String?
    /// Comes with a preview (a diagram, a mockup) that only the terminal shows.
    var preview = false
}

struct AskDetail: Equatable {
    /// AskUserQuestion's short header ("Approach"), or the tool's name.
    var header: String?
    var question: String
    /// Question `n` of `of`, when the agent asked several at once.
    var step: (n: Int, of: Int)?
    /// The command, plan, file or address it wants to use.
    var code: String?
    /// Beside the code: "+12 −3", "40 lines".
    var note: String?
    /// Screen option key → how the card shows it.
    var choices: [String: AskChoice] = [:]

    static func == (l: AskDetail, r: AskDetail) -> Bool {
        l.header == r.header && l.question == r.question && l.step?.n == r.step?.n && l.step?.of == r.step?.of
            && l.code == r.code && l.note == r.note && l.choices == r.choices
    }
}

@MainActor
final class Asks: ObservableObject {
    static let shared = Asks()

    /// Pane → the latest item read for it and what it asks. Kept per pane so
    /// a question whose item is replaced (its choices changed) keeps showing
    /// while the new one is read.
    @Published private(set) var detail: [String: (item: Int, ask: AskDetail)] = [:]
    private var paths: [String: URL] = [:]

    func ask(for item: ItemInfo) -> AskDetail? { detail[item.pane]?.ask }

    func load(_ item: ItemInfo, agent: AgentInfo?) async {
        // A pane with no question any more: its last one is not shown again.
        forget(keeping: Set(Store.shared.state.inbox.filter { $0.kind == "ask" }.map(\.pane)))
        if detail[item.pane]?.item == item.id { return }
        let screen = await Client.local.pane(item.pane, lines: 80)
        var url: URL?
        if let a = agent, a.kind == "claude", !a.session.isEmpty {
            url = paths[a.session]
            if url == nil {
                let id = a.session
                url = await Task.detached(priority: .utility) { Replies.locate(kind: "claude", id: id) }.value
                if let url { paths[id] = url }
            }
        }
        let found = await Task.detached(priority: .utility) { [url] in
            Asks.read(item, screen: screen.isEmpty ? item.body : screen, transcript: url)
        }.value
        if let found { detail[item.pane] = (item.id, found) } else { detail[item.pane] = nil }
    }

    func forget(keeping panes: Set<String>) {
        for p in detail.keys where !panes.contains(p) { detail[p] = nil }
    }

    // MARK: Reading

    nonisolated static func read(_ item: ItemInfo, screen: String, transcript: URL?) -> AskDetail? {
        let calls = transcript.map(pending) ?? []
        if let ask = calls.first(where: { $0.name == "AskUserQuestion" }), let d = question(ask.input, item, screen) { return d }
        if prompting(screen), let call = permission(calls, screen), let d = tool(call, item) { return d }
        return fromScreen(item, screen)
    }

    /// The calls the agent is still waiting on: since your last prompt, made
    /// and not yet answered.
    nonisolated static func pending(_ url: URL) -> [(name: String, input: [String: Any])] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let from = size > 512 * 1024 ? size - 512 * 1024 : 0
        try? h.seek(toOffset: from)
        let data = (try? h.readToEnd()) ?? Data()
        var calls: [(id: String, name: String, input: [String: Any])] = []
        var answered: Set<String> = []
        for line in SessionArchive.lines(data, dropFirst: from > 0) {
            if (line["isSidechain"] as? Bool) == true { continue }
            let type = line["type"] as? String
            guard type == "assistant" || type == "user", let m = line["message"] as? [String: Any] else { continue }
            let parts = m["content"] as? [[String: Any]] ?? []
            if m["role"] as? String == "user" {
                if (line["isMeta"] as? Bool) != true, parts.allSatisfy({ $0["type"] as? String != "tool_result" }),
                   SessionArchive.prompt(SessionArchive.text(m["content"])) != nil {
                    calls = []; answered = []
                }
                for p in parts where p["type"] as? String == "tool_result" {
                    if let id = p["tool_use_id"] as? String { answered.insert(id) }
                }
            } else {
                for p in parts where p["type"] as? String == "tool_use" {
                    if let id = p["id"] as? String, let name = p["name"] as? String {
                        calls.append((id, name, p["input"] as? [String: Any] ?? [:]))
                    }
                }
            }
        }
        return calls.filter { !answered.contains($0.id) }.map { ($0.name, $0.input) }
    }

    /// A tool permission prompt is on screen.
    nonisolated static func prompting(_ screen: String) -> Bool {
        ["Do you want to", "Would you like to proceed"].contains { screen.contains($0) }
    }

    /// Which waiting call the prompt is about: the one whose command, file or
    /// address is on screen, else the only one that can need asking.
    nonisolated static func permission(_ calls: [(name: String, input: [String: Any])], _ screen: String) -> (name: String, input: [String: Any])? {
        let quiet: Set<String> = ["Read", "Grep", "Glob", "LS", "TodoWrite", "ToolSearch", "AskUserQuestion"]
        let asking = calls.filter { !quiet.contains($0.name) }
        let flat = squash(screen)
        if let hit = asking.first(where: { c in
            let mark = (c.input["command"] ?? c.input["file_path"] ?? c.input["url"]) as? String
            return mark.map { squash(String($0.prefix(40))) }.map { !$0.isEmpty && flat.contains($0) } ?? false
        }) { return hit }
        if screen.contains("Would you like to proceed"), let plan = asking.first(where: { $0.name == "ExitPlanMode" }) { return plan }
        return asking.count == 1 ? asking[0] : nil
    }

    /// Without whitespace: a wrapped, indented command still matches.
    nonisolated private static func squash(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !"│┃║".unicodeScalars.contains($0) }.map(Character.init))
    }

    /// An option's label, without the multi-select box.
    nonisolated static func bareLabel(_ s: String) -> String {
        var t = s.bare.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^\[[ ✔✓xX×]\]\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        return t
    }

    nonisolated private static func same(_ screen: String, _ record: String) -> Bool {
        let s = screen.trimmingCharacters(in: CharacterSet(charactersIn: " …."))
        return !s.isEmpty && (record == s || record.hasPrefix(s))
    }

    /// AskUserQuestion: the question whose every choice is on screen (and,
    /// when two share their choices, whose words are).
    nonisolated static func question(_ input: [String: Any], _ item: ItemInfo, _ screen: String) -> AskDetail? {
        let qs = input["questions"] as? [[String: Any]] ?? []
        let shown = item.options.map { ($0.key, bareLabel($0.label)) }
        var fits: [AskDetail] = []
        for (i, q) in qs.enumerated() {
            let opts = q["options"] as? [[String: Any]] ?? []
            var choices: [String: AskChoice] = [:]
            for o in opts {
                guard let label = o["label"] as? String,
                      let key = shown.first(where: { same($0.1, label) })?.0 else { choices = [:]; break }
                let desc = (o["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = (o["preview"] as? String).map { !$0.isEmpty } ?? false
                choices[key] = AskChoice(label: label, detail: desc?.isEmpty == false ? desc : nil, preview: preview)
            }
            guard !opts.isEmpty, choices.count == opts.count, let text = q["question"] as? String else { continue }
            let header = (q["header"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            fits.append(AskDetail(header: header, question: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  step: qs.count > 1 ? (i + 1, qs.count) : nil, choices: choices))
        }
        let flat = squash(screen)
        return fits.first { flat.contains(squash(String($0.question.prefix(40)))) } ?? fits.first
    }

    /// A tool waiting for your OK: what it is for, then what it would run.
    nonisolated static func tool(_ call: (name: String, input: [String: Any]), _ item: ItemInfo) -> AskDetail? {
        let i = call.input
        func s(_ k: String) -> String? { (i[k] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        func lines(_ t: String?) -> Int { t.map { $0.isEmpty ? 0 : $0.components(separatedBy: "\n").count } ?? 0 }
        let file = s("file_path").map { ($0 as NSString).lastPathComponent }
        var d: AskDetail
        switch call.name {
        case "Bash":
            d = AskDetail(header: "Command", question: s("description") ?? "Run this command?", code: s("command"))
        case "Edit", "MultiEdit":
            let edits = i["edits"] as? [[String: Any]] ?? [i]
            let gone = edits.map { lines($0["old_string"] as? String) }.reduce(0, +)
            let added = edits.map { lines($0["new_string"] as? String) }.reduce(0, +)
            d = AskDetail(header: "Edit", question: "Edit \(file ?? "a file")?", code: s("file_path")?.abbreviatingHome, note: "+\(added) −\(gone)")
        case "Write":
            let n = lines(s("content"))
            let exists = s("file_path").map { FileManager.default.fileExists(atPath: $0) } ?? false
            d = AskDetail(header: "Write", question: "\(exists ? "Overwrite" : "Create") \(file ?? "a file")?",
                          code: s("file_path")?.abbreviatingHome, note: n == 1 ? "1 line" : "\(n) lines")
        case "NotebookEdit":
            d = AskDetail(header: "Edit", question: "Edit \(file ?? "a notebook")?", code: s("notebook_path")?.abbreviatingHome)
        case "WebFetch":
            let host = s("url").flatMap { URL(string: $0)?.host } ?? "a page"
            d = AskDetail(header: "Fetch", question: "Fetch \(host)?", code: s("url"))
        case "WebSearch":
            d = AskDetail(header: "Search", question: "Search the web?", code: s("query"))
        case "ExitPlanMode":
            d = AskDetail(header: "Plan", question: "Start on this plan?", code: s("plan").map(Replies.plain))
        default:
            // An MCP tool: mcp__server__tool.
            let parts = call.name.components(separatedBy: "__")
            let name = parts.count >= 3 ? "\(parts[2...].joined(separator: "__")) from \(parts[1])" : call.name
            let body = (try? JSONSerialization.data(withJSONObject: i, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) }
            d = AskDetail(header: "Tool", question: s("description") ?? "Use \(name)?", code: body.map { String($0.prefix(2000)) })
        }
        for o in item.options { d.choices[o.key] = choice(o.label.bare) }
        return d
    }

    /// Claude's permission choices, shorter: "Yes, and don't ask again for
    /// npm test commands in /Users/…/app" → "Yes, don't ask again", with the
    /// rest under it.
    nonisolated static func choice(_ label: String) -> AskChoice {
        var t = label.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"\s*\((esc|shift\+tab|tab)\)$"#, options: .regularExpression) { t.removeSubrange(r) }
        if t.hasPrefix("Yes, and don't ask again for ") {
            let rest = String(t.dropFirst("Yes, and don't ask again for ".count))
            return AskChoice(label: "Yes, don't ask again", detail: "for " + rest)
        }
        if t.hasPrefix("No, and tell Claude what to do differently") { return AskChoice(label: "No, tell Claude what to do instead") }
        return AskChoice(label: t)
    }

    /// The screen alone: the whole paragraph above the choices, wrapped lines
    /// joined, without a box's borders or a tab bar.
    nonisolated static func fromScreen(_ item: ItemInfo, _ screen: String) -> AskDetail? {
        guard let q = paragraph(screen) else { return nil }
        var d = AskDetail(question: q)
        if prompting(screen) { for o in item.options { d.choices[o.key] = choice(o.label.bare) } }
        return d
    }

    nonisolated static func paragraph(_ screen: String) -> String? {
        let border = CharacterSet(charactersIn: "│┃║╭╮╰╯ ")
        let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: border) }
        guard let first = lines.firstIndex(where: { $0.range(of: #"^[❯>›]?\s*1[.)]\s"#, options: .regularExpression) != nil }) else { return nil }
        var i = first - 1
        while i >= 0, lines[i].isEmpty { i -= 1 }
        var para: [String] = []
        while i >= 0, para.count < 8 {
            let l = lines[i]
            let rule = !l.isEmpty && l.allSatisfy { "─━═-_╌┄".contains($0) }
            let tabs = l.contains("☐") || l.contains("☒") || l.contains("✔ Submit") || l.hasPrefix("←")
            if l.isEmpty || rule || tabs { break }
            para.insert(l, at: 0)
            i -= 1
        }
        let text = para.joined(separator: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.isEmpty ? nil : text
    }

}
