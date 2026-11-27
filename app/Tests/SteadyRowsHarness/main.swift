import Foundation
// Stubs: an agent, and the rail's order (waiting, working, done, idle).
struct AgentInfo: Equatable { var pane: String; var status: String; var cwd: String; var parent: String? = nil }
enum Rail {
    @MainActor static func ordered(_ a: [AgentInfo]) -> [AgentInfo] {
        let r = ["blocked": 0, "working": 1, "done": 2]
        return a.enumerated().sorted { (r[$0.element.status] ?? 3, $0.offset) < (r[$1.element.status] ?? 3, $1.offset) }.map(\.element)
    }
}
func a(_ p: String, _ s: String, _ c: String, from: String? = nil) -> AgentInfo { AgentInfo(pane: p, status: s, cwd: c, parent: from) }
let folder: (AgentInfo) -> String = { ($0.cwd as NSString).lastPathComponent }
nonisolated(unsafe) var fails = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { fails += 1 } }
func flat(_ s: SteadyRows) -> [String] { s.groups.flatMap(\.panes) }

MainActor.assumeIsolated {
    let t0 = Date()
    var s = SteadyRows()
    // Opening: x has two agents (a group), y and z one each.
    s.update([a("1", "idle", "/p/x"), a("2", "working", "/p/x"), a("3", "idle", "/p/y"), a("4", "blocked", "/p/z")], folder: folder, now: t0)
    let opened = flat(s)
    check(s.groups.first?.folder == "x" && s.groups.last?.folder == nil, "opens sorted: the group, then the one-agent ones")
    check(opened == ["2", "1", "4", "3"], "opens sorted by state within each part (\(opened))")
    // States change: nothing moves, the rows update.
    s.update([a("1", "blocked", "/p/x"), a("2", "idle", "/p/x"), a("3", "working", "/p/y"), a("4", "idle", "/p/z")], folder: folder, now: t0 + 1)
    check(flat(s) == opened, "a change of state moves no row")
    check(s.info["1"]?.status == "blocked", "the row shows its new state")
    // A poll misses 3: it stays, gone, until the grace runs out.
    s.update([a("1", "blocked", "/p/x"), a("2", "idle", "/p/x"), a("4", "idle", "/p/z")], folder: folder, now: t0 + 2)
    check(flat(s) == opened && s.gone("3"), "a session a poll missed stays, marked gone")
    s.update([a("1", "blocked", "/p/x"), a("2", "idle", "/p/x"), a("3", "working", "/p/y"), a("4", "idle", "/p/z")], folder: folder, now: t0 + 3)
    check(flat(s) == opened && !s.gone("3"), "back on the next poll: in its place, not gone")
    s.update([a("1", "blocked", "/p/x"), a("2", "idle", "/p/x"), a("4", "idle", "/p/z")], folder: folder, now: t0 + 4)
    s.update([a("1", "blocked", "/p/x"), a("2", "idle", "/p/x"), a("4", "idle", "/p/z")], folder: folder, now: t0 + 4 + SteadyRows.grace + 1)
    check(flat(s) == ["2", "1", "4"], "really gone: it goes after the grace")
    // New ones: into their group, else at the end; never above.
    s.update([a("1", "blocked", "/p/x"), a("2", "idle", "/p/x"), a("4", "idle", "/p/z"), a("5", "blocked", "/p/x"), a("6", "blocked", "/p/w")], folder: folder, now: t0 + 20)
    check(flat(s) == ["2", "1", "5", "4", "6"], "new ones join their group's end, or the end (\(flat(s)))")
    // Opening again (a new list) sorts afresh.
    var again = SteadyRows()
    again.update([a("1", "idle", "/p/x"), a("2", "blocked", "/p/x")], folder: folder, now: t0)
    check(flat(again) == ["2", "1"], "a list opened again sorts afresh")

    // Started by another agent: under it, whatever its own state or folder.
    var n = SteadyRows()
    n.update([a("p", "idle", "/p/x"), a("c", "blocked", "/p/x", from: "p"), a("q", "working", "/p/y"),
              a("g", "working", "/p/z", from: "c"), a("o", "done", "/p/w", from: "gone")], folder: folder, now: t0)
    check(flat(n) == ["q", "o", "p", "c", "g"], "children open under their starter, theirs under them (\(flat(n)))")
    check(n.groups.allSatisfy { $0.folder == nil }, "its children don't make a starter's folder a group")
    let shown = Set(flat(n))
    check([n.depth("p", among: shown), n.depth("c", among: shown), n.depth("g", among: shown), n.depth("o", among: shown)] == [0, 1, 2, 0],
          "indented by how many starters are above (a starter not listed: none)")
    check(n.depth("g", among: ["g", "c"]) == 1 && n.depth("c", among: ["c"]) == 0, "a starter filtered out: not indented under it")
    // While open: a new child goes after its starter's earlier ones; a new
    // agent and its child arrive together, the child under it.
    n.update([a("p", "idle", "/p/x"), a("c", "blocked", "/p/x", from: "p"), a("q", "working", "/p/y"),
              a("g", "working", "/p/z", from: "c"), a("o", "done", "/p/w", from: "gone"),
              a("c2", "blocked", "/p/x", from: "p"), a("r2", "idle", "/p/v", from: "r"), a("r", "idle", "/p/v")], folder: folder, now: t0 + 1)
    check(flat(n) == ["q", "o", "p", "c", "g", "c2", "r", "r2"], "new children join under their starter (\(flat(n)))")
    // The starter goes: its children stay where they are, no longer indented.
    let left = [a("c", "blocked", "/p/x", from: "p"), a("q", "working", "/p/y"), a("g", "working", "/p/z", from: "c"),
                a("o", "done", "/p/w", from: "gone"), a("c2", "blocked", "/p/x", from: "p"), a("r2", "idle", "/p/v", from: "r"), a("r", "idle", "/p/v")]
    n.update(left, folder: folder, now: t0 + 2)
    n.update(left, folder: folder, now: t0 + 3 + SteadyRows.grace)
    check(flat(n) == ["q", "o", "c", "g", "c2", "r", "r2"] && n.depth("c", among: Set(flat(n))) == 0 && n.depth("g", among: Set(flat(n))) == 1,
          "a starter gone: its children stay put, a level up (\(flat(n)))")
    // Two that name each other: both listed, neither lost.
    var ring = SteadyRows()
    ring.update([a("x", "idle", "/p/x", from: "y"), a("y", "idle", "/p/y", from: "x")], folder: folder, now: t0)
    check(Set(flat(ring)) == ["x", "y"], "agents naming each other are both listed (\(flat(ring)))")

    // Intentionally closed pane leaves at once (no 6 s dimmed grace), while an
    // unexpectedly missing pane still stays dimmed for the grace period.
    var cl = SteadyRows()
    cl.update([a("1", "idle", "/p/x"), a("2", "working", "/p/x"), a("3", "idle", "/p/y")], folder: folder, now: t0)
    cl.update([a("2", "working", "/p/x")], folder: folder, closed: ["1"], now: t0 + 1)
    check(flat(cl) == ["2", "3"] && !cl.gone("1") && cl.info["1"] == nil && cl.gone("3"),
          "intentionally closed pane leaves immediately; unexpectedly missing stays dimmed (\(flat(cl)))")
    // A pane already dimmed (blip) that is then closed leaves immediately too.
    cl.update([a("2", "working", "/p/x")], folder: folder, closed: ["3"], now: t0 + 2)
    check(flat(cl) == ["2"] && cl.info["3"] == nil, "already-dimmed pane leaves immediately when closed (\(flat(cl)))")
}
exit(fails == 0 ? 0 : 1)
