import Foundation
// Stubs: an agent, and the rail's order (waiting, working, done, idle).
struct AgentInfo: Equatable { var pane: String; var status: String; var cwd: String }
enum Rail {
    @MainActor static func ordered(_ a: [AgentInfo]) -> [AgentInfo] {
        let r = ["blocked": 0, "working": 1, "done": 2]
        return a.enumerated().sorted { (r[$0.element.status] ?? 3, $0.offset) < (r[$1.element.status] ?? 3, $1.offset) }.map(\.element)
    }
}
func a(_ p: String, _ s: String, _ c: String) -> AgentInfo { AgentInfo(pane: p, status: s, cwd: c) }
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
}
exit(fails == 0 ? 0 : 1)
