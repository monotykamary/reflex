import Foundation

// A thin client for reflexd's JSON API, plus the polled state the UI renders.

struct Client {
    var base: URL
    var token: String

    static var local: Client { Client(base: URL(string: "http://127.0.0.1:\(Settings.shared.port)")!, token: Settings.daemonToken) }

    private func request(_ path: String, body: [String: Any]? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 90
        if let body {
            r.httpMethod = "POST"
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let (data, _) = try await URLSession.shared.data(for: request(path))
        return try JSONDecoder().decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, _ body: [String: Any], as: T.Type) async throws -> T {
        let (data, _) = try await URLSession.shared.data(for: request(path, body: body))
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any]) async -> Bool {
        (try? await URLSession.shared.data(for: request(path, body: body))) != nil
    }

    func state() async throws -> StateInfo { try await get("/api/state", as: StateInfo.self) }
    /// Whether reflexd hands over its state within `seconds` (its actor
    /// answers, not just its socket).
    func answers(within seconds: TimeInterval) async -> Bool {
        var r = request("/api/state")
        r.timeoutInterval = seconds
        guard let (data, _) = try? await URLSession.shared.data(for: r) else { return false }
        return (try? JSONDecoder().decode(StateInfo.self, from: data)) != nil
    }
    /// The agents herdr-core lost (a restart): shown to bring back.
    func stopped() async throws -> [StoppedInfo] { try await get("/api/stopped", as: StoppedResponse.self).stopped }

    private struct Health: Decodable { var ok: Bool }
    /// reflexd is up and answering.
    func healthy() async -> Bool { (try? await get("/api/health", as: Health.self))?.ok ?? false }

    /// Route a request. `dry`: decide only — nothing is sent or started.
    func route(_ text: String, dry: Bool = false) async throws -> RouteResponse {
        var body: [String: Any] = ["text": text, "memory": await Memory.shared.context(for: text)]
        if dry { body["dry"] = true }
        return try await post("/api/route", body, as: RouteResponse.self)
    }

    /// Jev's live ranking for the Ask bar's list. Dry: nothing is sent.
    /// Jev's ranking; `machine` ("@work") keeps it to that Mac's sessions,
    /// folders and earlier sessions.
    func candidates(_ text: String, harness: String?, machine: String? = nil) async throws -> CandidatesResponse {
        var body: [String: Any] = ["text": text, "memory": await Memory.shared.context(for: text)]
        if let harness { let (k, profile) = Profiles.split(harness); body["harness"] = k; body["profile"] = profile }
        if let machine { body["machine"] = machine }
        return try await post("/api/candidates", body, as: CandidatesResponse.self)
    }

    func send(pane: String, text: String, label: String) async throws -> PendingInfo {
        try await post("/api/send", ["pane": pane, "text": text, "label": label], as: PendingInfo.self)
    }

    func side(pane: String, text: String) async throws -> RouteResponse {
        try await post("/api/side", ["pane": pane, "text": text], as: RouteResponse.self)
    }

    /// `kind` may name a profile: "claude[tom]" (see Profiles).
    func spawn(cwd: String, kind: String, text: String) async throws -> PendingInfo {
        let (k, profile) = Profiles.split(kind)
        return try await post("/api/spawn", ["cwd": cwd, "kind": k, "profile": profile, "text": text], as: PendingInfo.self)
    }

    private struct OkReply: Decodable { var ok: Bool }

    @discardableResult
    func answer(item: Int, key: String) async -> Bool {
        (try? await post("/api/answer", ["item": item, "key": key], as: OkReply.self))?.ok ?? false
    }
    @discardableResult
    func dismiss(_ item: Int) async -> Bool {
        (try? await post("/api/dismiss", ["item": item], as: OkReply.self))?.ok ?? false
    }
    func note(pane: String, agent: String, title: String, body: String) async {
        await post("/api/note", ["pane": pane, "agent": agent, "title": title, "body": body])
    }
    func focus(_ pane: String) async { await post("/api/focus", ["pane": pane]) }
    /// Bytes into a pane as typed (herdr pane.send_text): a shared terminal's keys.
    @discardableResult
    func type(_ pane: String, _ text: String) async -> Bool { await post("/api/text", ["pane": pane, "text": text]) }
    /// Bring an earlier session back in a new herdr workspace (resume, fork
    /// or attach), then submit `text` there if it is not empty.
    func resume(_ p: PastSession, mode: String, text: String) async throws -> PendingInfo {
        try await post("/api/resume", ["cwd": p.cwd, "kind": p.agent, "profile": p.profile ?? "", "session": p.id, "mode": mode, "text": text,
                                       "label": "\(p.spec) · \(p.title.prefix(40))"], as: PendingInfo.self)
    }

    /// A live agent's own session, brought back where new sessions start
    /// (mode "continue": the folder's latest, its id never known).
    func resume(cwd: String, kind: String, profile: String? = nil, session: String, mode: String = "resume", label: String) async throws -> PendingInfo {
        try await post("/api/resume", ["cwd": cwd, "kind": kind, "profile": profile ?? "", "session": session, "mode": mode, "text": "", "label": label],
                       as: PendingInfo.self)
    }

    /// Ends the session: herdr closes the pane and the agent in it.
    /// Returns true if closed (or already gone), false if closing failed.
    @discardableResult
    func close(_ pane: String) async -> Bool {
        guard let r = try? await post("/api/close", ["pane": pane], as: PaneResponse.self) else { return false }
        if r.ok { return true }
        let err = (r.error ?? "").lowercased()
        return err.contains("not_found") || err.contains("no terminal") || err.contains("not found")
    }
    func reindex() async { await post("/api/reindex", [:]) }
    /// Another Mac's folders changed (RemoteIndex): merged in, this Mac not scanned again.
    func reindexMachines() async { await post("/api/reindex", ["machines": true]) }

    func pane(_ id: String, lines: Int = 160) async -> String {
        let q = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        let r = try? await get("/api/pane?id=\(q)&lines=\(lines)", as: PaneResponse.self)
        return r?.text ?? r?.error ?? ""
    }

    /// Folders for the words: every Mac's (nil), this Mac's ("."), or one machine's.
    func folders(_ q: String, machine: String? = nil) async -> [FolderInfo] {
        let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let m = machine.map { "&machine=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0) } ?? ""
        return (try? await get("/api/folders?q=\(e)\(m)", as: FoldersResponse.self))?.folders ?? []
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var state = StateInfo.empty
    @Published private(set) var connected = false
    /// When reflexd last answered (DaemonWatch restarts one that stops).
    private(set) var lastOK = Date()
    /// Agents herdr-core lost (a restart), asked for every few seconds.
    @Published private(set) var stopped: [StoppedInfo] = []
    private var stoppedAt = Date.distantPast
    /// Resumed or dismissed: gone at once, not back while the core still lists it.
    private var leaving: Set<String> = []
    /// Panes being closed (or confirmed ended by herdr-core): gone at once from
    /// lists, windows and MissingHold until the daemon poll drops them.
    private struct ClosingEntry {
        var at: Date
        var confirmed: Bool
    }
    private var closing: [String: ClosingEntry] = [:]
    /// Published for SteadyRows so intentionally closed rows leave immediately
    /// instead of sitting dimmed for the unexpected-blip grace period.
    @Published private(set) var closingPanes: Set<String> = []
    /// Optimistic pending answers until reflexd reports the real pending/clear.
    private var answering: [Int: (pending: PendingInfo, at: Date)] = [:]
    /// Bumped per pane when a dispatch to it ran — the receiving bead pulses.
    @Published private(set) var pulses: [String: Int] = [:]
    /// A question that just arrived, surfaced at the edge for a few seconds.
    @Published var peek: ItemInfo?

    private var loop: Task<Void, Never>?
    private var lastPending: [PendingInfo] = []
    private var seenItems: Set<Int>?
    private var peekClear: Task<Void, Never>?
    /// When each pane last had a question in the inbox.
    private var askedAt: [String: Date] = [:]
    private var clearing: Set<Int> = []
    /// Another machine's agents a slow answer left out of the list, kept.
    private var missing = MissingHold()
    /// Panes currently being probed via `terminal.get` to tell a slow machine
    /// from a closed remote agent.
    private var probingMissing: Set<String> = []

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // Poll faster while an undo window is open so "sent" lands on time.
                let busy = !(self?.state.pending.isEmpty ?? true)
                try? await Task.sleep(for: .milliseconds(busy ? 250 : 600))
            }
        }
    }

    func refresh() async {
        do {
            var next = try await Client.local.state()
            let now = Date()
            // Expire closing entries once confirmed and absent from the daemon's
            // list (or past the safety cap).
            let rawPanes = Set(next.agents.map(\.pane))
            for (pane, entry) in closing {
                let stale = now.timeIntervalSince(entry.at) > (entry.confirmed ? 15 : 30)
                if (entry.confirmed && !rawPanes.contains(pane)) || stale {
                    closing[pane] = nil
                    closingPanes.remove(pane)
                }
            }
            if !closing.isEmpty {
                for pane in closing.keys { missing.forget(pane) }
                next.agents.removeAll { closing[$0.pane] != nil }
                next.inbox.removeAll { closing[$0.pane] != nil && $0.kind != "route" }
                next.pending.removeAll { p in p.action.pane.map { closing[$0] != nil } ?? false }
            }
            // Being cleared: gone at once, not back for a poll or two.
            clearing.formIntersection(next.inbox.map(\.id))
            next.inbox.removeAll { clearing.contains($0.id) }
            // Optimistic answers stay visible until reflexd's real pending or
            // cleared inbox reflects them.
            let inboxIDs = Set(next.inbox.map(\.id))
            let pendingItems = Set(next.pending.map(\.item))
            for (id, entry) in answering {
                if !inboxIDs.contains(id) || pendingItems.contains(id) || now.timeIntervalSince(entry.at) > 10 {
                    answering[id] = nil
                } else {
                    next.pending.append(entry.pending)
                }
            }
            holdMissing(&next)
            observe(next)
            state = next
            lastOK = Date()
            if Date().timeIntervalSince(stoppedAt) > 3 { await refreshStopped() }
            // `herdr`: whether your agents can be reached (herdr-core, or herdr).
            // Without herdr-core installed, sessions start in herdr: keep it up.
            if Settings.shared.usesCore && CoreServer.installed { CoreServer.ensure() } else { HerdrServer.ensure(reachable: next.herdr) }
            // Whatever arrives for the session you are looking at, you have seen.
            if let pane = watching() { seen(pane) }
            connected = true
        } catch {
            connected = false
        }
    }

    /// A connected machine that listed agents and now lists none: its agents
    /// as last seen, up to `holdMissing` (then it really has none). Probes
    /// held herdr-core terminals in the background so one intentionally closed
    /// from another Mac or the CLI leaves right away instead of lingering 90 s.
    private func holdMissing(_ next: inout StateInfo) {
        let connected = Set(CoreMachines.known.filter { $0.state == "connected" }.map(\.name))
        let r = missing.apply(next.agents, connected: connected) { $0.machine }
        for (m, n) in r.started {
            NSLog("Reflex: herdr-core's list left out %@'s %d agents (it says connected); kept as they were", m, n)
            let heldPanes = missing.held(on: m).map(\.pane).filter(HerdrCore.isCore)
            if !heldPanes.isEmpty { verifyMissing(heldPanes) }
        }
        next.agents = r.agents
    }

    /// Ask herdr-core directly about held remote panes: if one really ended
    /// (not_found, finished, or back at a plain shell), drop it right away
    /// instead of waiting out MissingHold's 90 s window.
    private func verifyMissing(_ panes: [String]) {
        for pane in panes where probingMissing.insert(pane).inserted {
            Task { [weak self] in
                defer { self?.probingMissing.remove(pane) }
                let gone: Bool
                do {
                    let info = try await HerdrCore.call("terminal.get", ["terminal": pane], timeout: 3)
                    gone = Self.isEndedOrShell(info)
                } catch let err as HerdrCore.Failure where err.kind == "not_found" {
                    gone = true
                } catch {
                    // Timeout / unreachable: genuine slow machine, keep holding.
                    gone = false
                }
                if gone { self?.terminalEnded(pane) }
            }
        }
    }

    /// Mirrors daemon/src/hc.ts: finished, or back at a plain shell with no
    /// OSC 7501 app reported.
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "nu", "login"]
    private static func isEndedOrShell(_ t: [String: Any]) -> Bool {
        if (t["state"] as? String) == "finished" { return true }
        let app = (t["status"] as? [String: Any])?["app"] as? String ?? ""
        guard app.isEmpty else { return false }
        guard let fg = t["foreground"] as? [String: Any],
              let argv = fg["argv"] as? [String], let first = argv.first else { return false }
        var name = (first as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        return shells.contains(name)
    }

    func refreshStopped() async {
        stoppedAt = Date()
        guard let s = try? await Client.local.stopped() else { return }
        leaving.formIntersection(s.map(\.pane))
        let next = s.filter { !leaving.contains($0.pane) && closing[$0.pane] == nil }
        if next != stopped { stopped = next }
    }

    /// Off the list now (resumed or dismissed); the core forgets it shortly.
    func leave(_ pane: String) {
        leaving.insert(pane)
        stopped.removeAll { $0.pane == pane }
    }

    /// Roll back an optimistic `leave` when resuming a stopped agent fails.
    func unleave(_ pane: String) {
        leaving.remove(pane)
        Task { await refreshStopped() }
    }

    func isClosing(_ pane: String) -> Bool { closing[pane] != nil }

    /// Forget a pane from MissingHold without changing the open window (e.g.
    /// HerdrMove closing the old pane while keeping the window for the move).
    func forgetMissing(_ pane: String) {
        missing.forget(pane)
    }

    /// Forget every held agent on a machine that was paused, stopped or removed.
    func forgetMachine(_ machine: String) {
        missing.forgetMachine(machine)
    }

    /// Close a session optimistically: drop it from the UI, MissingHold and its
    /// terminal window immediately, close it in the background, and roll back
    /// only if the close fails while the terminal still exists.
    func close(_ pane: String) {
        closing[pane] = ClosingEntry(at: Date(), confirmed: false)
        closingPanes.insert(pane)
        leaving.insert(pane)
        missing.forget(pane)
        BoatLifetime.shared.forget(pane)
        removePaneLocally(pane)
        AppDelegate.current?.closedSession(pane)
        Task {
            let ok = await Client.local.close(pane)
            if ok {
                if closing[pane] != nil { closing[pane]?.confirmed = true }
            } else {
                closing[pane] = nil
                closingPanes.remove(pane)
                leaving.remove(pane)
            }
            await refresh()
        }
    }

    /// herdr-core confirmed this terminal ended (killed, exited, not_found, or
    /// returned to a plain shell): drop it from MissingHold and the UI now.
    func terminalEnded(_ pane: String) {
        if closing[pane] == nil {
            closing[pane] = ClosingEntry(at: Date(), confirmed: true)
            closingPanes.insert(pane)
        } else {
            closing[pane]?.confirmed = true
        }
        missing.forget(pane)
        BoatLifetime.shared.forget(pane)
        removePaneLocally(pane)
    }

    private func removePaneLocally(_ pane: String) {
        var s = state
        let beforeAgents = s.agents.count, beforeInbox = s.inbox.count, beforePending = s.pending.count
        s.agents.removeAll { $0.pane == pane }
        s.inbox.removeAll { $0.pane == pane && $0.kind != "route" }
        s.pending.removeAll { $0.action.pane == pane }
        if s.agents.count != beforeAgents || s.inbox.count != beforeInbox || s.pending.count != beforePending {
            state = s
        }
        if peek?.pane == pane { peek = nil }
        stopped.removeAll { $0.pane == pane }
    }

    /// Dismiss inbox items optimistically, sending all dismissals concurrently
    /// and rolling back any that fail.
    func dismiss(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        clearing.formUnion(set)
        var s = state
        s.inbox.removeAll { set.contains($0.id) }
        state = s
        if let p = peek, set.contains(p.id) { peek = nil }
        Task {
            let failed: [Int] = await withTaskGroup(of: (Int, Bool).self) { group in
                for id in ids {
                    group.addTask { (id, await Client.local.dismiss(id)) }
                }
                var bad: [Int] = []
                for await (id, ok) in group where !ok { bad.append(id) }
                return bad
            }
            if !failed.isEmpty { clearing.subtract(failed) }
            await refresh()
        }
    }

    /// Answer a question optimistically: disable its buttons and show the
    /// chosen option immediately while the answer goes to reflexd.
    func answer(item: ItemInfo, key: String) {
        guard answering[item.id] == nil, !state.pending.contains(where: { $0.item == item.id }) else { return }
        let opt = item.options.first { $0.key == key }
        let label = "→ " + (opt?.label ?? key)
        let action = opt?.action ?? ActionInfo(type: "press", pane: item.pane, key: key)
        let optimistic = PendingInfo(id: -item.id, label: label, action: action,
                                     due: state.now + state.undo, left: state.undo, item: item.id)
        answering[item.id] = (optimistic, Date())
        var s = state
        s.pending.append(optimistic)
        state = s
        Task {
            let ok = await Client.local.answer(item: item.id, key: key)
            if !ok { answering[item.id] = nil }
            await refresh()
        }
    }

    private func observe(_ next: StateInfo) {
        let ran = Set(next.receipts.filter(\.ok).map(\.id))
        for p in lastPending where !next.pending.contains(where: { $0.id == p.id }) && ran.contains(p.id) {
            if let pane = p.action.pane { pulses[pane, default: 0] += 1 }
        }
        lastPending = next.pending

        let ids = Set(next.inbox.map(\.id))
        // A question already on screen comes back as a new item whenever its
        // choices change, and typing an answer into its free-text row changes
        // them each keystroke. Only a pane's first question in a while, from
        // a session you are not typing in, surfaces at the edge.
        let now = Date(), front = watching()
        let quiet = { (i: ItemInfo) in
            i.pane != front && now.timeIntervalSince(self.askedAt[i.pane] ?? .distantPast) > 10
        }
        defer {
            for i in next.inbox where i.kind == "ask" { askedAt[i.pane] = now }
            askedAt = askedAt.filter { now.timeIntervalSince($0.value) < 60 }
        }
        if let seen = seenItems {
            if let fresh = next.inbox.first(where: { !seen.contains($0.id) && $0.kind == "ask" && quiet($0) }) {
                peek = fresh
                peekClear?.cancel()
                peekClear = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    if !Task.isCancelled { self?.peek = nil }
                }
            }
            seenItems = seen.union(ids)
        } else {
            seenItems = ids
        }
        if let p = peek, !ids.contains(p.id) { peek = nil }
    }

    /// The session whose terminal has the keys, if any (set by the app).
    var watching: () -> String? = { nil }

    private func clears(_ item: ItemInfo, _ pane: String) -> Bool {
        !pane.isEmpty && item.pane == pane && item.kind != "route"
    }

    /// You opened this session: its notifications are read. (Jev's routing
    /// questions are not the session's, and stay.)
    func seen(_ pane: String) {
        let ids = state.inbox.filter { clears($0, pane) }.map(\.id)
        dismiss(ids)
    }
}
