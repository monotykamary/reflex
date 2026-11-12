import Foundation
// The real MissingHold (app/Sources/Reflex/MissingHold.swift) with a stub agent.
struct AgentInfo: Equatable { var pane: String }
let machine: (AgentInfo) -> String = { a in a.pane.contains("/") ? String(a.pane.split(separator: "/")[0]) : "" }
func a(_ p: String) -> AgentInfo { AgentInfo(pane: p) }
nonisolated(unsafe) var fails = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { fails += 1 } }
func panes(_ xs: [AgentInfo]) -> Set<String> { Set(xs.map(\.pane)) }

let t0 = Date()
let up: Set<String> = ["boat"]
var h = MissingHold()
let all = [a("t1"), a("boat/t1"), a("boat/t2")]
_ = h.apply(all, connected: up, now: t0, machine: machine)
// A slow answer: boat listed nothing while connected.
var r = h.apply([a("t1")], connected: up, now: t0 + 2, machine: machine)
check(panes(r.agents) == panes(all), "a connected machine listing none keeps its agents")
check(r.started["boat"] == 2, "the gap is reported once, with its count")
r = h.apply([a("t1")], connected: up, now: t0 + 30, machine: machine)
check(panes(r.agents) == panes(all) && r.started.isEmpty, "still kept 30 s on, not reported again")
// Back: the list's own agents, and the next gap is timed afresh.
r = h.apply([a("t1"), a("boat/t1")], connected: up, now: t0 + 40, machine: machine)
check(panes(r.agents) == ["t1", "boat/t1"], "listed again: as listed (boat/t2 really ended)")
r = h.apply([a("t1")], connected: up, now: t0 + 200, machine: machine)
check(panes(r.agents) == ["t1", "boat/t1"], "a later gap is timed from its own start")
// Past the limit: it really has none.
r = h.apply([a("t1")], connected: up, now: t0 + 200 + MissingHold.limit + 1, machine: machine)
check(panes(r.agents) == ["t1"], "past the limit the machine's agents go")
r = h.apply([a("t1")], connected: up, now: t0 + 400, machine: machine)
check(panes(r.agents) == ["t1"], "and stay gone")
// Not connected: nothing held (the daemon keeps a down machine's itself).
var d = MissingHold()
_ = d.apply(all, connected: up, now: t0, machine: machine)
r = d.apply([a("t1")], connected: [], now: t0 + 2, machine: machine)
check(panes(r.agents) == ["t1"], "a machine not connected isn't held here")
// This Mac's agents are never held.
var l = MissingHold()
_ = l.apply(all, connected: up, now: t0, machine: machine)
r = l.apply([a("boat/t1"), a("boat/t2")], connected: up, now: t0 + 2, machine: machine)
check(panes(r.agents) == ["boat/t1", "boat/t2"], "this Mac's agents are never held")
exit(fails == 0 ? 0 : 1)
