import Foundation

/// herdr-core's list leaves out a machine whose answer is slow (a few
/// seconds: a busy sandbox) while still calling it connected. Its agents
/// would vanish for a poll or a few, though their terminals stream on, and
/// the machine would look idle (its hour not renewed). A connected machine
/// that listed agents and now lists none keeps them as last seen, up to
/// `limit`; past that it really has none.
struct MissingHold {
    static let limit: TimeInterval = 90

    private var lastOn: [String: [AgentInfo]] = [:]
    private(set) var missingSince: [String: Date] = [:]

    /// The agents to show: `agents` plus those held. `machine` is an agent's
    /// machine ("" for this Mac's, never held).
    mutating func apply(_ agents: [AgentInfo], connected: Set<String>, now: Date = Date(),
                        machine: (AgentInfo) -> String) -> (agents: [AgentInfo], started: [String: Int]) {
        var out = agents
        var started: [String: Int] = [:]
        var listed: [String: [AgentInfo]] = [:]
        for a in agents {
            let m = machine(a)
            if !m.isEmpty { listed[m, default: []].append(a) }
        }
        // Listed: not missing (the next gap is timed from its start).
        for m in listed.keys { missingSince[m] = nil }
        var kept = listed
        for (m, was) in lastOn where listed[m] == nil && !was.isEmpty && connected.contains(m) {
            if missingSince[m] == nil {
                missingSince[m] = now
                started[m] = was.count
            }
            guard now.timeIntervalSince(missingSince[m] ?? now) < Self.limit else { continue }
            out += was
            kept[m] = was
        }
        lastOn = kept
        return (out, started)
    }
}
