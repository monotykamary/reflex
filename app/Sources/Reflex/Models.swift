import Foundation

// Wire types of reflexd's JSON API (see daemon/Model.bend for the source of truth).

struct AgentInfo: Codable, Identifiable, Hashable {
    var pane: String
    var name: String
    var kind: String
    var status: String
    var cwd: String
    var title: String
    var seq: Int
    var session: String
    var id: String { pane }

    /// The machine it runs on ("" for this Mac; see Machines).
    var machine: String { Machines.machine(of: pane) }
    var remote: Bool { !machine.isEmpty }
    /// "claude · reflex", or "claude · reflex on work" for another Mac's.
    var label: String { "\(kind) · \(folder)" + (remote ? " on \(machine)" : "") }
    var place: String {
        guard !machine.isEmpty else { return cwd.abbreviatingHome }
        // Its own home, not this Mac's: /Users/<anyone>/x reads ~/x there.
        let parts = cwd.split(separator: "/", omittingEmptySubsequences: false)
        let path = parts.count >= 3 && parts[1] == "Users" ? "~" + parts.dropFirst(3).map { "/" + $0 }.joined() : cwd
        return "\(machine): \(path)"
    }
    var folder: String { (cwd as NSString).lastPathComponent }
}

struct ActionInfo: Codable, Hashable {
    var type: String
    var pane: String?
    var cwd: String?
    var kind: String?
    var text: String?
    var key: String?
    /// For "resume": the earlier session's id, and resume / fork / attach.
    var session: String?
    var mode: String?
}

struct OptionInfo: Codable, Hashable, Identifiable {
    var key: String
    var label: String
    var action: ActionInfo
    var id: String { key }
}

struct ItemInfo: Codable, Identifiable, Hashable {
    var id: Int
    var kind: String
    var pane: String
    var agent: String
    var title: String
    var body: String
    var options: [OptionInfo]
    var at: Int
}

struct PendingInfo: Codable, Identifiable, Hashable {
    var id: Int
    var label: String
    var action: ActionInfo
    var due: Int
    var left: Int
    var item: Int
}

struct ReceiptInfo: Codable, Identifiable, Hashable {
    var id: Int
    var label: String
    var ok: Bool
    var detail: String
    var at: Int
}

struct StateInfo: Codable {
    var now: Int
    var undo: Int
    var herdr: Bool
    var folders: Int
    var agents: [AgentInfo]
    var inbox: [ItemInfo]
    var pending: [PendingInfo]
    var receipts: [ReceiptInfo]

    static let empty = StateInfo(now: 0, undo: 2000, herdr: false, folders: 0, agents: [], inbox: [], pending: [], receipts: [])
}

struct RouteInfo: Codable {
    var decision: String
    var label: String?
    var why: String?
    var title: String?
    var error: String?
    var options: [OptionInfo]?
    var action: ActionInfo?
}

struct PostedInfo: Codable {
    var ok: Bool?
    var item: Int?
}

/// One candidate Jev weighed for a request: a session (prompt) or a folder (spawn).
struct RankedInfo: Codable, Hashable {
    var bp: Int
    var label: String
    var action: ActionInfo
}

/// `/api/candidates`: Jev's ranking of every candidate, live and dry.
struct CandidatesResponse: Codable {
    var ok: Bool
    var ms: Int?
    var side: Int?
    var threshold: Int?
    var harness: String?
    var decision: RouteInfo?
    var ranked: [RankedInfo]?
    var error: String?
}

struct RouteResponse: Codable {
    var ok: Bool
    var route: RouteInfo?
    var dispatch: PendingInfo?
    var posted: PostedInfo?
    var error: String?
}

struct PaneResponse: Codable {
    var ok: Bool
    var text: String?
    var error: String?
}

struct FolderInfo: Codable, Identifiable, Hashable {
    var path: String
    var short: String
    var name: String
    var desc: String
    var branch: String
    var ageHours: Int
    var id: String { path }
}

struct FoldersResponse: Codable {
    var ok: Bool
    var folders: [FolderInfo]?
}

extension String {
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}

enum AgentStatus {
    static func symbolColorName(_ status: String) -> String {
        switch status {
        case "working": return "blue"
        case "blocked": return "amber"
        case "done": return "green"
        default: return "grey"
        }
    }
}

extension String {
    /// Daemon labels start with "→ " for plain-text surfaces; glass UI shows an icon instead.
    var bare: String { hasPrefix("→ ") ? String(dropFirst(2)) : self }
}
