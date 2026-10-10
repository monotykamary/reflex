import AppKit
import SwiftUI

// ⌥⌥ opens the Ask bar — instantly: it is used all day, so it does not
// animate in. Like Dia's bar it has two modes, told apart as you type:
//
//   search  a few words ("reflex", "jev fab") find a session; ⏎ opens its
//           terminal. No Jev call: instant.
//   ask     prose or a question ("fix the flaky test in jev fabric", "why
//           is staging red?") is a request. No step between: the list below
//           is where it could go — live sessions, folders to start one in, a
// new folder, any folder you choose. A local match fills the list at once;
// Jev's ranking replaces it a moment after you stop typing, with its pick on
// top. ⏎ sends to the selected row.
//
// Nothing moves the selection but you and Jev: hovering never does, a click
// on a row that has just moved under the pointer is ignored, and once you
// pick a row Jev's later rankings leave it alone.

/// A row in the Ask bar's list.
struct Candidate: Identifiable, Equatable {
    enum Kind: Equatable { case session, folder, newFolder, chooseFolder, command, ask, resume }
    var id: String
    var kind: Kind
    var title: String
    var detail: String
    /// Jev's weight, 0…10000, once Jev has answered for this text.
    var bp: Int?
    var agent: AgentInfo?
    var path: String?
    var command: SlashCommand?
    /// An earlier session (resume rows).
    var past: PastSession?
}

/// What a leading "/word" does.
enum SlashCommand: Equatable, Hashable {
    case harness(String)
    case newFolder
    case btw
    case folder
    case resume

    var token: String {
        switch self {
        case .harness(let h): return "/" + h
        case .newFolder: return "/new"
        case .btw: return "/btw"
        case .folder: return "/folder"
        case .resume: return "/resume"
        }
    }

    @MainActor var help: String {
        switch self {
        case .harness(let h):
            return h == Settings.shared.harness ? "Start new sessions with \(h) (your default)" : "Start new sessions with \(h) instead of \(Settings.shared.harness)"
        case .newFolder: return "Start in a new project folder"
        case .btw: return "Ask a side question, without interrupting"
        case .folder: return "Choose any folder to start in"
        case .resume: return "Bring back an earlier session — Claude, pi or Codex"
        }
    }

    @MainActor static var all: [SlashCommand] {
        [.resume] + Onboarding.harnesses.map { .harness($0) } + [.newFolder, .btw, .folder]
    }
}

@MainActor
final class CommandModel: ObservableObject {
    enum Phase: Equatable {
        case typing
        case sending(String)
        case sent(String)
        case failed(String)
    }

    @Published var text = "" { didSet { if text != oldValue { textChanged() } } }
    @Published var phase: Phase = .typing
    @Published var focusTick = 0
    @Published var shake: CGFloat = 0
    @Published var arrivals = 0
    /// False while the bar animates away (it appears instantly: used all day).
    @Published var shown = true
    /// The bar's measured size; its window fits it.
    @Published var size: CGSize = .zero

    // Tokens set by slash commands.
    @Published var harness: String?
    /// /resume: the words filter earlier sessions, nothing else.
    @Published var resumeOnly = false
    @Published var sideForced = false
    @Published var newForced = false

    // The list.
    @Published private(set) var jev: CandidatesResponse?
    /// The text Jev's answer is for; a stale answer is not shown as a pick.
    @Published private(set) var jevText = ""
    @Published private(set) var thinking = false
    @Published private(set) var local: [FolderInfo] = []
    @Published var selection: String?
    /// The user chose a row (keys or a deliberate click): Jev stops moving it.
    @Published var userPicked = false
    /// The folder the user chose with the chooser, offered on top.
    @Published var chosenFolder: String?
    /// Naming a new folder: ⏎ on the New folder row asks first.
    @Published var naming = false
    @Published var newName = ""
    /// When the rows last changed order (a click right after is ignored).
    private(set) var reorderedAt = Date.distantPast

    /// The session whose terminal was in front when the bar opened.
    var frontPane: String?
    /// ⌘⌫ armed on this session: a second ⌘⌫ closes it.
    @Published var armedClose: String?
    private var disarm: Task<Void, Never>?

    var close: () -> Void = {}
    /// Open an agent's terminal.
    var openPane: (String) -> Void = { _ in }
    var openSetup: (Onboarding.Step) -> Void = { _ in }
    private var debounce: Task<Void, Never>?
    private var generation = 0
    private var sendWhenReady = false

    /// An agent picked from elsewhere (the rail): select it, as if by hand.
    var target: String? {
        get { selection?.hasPrefix("s:") == true ? String(selection!.dropFirst(2)) : nil }
        set {
            selection = newValue.map { "s:" + $0 }
            userPicked = newValue != nil
        }
    }

    func reset() {
        debounce?.cancel()
        generation += 1
        text = ""
        phase = .typing
        harness = nil
        resumeOnly = false
        sideForced = false
        newForced = false
        jev = nil
        jevText = ""
        thinking = false
        selection = nil
        userPicked = false
        chosenFolder = nil
        naming = false
        newName = ""
        sendWhenReady = false
        armedClose = nil
        focusTick += 1
        Task { local = await Client.local.folders("") }
    }

    // MARK: Words

    /// The request, trimmed.
    var request: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// While typing "/p…" (no space yet), the list is commands.
    var commandQuery: String? {
        guard text.hasPrefix("/"), !text.contains(" ") else { return nil }
        return String(text.dropFirst()).lowercased()
    }

    enum Mode: Equatable { case search, ask }

    /// Decided by the words alone, with no step in between: a request
    /// (prose, a question, a command) asks; anything else is a lookup, which
    /// only ever opens a session — it is never sent anywhere.
    var mode: Mode {
        if resumeOnly { return .search }
        if sideForced || newForced || harness != nil { return .ask }
        return CommandModel.looksLikeProse(request) ? .ask : .search
    }

    /// A request, not a lookup: a question; four or more words; a phrase
    /// with sentence punctuation; or one that starts like an instruction or
    /// question, or has a sentence's verb in it ("staging is broken").
    nonisolated static func looksLikeProse(_ t: String) -> Bool {
        let words = t.split(whereSeparator: \.isWhitespace).map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        guard let first = words.first else { return false }
        if t.hasSuffix("?") { return true }
        if words.count >= 4 { return true }
        if words.count >= 2, t.contains(where: { "?!.,:;".contains($0) }) { return true }
        let verbs: Set<String> = [
            "is", "are", "was", "were", "be", "been", "has", "have", "had", "does", "do", "did", "can", "can't", "cannot",
            "won't", "doesn't", "isn't", "aren't", "didn't", "don't", "should", "would", "could", "will", "keeps", "keep",
            "fails", "failing", "failed", "broke", "broken", "breaks", "crashes", "crashing", "hangs", "works", "working",
        ]
        if words.count >= 2, words.dropFirst().contains(where: verbs.contains) { return true }
        let starts: Set<String> = [
            "fix", "add", "make", "why", "what", "how", "when", "where", "who", "which", "can", "could", "should", "would",
            "please", "run", "update", "write", "explain", "refactor", "remove", "delete", "create", "build", "test", "deploy",
            "check", "review", "implement", "rename", "move", "help", "show", "tell", "find", "investigate", "debug", "btw",
            "change", "set", "install", "upgrade", "bump", "release", "publish", "merge", "rebase", "commit", "push", "revert",
            "is", "are", "does", "do", "did", "summarize", "summarise", "document", "clean", "optimize", "port", "migrate", "try",
        ]
        return words.count >= 2 && starts.contains(first)
    }

    /// Sessions whose title, agent, folder or path contain every word —
    /// most recently switched to first, like ⌘Tab.
    var sessionMatches: [AgentInfo] {
        let q = request.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return Recents.shared.sorted(agents.filter { a in
            let hay = "\(a.title) \(a.kind) \(a.folder) \(a.place) \(a.name)".lowercased()
            return q.allSatisfy { hay.contains($0) }
        })
    }

    /// ⌘⌫ on a session: once arms it, twice (within three seconds) closes it.
    func closeSelected() {
        guard let a = selected?.agent else { return }
        if armedClose == a.pane {
            disarm?.cancel()
            armedClose = nil
            Sessions.close(a.pane)
            return
        }
        armedClose = a.pane
        disarm?.cancel()
        disarm = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.armedClose = nil
        }
    }

    var isSide: Bool {
        if sideForced { return true }
        if request.lowercased().hasPrefix("btw") { return true }
        if let s = jev?.side, jevText == request { return s >= 5000 }
        return false
    }

    /// The user's own words for "make a new project folder".
    var keywordHit: Bool {
        let k = Settings.shared.newKeyword.trimmingCharacters(in: .whitespaces).lowercased()
        return !k.isEmpty && request.lowercased().contains(k)
    }

    private func textChanged() {
        // A completed "/word " becomes a token.
        if text.hasSuffix(" "), text.hasPrefix("/") {
            let word = "/" + String(text.dropFirst().dropLast()).lowercased()
            if let c = SlashCommand.all.first(where: { $0.token == word }) {
                text = ""
                apply(c)
                return
            }
        }
        if naming { naming = false }
        if case .failed = phase { phase = .typing }
        schedule()
    }

    func apply(_ c: SlashCommand) {
        switch c {
        case .harness(let h): harness = h == Settings.shared.harness ? nil : h
        case .newFolder: newForced = true
        case .btw: sideForced = true
        case .folder: chooseFolder()
        case .resume: resumeOnly = true; SessionArchive.shared.refresh()
        }
        if text.hasPrefix("/") { text = "" }
        focusTick += 1
        schedule()
    }

    /// Backspace on an empty field takes the last token off.
    func dropToken() -> Bool {
        if resumeOnly { resumeOnly = false } else if newForced { newForced = false } else if sideForced { sideForced = false } else if harness != nil { harness = nil } else { return false }
        schedule()
        return true
    }

    // MARK: Asking Jev

    /// The index just finished: ask again, the answer may change.
    func indexReady() {
        guard !request.isEmpty, phase == .typing else { return }
        jevText = ""
        schedule()
    }

    /// The local list now; Jev's ranking ~280 ms after the last keystroke.
    private func schedule() {
        debounce?.cancel()
        generation += 1
        let gen = generation
        let words = request
        let h = harness
        Task { [weak self] in
            let fs = await Client.local.folders(words)
            guard let self, self.generation == gen else { return }
            self.local = fs
            self.settle()
        }
        guard commandQuery == nil, mode == .ask, words.count >= 3 else {
            thinking = false
            settle()
            return
        }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            self.thinking = true
            let r = try? await Client.local.candidates(words, harness: h)
            guard self.generation == gen else { return }
            self.thinking = false
            self.jev = r ?? CandidatesResponse(ok: false, error: "reflexd did not answer")
            self.jevText = words
            self.settle()
            if self.sendWhenReady {
                self.sendWhenReady = false
                if self.confident { self.submit() } else { self.nudge() }
            }
        }
    }

    /// Jev is sure enough to act on ⏎ without a look at the list.
    var confident: Bool { jevText == request && jev?.decision?.decision == "go" && pick != nil && pick != "new" }

    /// The rows changed underneath (earlier sessions re-read): keep a valid selection.
    func resettle() { settle() }

    /// Keep the selection on Jev's pick until the user takes over.
    private func settle() {
        let ids = rows.map(\.id)
        if userPicked, let s = selection, ids.contains(s) { return }
        userPicked = false
        var next = pick ?? ids.first
        // ⌘Tab-like: already in the first session's terminal → the one before it.
        if mode == .search, ids.count > 1, let front = frontPane, ids.first == "s:" + front { next = ids[1] }
        if next != selection {
            selection = next
            reorderedAt = Date()
        }
    }

    // MARK: Rows

    private var agents: [AgentInfo] { Store.shared.state.agents }

    private func leaf(_ path: String) -> String { (path as NSString).lastPathComponent }

    private func bp(for id: String) -> Int? {
        guard jevText == request, let ranked = jev?.ranked else { return nil }
        for r in ranked {
            if let p = r.action.pane, r.action.type == "prompt", "s:" + p == id { return r.bp }
            if let c = r.action.cwd, r.action.type == "spawn", "f:" + c == id { return r.bp }
            if let x = r.action.session, r.action.type == "resume", "r:" + x == id { return r.bp }
        }
        return nil
    }

    /// The folder a new project would get, from the words after the keyword
    /// (or the request's own words).
    var suggestedName: String {
        let stop: Set<String> = ["a", "an", "the", "called", "named", "for", "to", "of", "and", "with", "in", "on", "new", "project",
                                 "please", "make", "create", "start", "build", "me", "my", "that", "this", "it", "folder", "i", "want"]
        var words = request.lowercased()
        let k = Settings.shared.newKeyword.lowercased()
        if !k.isEmpty, let r = words.range(of: k) { words = String(words[r.upperBound...]) }
        let picked = words.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stop.contains($0) }.prefix(3)
        return picked.isEmpty ? "new-project" : picked.joined(separator: "-")
    }

    /// Jev's pick: what ⏎ sends to unless you choose otherwise.
    var pick: String? {
        guard mode == .ask else { return nil }
        if newForced || (keywordHit && !request.isEmpty) { return "new" }
        guard !request.isEmpty, jevText == request, let r = jev, r.ok else { return nil }
        if let a = r.decision?.action, r.decision?.decision == "go" {
            if a.type == "resume", let x = a.session { return "r:" + x }
            if let p = a.pane { return "s:" + p }
            if let c = a.cwd { return "f:" + c }
        }
        // Not sure: the best row, unless nothing is even close — then a new
        // folder. (Not while the projects are still being indexed: then
        // "nothing fits" only means "nothing indexed yet".)
        let indexed = Store.shared.state.folders > 0
        // An earlier conversation is only brought back when Jev is sure (the
        // `go` above); unsure, the guess is a live session or a folder.
        guard let top = r.ranked?.first(where: { $0.action.type != "resume" }) else { return indexed ? "new" : nil }
        if top.bp < 2500 && indexed { return "new" }
        if let p = top.action.pane, top.action.type == "prompt" { return "s:" + p }
        if let c = top.action.cwd { return "f:" + c }
        return nil
    }

    /// Below the threshold, Jev's pick is a suggestion you confirm.
    var unsure: Bool { pick != nil && !confident }

    var rows: [Candidate] {
        if let q = commandQuery {
            return SlashCommand.all.filter { q.isEmpty || $0.token.dropFirst().hasPrefix(q) }.map {
                Candidate(id: "c:" + $0.token, kind: .command, title: $0.token, detail: $0.help, command: $0)
            }
        }
        if mode == .search { return searchRows }
        let kind = harness ?? Settings.shared.harness
        let side = isSide
        var out: [Candidate] = []
        // Sessions: Jev's order when it has one, else live order.
        var sessions = Recents.shared.sorted(agents).map { a in
            Candidate(id: "s:" + a.pane, kind: .session,
                      title: a.title.isEmpty ? "\(a.kind) · \(a.folder)" : a.title,
                      detail: (side ? "btw → " : "") + "\(a.kind) · \(a.folder) · " + StatusWord.of(a.status),
                      bp: bp(for: "s:" + a.pane), agent: a, path: a.cwd)
        }
        // Jev's weight first; equal weights keep the recent order (stable).
        sessions = sessions.enumerated().sorted { l, r in
            let a = l.element.bp ?? -1, b = r.element.bp ?? -1
            return a != b ? a > b : l.offset < r.offset
        }.map(\.element)
        out += sessions
        if !side {
            // Folders: the chosen one, Jev's, then the local index's — once each.
            var seen = Set<String>()
            var folders: [Candidate] = []
            if let c = chosenFolder {
                seen.insert(c)
                folders.append(Candidate(id: "f:" + c, kind: .folder, title: leaf(c), detail: "new \(kind) · \(c.abbreviatingHome) · chosen",
                                         bp: bp(for: "f:" + c), path: c))
            }
            for r in (jevText == request ? jev?.ranked ?? [] : []) where r.action.type == "spawn" {
                guard let c = r.action.cwd, seen.insert(c).inserted else { continue }
                folders.append(Candidate(id: "f:" + c, kind: .folder, title: leaf(c), detail: "new \(kind) · \(c.abbreviatingHome)", bp: r.bp, path: c))
            }
            for f in local where seen.insert(f.path).inserted {
                folders.append(Candidate(id: "f:" + f.path, kind: .folder, title: f.name,
                                         detail: "new \(kind) · \(f.short)" + (f.desc.isEmpty ? "" : " · \(f.desc)"), path: f.path))
            }
            // Folders before earlier sessions: new work is the common case,
            // and the folders must not fall below the fold.
            out += folders.prefix(8)
            // Earlier sessions Jev weighed for this request.
            for r in (jevText == request ? jev?.ranked ?? [] : []) where r.action.type == "resume" {
                guard let x = r.action.session else { continue }
                let past = SessionArchive.shared.sessions.first { $0.id == x }
                    ?? PastSession(agent: r.action.kind ?? "claude", id: x, cwd: r.action.cwd ?? "", title: r.label,
                                   last: "", modified: Date(), state: .past)
                out.append(resumeRow(past, bp: r.bp))
            }
            if !request.isEmpty {
                out.append(Candidate(id: "new", kind: .newFolder, title: "New folder “\(suggestedName)”",
                                     detail: "new \(kind) · \((Settings.shared.newFolderParent as NSString).appendingPathComponent(suggestedName).abbreviatingHome)"))
            }
            out.append(Candidate(id: "choose", kind: .chooseFolder, title: "Choose folder…", detail: "start in any folder; added to your projects if it's new"))
        }
        // Jev's pick first.
        if let p = pick, let i = out.firstIndex(where: { $0.id == p }) {
            out.insert(out.remove(at: i), at: 0)
        }
        return out
    }

    /// Search: the live sessions matching every word (most recent first),
    /// then earlier sessions that could be resumed. /resume: only those.
    private var searchRows: [Candidate] {
        let pasts = SessionArchive.shared.matching(request, limit: resumeOnly ? 30 : (request.isEmpty ? 4 : 6)).map { resumeRow($0, bp: nil) }
        if resumeOnly { return pasts }
        return sessionMatches.map { a in
            Candidate(id: "s:" + a.pane, kind: .session,
                      title: a.title.isEmpty ? "\(a.kind) · \(a.folder)" : a.title,
                      detail: "\(a.kind) · \(a.folder) · " + StatusWord.of(a.status), agent: a, path: a.cwd)
        } + pasts
    }

    private func resumeRow(_ p: PastSession, bp: Int?) -> Candidate {
        let state: String
        switch p.state {
        case .running: state = " · running in the background"
        case .background: state = " · background, stopped"
        case .elsewhere: state = " · open elsewhere — forks"
        case .past: state = ""
        }
        return Candidate(id: "r:" + p.id, kind: .resume, title: p.title,
                         detail: "\(p.agent) · \(p.folder) · \(p.ago)" + state, bp: bp, path: p.cwd, past: p)
    }

    var selected: Candidate? { rows.first { $0.id == selection } ?? rows.first }

    // MARK: Moving

    func move(_ delta: Int) {
        let r = rows
        guard !r.isEmpty else { return }
        let i = r.firstIndex { $0.id == selection } ?? 0
        selection = r[max(0, min(r.count - 1, i + delta))].id
        userPicked = true
        armedClose = nil
        naming = false
    }

    /// A deliberate click: ignored if the rows just moved under the pointer.
    func click(_ c: Candidate, count: Int) {
        guard Date().timeIntervalSince(reorderedAt) > 0.35 else { return }
        selection = c.id
        userPicked = true
        armedClose = nil
        if count >= 2 { submit() }
    }

    // MARK: Sending

    /// ⏎: send to the selected row. Before Jev has answered, wait for it —
    /// then go if it is sure, else show its pick to confirm.
    func submit() {
        guard phase == .typing || isFailed else { return }
        if selected?.kind == .command, let c = selected?.command { apply(c); return }
        if selected?.kind == .chooseFolder { chooseFolder(); return }
        if mode == .search {
            if selected?.kind == .resume, let c = selected { send(to: c, open: true); return }
            if let a = selected?.agent { openPane(a.pane); close() }
            return
        }
        guard !request.isEmpty else { return }
        if !userPicked && (thinking || debounce.map { !$0.isCancelled } == true && jevText != request && request.count >= 3) {
            sendWhenReady = true
            return
        }
        guard let c = selected else { return }
        send(to: c)
    }

    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    private func nudge() {
        withAnimation(.linear(duration: 0.36)) { shake += 1 }
    }

    /// ⌘⏎ on an earlier session in search: a fork, not the session itself.
    func forkSelected() {
        guard let c = selected, c.kind == .resume, let p = c.past else { submit(); return }
        resume(p, mode: "fork", text: "", open: true)
    }

    private func resume(_ p: PastSession, mode: String?, text: String, open: Bool) {
        let how = (mode ?? p.mode) == "fork" ? "Forking" : ((mode ?? p.mode) == "attach" ? "Attaching" : "Resuming")
        phase = .sending("\(how) \(p.agent) · \(p.title.prefix(40))")
        Task {
            do {
                try await Sessions.resume(p, mode: mode, text: text, open: open)
                done("\(how) \(p.agent) in \(p.folder)")
            } catch { fail("reflexd did not answer — \(error.localizedDescription)") }
        }
    }

    /// Where this request went, for follow-ups; and when it was not where
    /// Jev would have sent it, the correction, for similar requests later.
    private func remember(_ words: String, sentTo c: Candidate, kind: String) {
        let target = describe(c, kind: kind)
        Memory.shared.sent(words, to: target)
        guard let p = pick, p != c.id, jevText == words else { return }
        let jev = p == "new" ? "a new project folder" : rows.first { $0.id == p }.map { describe($0, kind: kind) }
        if let jev { Memory.shared.corrected(words, jev: jev, chose: target) }
    }

    private func describe(_ c: Candidate, kind: String) -> String {
        switch c.kind {
        case .session:
            guard let a = c.agent else { return c.title }
            return "the \(a.kind) session in \(Memory.short(a.cwd))" + (a.title.isEmpty ? "" : " (\"\(a.title)\")")
        case .folder:
            return "a new \(kind) session in \(Memory.short(c.path ?? c.title))"
        case .newFolder:
            return "a new project folder"
        case .resume:
            guard let p = c.past else { return c.title }
            return "the earlier \(p.agent) conversation \"\(p.title)\" in \(Memory.short(p.cwd))"
        default:
            return c.title
        }
    }

    /// ⌘⏎ in ask mode: send, then open that agent's terminal to watch.
    func sendAndOpen() {
        guard mode == .ask, let c = selected else { return }
        send(to: c, open: true)
    }

    func send(to c: Candidate, open: Bool = false) {
        let words = request
        let kind = harness ?? Settings.shared.harness
        if mode == .ask, ![.command, .chooseFolder, .ask].contains(c.kind), c.kind != .newFolder || naming {
            remember(words, sentTo: c, kind: kind)
        }
        switch c.kind {
        case .session:
            guard let a = c.agent else { return }
            let side = isSide
            let label = (side ? "btw → " : "") + "\(a.kind) · \(a.folder)"
            phase = .sending(label)
            Task {
                do {
                    if side {
                        let r = try await Client.local.side(pane: a.pane, text: words)
                        if let e = r.error ?? r.route?.error { return fail(e) }
                        if r.route?.decision == "choose" {
                            return fail("\(a.kind) has no side channel: remove /btw to send it as a prompt.")
                        }
                        done(label)
                    } else {
                        Recents.shared.touch(a.pane)
                        let p = try await Client.local.send(pane: a.pane, text: words, label: label)
                        await watch(p.id, label: label)
                    }
                    if open { openPane(a.pane) }
                } catch { fail("reflexd did not answer — \(error.localizedDescription)") }
            }
        case .folder:
            guard let path = c.path else { return }
            spawn(in: path, kind: kind, text: words, open: open)
        case .newFolder:
            // Rare by design: name it first, then ⏎ again to create.
            if !naming {
                newName = suggestedName
                naming = true
                return
            }
            let name = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
            guard !name.isEmpty else { return }
            let path = (Settings.shared.newFolderParent as NSString).appendingPathComponent(name)
            naming = false
            spawn(in: path, kind: kind, text: words, isNew: true, open: open)
        case .chooseFolder:
            chooseFolder()
        case .command:
            if let cmd = c.command { apply(cmd) }
        case .ask:
            break
        case .resume:
            guard let p = c.past else { return }
            // From search: just bring it back. From a request: bring it back and send it.
            resume(p, mode: nil, text: mode == .ask ? words : "", open: open)
        }
    }

    private func spawn(in path: String, kind: String, text: String, isNew: Bool = false, open: Bool = false) {
        let label = "\(kind) in \((path as NSString).lastPathComponent)"
        phase = .sending((isNew ? "new folder · " : "") + label)
        Task {
            do {
                let p = try await Client.local.spawn(cwd: path, kind: kind, text: text)
                if open { Sessions.openWhenStarted(p.id) }
                if isNew {
                    // The new folder is inside a root: the next index finds it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Task { await Client.local.reindex() } }
                }
                // Starting an agent takes a few seconds; a failure lands in the inbox.
                done("Starting " + label)
            } catch { fail("reflexd did not answer — \(error.localizedDescription)") }
        }
    }

    /// A prompt runs at once: show its receipt, or its failure.
    private func watch(_ id: Int, label: String) async {
        for _ in 0..<20 {
            await Store.shared.refresh()
            if let r = Store.shared.state.receipts.first(where: { $0.id == id }) {
                return r.ok ? done(label) : fail(r.detail)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        done(label)
    }

    private func done(_ label: String) {
        phase = .sent(label)
        arrivals += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if case .sent = self?.phase { self?.close() }
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        nudge()
    }

    /// Any folder: a chooser. One outside the project roots joins the projects.
    func chooseFolder() {
        if text.hasPrefix("/") { text = "" }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Start Here"
        panel.message = "Choose the folder to start this session in."
        panel.directoryURL = URL(fileURLWithPath: Settings.shared.newFolderParent)
        AppDelegate.activateSelf()
        guard panel.runModal() == .OK, let url = panel.url else { focusTick += 1; return }
        Settings.shared.addFolder(url.path)
        chosenFolder = url.path
        selection = "f:" + url.path
        userPicked = true
        focusTick += 1
    }

    /// Esc: leave naming, then clear a failure, then close.
    func escape() {
        if naming { naming = false; focusTick += 1; return }
        if case .failed = phase { phase = .typing; focusTick += 1; return }
        close()
    }
}

enum StatusWord {
    static func of(_ status: String) -> String {
        switch status {
        case "working": return "working"
        case "blocked": return "needs you"
        case "done": return "done"
        default: return "idle"
        }
    }
}

// MARK: - View

struct CommandBar: View {
    @ObservedObject var model: CommandModel
    @ObservedObject var store = Store.shared
    @ObservedObject var archive = SessionArchive.shared
    @FocusState private var focused: Bool
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            field
                .raySurface(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .modifier(Shake(animatableData: model.shake))
            list
                // The footer's tint must not square off the rounded corners.
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .raySurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(width: 680)
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.size = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        // Leaves with a short fade, settle and blur; arrives with none.
        .opacity(model.shown ? 1 : 0)
        .scaleEffect(model.shown || reduce ? 1 : 0.98, anchor: .top)
        .offset(y: model.shown || reduce ? 0 : -6)
        .blur(radius: model.shown || reduce ? 0 : 3)
        .animation(model.shown ? nil : Motion.exit, value: model.shown)
        .animation(Motion.pick(Motion.swap, reduce: reduce), value: model.rows.map(\.id))
        .animation(Motion.pick(Motion.swap, reduce: reduce), value: model.phase)
        .onChange(of: model.focusTick) { _, _ in focused = true }
        .onChange(of: store.state.folders > 0) { _, ready in if ready { model.indexReady() } }
        .onChange(of: archive.sessions.map(\.id)) { _, _ in model.resettle() }
        .onChange(of: model.naming) { _, n in if n { nameFocused = true } else { focused = true } }
        .onAppear { focused = true }
        .sensoryFeedback(.alignment, trigger: model.selection)
        .sensoryFeedback(.levelChange, trigger: model.arrivals)
    }

    // MARK: Field

    private var field: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.mode == .search && model.commandQuery == nil ? "magnifyingglass" : "sparkle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: model.thinking && !reduce)
                    .frame(width: 20)
                    .help(model.mode == .search ? "Searching your sessions" : "A request — Jev routes it")
                tokens
                TextField("", text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Type.field)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { model.submit() }
                    .onKeyPress(phases: .down) { press in key(press) }
                    .background(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text(placeholder)
                                .font(Type.field)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .id(placeholder)
                                // Gone the instant you type; a new placeholder still blurs in.
                                .transition(.asymmetric(insertion: .blurSwap, removal: .identity))
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(isSending)
                trailing
            }
            .frame(minHeight: CommandBar.lineHeight)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        // Over the field's bottom edge, taking no room: nothing shifts when Jev starts reading.
        .overlay(alignment: .bottom) {
            if model.thinking {
                ThinkingLine().frame(height: 2).padding(.horizontal, 24).transition(.opacity)
            }
        }
    }

    /// The field's one-line height (Type.field), which tokens fit inside.
    static let lineHeight: CGFloat = 28

    private var isSending: Bool { if case .sending = model.phase { return true } else { return false } }

    private var placeholder: String {
        if model.sideForced { return "Ask on the side…" }
        if model.newForced { return "What's the new project for?" }
        if model.resumeOnly { return "Find an earlier session…" }
        if let h = model.harness { return "Ask a new \(h) session, or your agents…" }
        return "Search sessions, or ask your agents…"
    }

    private var tokens: some View {
        HStack(spacing: 6) {
            if let h = model.harness { token("/" + h, Tone.route) }
            if model.newForced { token("/new", Tone.done) }
            if model.sideForced { token("/btw", Tone.blocked) }
            if model.resumeOnly { token("/resume", Tone.working) }
        }
    }

    private func token(_ label: String, _ tint: Color) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9)
            .frame(height: CommandBar.lineHeight - 4)
            .background(tint.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
            .transition(.surface(reduce: reduce))
    }

    @ViewBuilder private var trailing: some View {
        switch model.phase {
        case .sending:
            ProgressView().controlSize(.small).transition(.blurSwap)
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Tone.done)
                .font(.system(size: 17))
                .transition(.symbolEffect(.drawOn))
        default:
            EmptyView()
        }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .downArrow: model.move(1); return .handled
        case .upArrow: model.move(-1); return .handled
        case .tab: model.move(press.modifiers.contains(.shift) ? -1 : 1); return .handled
        case .return where press.modifiers.contains(.command):
            // Send, then open the terminal (in search, ⏎ already opens it).
            if model.mode == .search { model.forkSelected() } else { model.sendAndOpen() }
            return .handled
        case .return where press.modifiers.contains(.option):
            // A new line in a long request.
            return .ignored
        case .return:
            // A multi-line field takes Return as a new line and never submits;
            // ⏎ is the bar's main key, so it is handled here.
            model.submit()
            return .handled
        case .delete where press.modifiers.contains(.command) && model.selected?.kind == .session:
            model.closeSelected()
            return .handled
        case .delete where model.text.isEmpty: return model.dropToken() ? .handled : .ignored
        default: break
        }
        if press.modifiers.contains(.control), press.characters == "n" { model.move(1); return .handled }
        if press.modifiers.contains(.control), press.characters == "p" { model.move(-1); return .handled }
        // ⌘1–9: that row, deliberately.
        if press.modifiers.contains(.command), let n = Int(press.characters), (1...9).contains(n) {
            let r = model.rows
            if r.indices.contains(n - 1) {
                model.selection = r[n - 1].id
                model.userPicked = true
                model.submit()
            }
            return .handled
        }
        return .ignored
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .sent(let label):
                status("checkmark.circle.fill", Tone.done, "Sent", label)
            case .sending(let label):
                status("arrow.turn.down.right", Tone.working, "Sending", label)
            default:
                if !model.rows.isEmpty { rowsView }
            }
            footer
        }
    }

    private func status(_ symbol: String, _ tint: Color, _ title: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title).font(Type.title)
            Text(label.bare).font(Type.body).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .transition(.blurSwap)
    }

    private var rowsView: some View {
        let rows = model.rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, c in
                        if let header = header(before: i, rows: rows) {
                            Text(header)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, i == 0 ? 6 : 10).padding(.bottom, 3)
                        }
                        CandidateRow(candidate: c, index: i, selected: c.id == model.selection,
                                     isPick: c.id == model.pick && c.kind != .command, unsure: model.unsure,
                                     naming: model.naming && c.kind == .newFolder,
                                     name: $model.newName, nameFocused: $nameFocused,
                                     confirmName: { model.send(to: c) },
                                     click: { model.click(c, count: $0) })
                            .id(c.id)
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .scrollIndicators(.never)
            .frame(height: min(max(rowsHeight, 44), 340))
            .onChange(of: model.selection) { _, s in
                if let s { withAnimation(Motion.pick(Motion.micro, reduce: reduce)) { proxy.scrollTo(s) } }
            }
        }
    }

    /// Section titles: Jev's pick, then each kind of row.
    private func header(before i: Int, rows: [Candidate]) -> String? {
        let c = rows[i]
        if c.kind == .command { return i == 0 ? "Commands" : nil }
        if i == 0 && c.id == model.pick { return model.unsure ? "Jev's best guess" : "Jev's pick" }
        func group(_ k: Candidate.Kind) -> String {
            switch k {
            case .session: return model.mode == .search ? "Open a session" : (model.isSide ? "Ask on the side" : "Sessions")
            case .ask: return "Ask"
            case .folder: return "Start in a folder"
            case .newFolder, .chooseFolder: return "Other"
            case .resume: return "Resume"
            case .command: return "Commands"
            }
        }
        if i == 0 { return group(c.kind) }
        let afterPick = i == 1 && rows[0].id == model.pick
        if afterPick || group(rows[i - 1].kind) != group(c.kind) { return group(c.kind) }
        return nil
    }

    private var footer: some View {
        HStack(spacing: 12) {
            footerStatus
            Spacer()
            if case .typing = model.phase, let c = model.selected, !model.request.isEmpty || c.kind == .command || c.kind == .chooseFolder {
                Text(actionLabel(c)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                KeyCap(key: "⏎", tint: .primary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    @ViewBuilder private var footerStatus: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .typing where model.armedClose != nil:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.red)
                Text("⌘⌫ again to close \(model.selected?.agent.map { "\($0.kind) · \($0.folder)" } ?? "this session") — it ends the agent")
                    .foregroundStyle(.primary).lineLimit(1)
            case .typing where model.mode == .search && !model.request.isEmpty && model.rows.isEmpty:
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                Text("No session matches “\(model.request)” — write it as a sentence to send it").foregroundStyle(.secondary).lineLimit(1)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.blocked)
                Text(message).lineLimit(2)
                if message.lowercased().contains("credential") || message.contains("provider key") {
                    Button("Set up Jev") { model.close(); model.openSetup(.jev) }.controlSize(.small)
                }
            default:
                if !store.connected {
                    Label("reflexd offline", systemImage: "bolt.horizontal.circle").foregroundStyle(Tone.blocked)
                } else if model.thinking {
                    Text("Jev is reading…").foregroundStyle(.secondary)
                } else if store.state.folders == 0 && !model.request.isEmpty {
                    ProgressView().controlSize(.mini)
                    Text("Indexing your projects…").foregroundStyle(.secondary)
                } else if let j = model.jev, model.jevText == model.request, !model.request.isEmpty {
                    if j.ok {
                        Text(model.unsure ? "Jev isn't sure — ↑↓ to choose" : "Jev").foregroundStyle(.secondary)
                        if let ms = j.ms { Text(verbatim: "\(ms) ms").foregroundStyle(.tertiary).monospacedDigit() }
                        hint("⌘⏎", "send & open")
                    } else {
                        Text(j.error ?? "Jev did not answer").foregroundStyle(Tone.blocked).lineLimit(1)
                    }
                } else if model.mode == .search {
                    hint("⏎", "open")
                    if model.selected?.kind == .session { hint("⌘⌫", "close") }
                    if model.selected?.kind == .resume { hint("⌘⏎", "fork instead") }
                    Text("type a request to send it").foregroundStyle(.tertiary)
                    hint("/", "commands")
                } else {
                    hint("↑↓", "choose")
                    hint("⌘⏎", "send & open")
                    hint("/", "commands")
                }
            }
        }
        .font(.system(size: 12))
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(Type.count).foregroundStyle(.secondary)
            Text(what).foregroundStyle(.tertiary)
        }
    }

    private func actionLabel(_ c: Candidate) -> String {
        let kind = model.harness ?? Settings.shared.harness
        switch c.kind {
        case .session:
            if model.mode == .search { return "Open terminal" }
            return model.isSide ? "Ask on the side" : "Send to \(c.agent?.kind ?? "agent")"
        case .folder: return "Start \(kind) in \(c.title)"
        case .newFolder: return model.naming ? "Create folder and start" : "Name the new folder"
        case .chooseFolder: return "Choose…"
        case .command: return "Use \(c.title)"
        case .ask: return "Ask Jev"
        case .resume:
            let how = c.past?.mode == "attach" ? "Attach" : (c.past?.mode == "fork" ? "Fork" : "Resume")
            return model.mode == .ask ? "\(how) and send" : how
        }
    }
}

/// One row: icon, title, detail; Jev's weight; selection drawn on the row,
/// hover only faintly — hovering never selects.
private struct CandidateRow: View {
    var candidate: Candidate
    var index: Int
    var selected: Bool
    var isPick: Bool
    var unsure: Bool
    var naming: Bool
    @Binding var name: String
    var nameFocused: FocusState<Bool>.Binding
    var confirmName: () -> Void
    var click: (Int) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                if naming {
                    HStack(spacing: 4) {
                        Text("New folder").font(.system(size: 13, weight: .semibold))
                        TextField("", text: $name, prompt: Text("name"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .focused(nameFocused)
                            .onSubmit(confirmName)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text("⏎ to create it and start · esc to keep looking").font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    Text(candidate.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(candidate.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if isPick {
                Label(unsure ? "best guess" : "Jev", systemImage: "sparkle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(unsure ? Tone.blocked : Tone.route)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background((unsure ? Tone.blocked : Tone.route).opacity(0.14), in: Capsule())
            }
            if let bp = candidate.bp {
                Text(verbatim: "\(bp / 100)%").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }
            if index < 9 {
                Text(verbatim: "⌘\(index + 1)").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .trailing)
                    .opacity(selected || hover ? 1 : 0)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.12 : (hover ? 0.04 : 0)))
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.micro) { hover = h } }
        .gesture(TapGesture(count: 2).onEnded { click(2) }.exclusively(before: TapGesture().onEnded { click(1) }))
        .animation(Motion.micro, value: selected)
    }

    @ViewBuilder private var icon: some View {
        switch candidate.kind {
        case .session:
            AgentGlyph(status: candidate.agent?.status ?? "idle", size: 11)
        case .folder:
            Image(systemName: "folder.fill").foregroundStyle(Color(red: 0.35, green: 0.62, blue: 0.95))
        case .newFolder:
            Image(systemName: "folder.badge.plus").foregroundStyle(Tone.done)
        case .chooseFolder:
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        case .command:
            Image(systemName: "slash.circle").foregroundStyle(Tone.route)
        case .ask:
            Image(systemName: "sparkle").foregroundStyle(Tone.route)
        case .resume:
            Image(systemName: candidate.past?.state == .running ? "moon.zzz.fill" : "clock.arrow.circlepath").foregroundStyle(Tone.working)
        }
    }
}
