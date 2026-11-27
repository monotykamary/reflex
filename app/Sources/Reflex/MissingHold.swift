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

    /// Explicitly drop a pane (closed intentionally or confirmed ended by
    /// herdr-core), so a connected machine that now lists no agents doesn't
    /// keep it alive for `limit` seconds as a phantom.
    mutating func forget(_ pane: String) {
        for m in Array(lastOn.keys) {
            guard var xs = lastOn[m], xs.contains(where: { $0.pane == pane }) else { continue }
            xs.removeAll { $0.pane == pane }
            if xs.isEmpty {
                lastOn[m] = nil
                missingSince[m] = nil
            } else {
                lastOn[m] = xs
            }
        }
    }

    /// Explicitly drop a machine (paused, turned off, or removed).
    mutating func forgetMachine(_ m: String) {
        lastOn[m] = nil
        missingSince[m] = nil
    }

    /// The agents currently held for a machine, if any.
    func held(on m: String) -> [AgentInfo] { lastOn[m] ?? [] }

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
