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
    func candidates(_ text: String, harness: String?) async throws -> CandidatesResponse {
        var body: [String: Any] = ["text": text, "memory": await Memory.shared.context(for: text)]
        if let harness { body["harness"] = harness }
        return try await post("/api/candidates", body, as: CandidatesResponse.self)
    }

    func send(pane: String, text: String, label: String) async throws -> PendingInfo {
        try await post("/api/send", ["pane": pane, "text": text, "label": label], as: PendingInfo.self)
    }

    func side(pane: String, text: String) async throws -> RouteResponse {
        try await post("/api/side", ["pane": pane, "text": text], as: RouteResponse.self)
    }

    func spawn(cwd: String, kind: String, text: String) async throws -> PendingInfo {
        try await post("/api/spawn", ["cwd": cwd, "kind": kind, "text": text], as: PendingInfo.self)
    }

    func answer(item: Int, key: String) async { await post("/api/answer", ["item": item, "key": key]) }
    func dismiss(_ item: Int) async { await post("/api/dismiss", ["item": item]) }
    func note(pane: String, agent: String, title: String, body: String) async {
        await post("/api/note", ["pane": pane, "agent": agent, "title": title, "body": body])
    }
    func focus(_ pane: String) async { await post("/api/focus", ["pane": pane]) }
    /// Bring an earlier session back in a new herdr workspace (resume, fork
    /// or attach), then submit `text` there if it is not empty.
    func resume(_ p: PastSession, mode: String, text: String) async throws -> PendingInfo {
        try await post("/api/resume", ["cwd": p.cwd, "kind": p.agent, "session": p.id, "mode": mode, "text": text,
                                       "label": "\(p.agent) · \(p.title.prefix(40))"], as: PendingInfo.self)
    }

    /// Ends the session: herdr closes the pane and the agent in it.
    func close(_ pane: String) async { await post("/api/close", ["pane": pane]) }
    func reindex() async { await post("/api/reindex", [:]) }

    func pane(_ id: String, lines: Int = 160) async -> String {
        let q = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        let r = try? await get("/api/pane?id=\(q)&lines=\(lines)", as: PaneResponse.self)
        return r?.text ?? r?.error ?? ""
    }

    func folders(_ q: String) async -> [FolderInfo] {
        let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return (try? await get("/api/folders?q=\(e)", as: FoldersResponse.self))?.folders ?? []
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var state = StateInfo.empty
    @Published private(set) var connected = false
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
            // Being cleared: gone at once, not back for a poll or two.
            clearing.formIntersection(next.inbox.map(\.id))
            next.inbox.removeAll { clearing.contains($0.id) }
            observe(next)
            state = next
            HerdrServer.ensure(reachable: next.herdr)
            // Whatever arrives for the session you are looking at, you have seen.
            if let pane = watching() { seen(pane) }
            connected = true
        } catch {
            connected = false
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
        guard !ids.isEmpty else { return }
        clearing.formUnion(ids)
        var s = state
        s.inbox.removeAll { ids.contains($0.id) }
        state = s
        Task {
            for id in ids { await Client.local.dismiss(id) }
            await refresh()
        }
    }
}
