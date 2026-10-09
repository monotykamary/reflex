import Base
import ./Model.bend as M
import ./Core.bend as Core
import ./Route.bend as R
import ./Index.bend as Ix

# The laws reflexd's pure core must satisfy. PROOF.bend proves each one;
# `bend PROOF.bend` prints ALL PROOFS CHECK only when every law holds.
# These concern the policy the IO shell (main.bend) executes; Herdr, Jev, the
# harnesses and Bend's runtime are assumptions, not proven here.

# The undo window
# ---------------

# Nothing leaves the undo window early: every dispatch `fire` releases is ripe.
law fired_are_ripe:
  for +ps: List<&2, M.Dispatch>
  for +now: U32
  {Core.all_ripe(now, Core.Split.due(Core.fire(ps, now))) == True{} : Bool}

# Nothing ripe is left waiting: every dispatch `fire` keeps is still unripe.
law kept_are_unripe:
  for +ps: List<&2, M.Dispatch>
  for +now: U32
  {Core.none_ripe(now, Core.Split.rest(Core.fire(ps, now))) == True{} : Bool}

# `fire` neither loses nor duplicates a dispatch.
law fire_partitions:
  for +ps: List<&2, M.Dispatch>
  for +now: U32
  {Nat.add(List.length(&2, M.Dispatch, Core.Split.due(Core.fire(ps, now))), List.length(&2, M.Dispatch, Core.Split.rest(Core.fire(ps, now)))) == List.length(&2, M.Dispatch, ps) : Nat}

# Undo works: a cancelled dispatch is no longer pending, so it can never run.
law cancel_removes:
  for +ps: List<&2, M.Dispatch>
  for +id: U32
  {Core.has_dispatch(Core.cancel(ps, id), id) == False{} : Bool}

# A tick runs exactly the ripe dispatches, and keeps exactly the rest pending.
law tick_runs_ripe:
  for +now0: U32
  for +next: U32
  for +undo: U32
  for +herdr: Bool
  for +agents: List<&2, M.Agent>
  for +inbox: List<&2, M.Item>
  for +pending: List<&2, M.Dispatch>
  for +receipts: List<&2, M.Receipt>
  for +folders: List<&2, M.Folder>
  for +now: U32
  {Core.Out.run(Core.step(M.State{now0, next, undo, herdr, agents, inbox, pending, receipts, folders}, M.Tick{now})) == Core.Split.due(Core.fire(pending, now)) : List<&2, M.Dispatch>}

law tick_keeps_unripe:
  for +now0: U32
  for +next: U32
  for +undo: U32
  for +herdr: Bool
  for +agents: List<&2, M.Agent>
  for +inbox: List<&2, M.Item>
  for +pending: List<&2, M.Dispatch>
  for +receipts: List<&2, M.Receipt>
  for +folders: List<&2, M.Folder>
  for +now: U32
  {Core.Out.pending(Core.step(M.State{now0, next, undo, herdr, agents, inbox, pending, receipts, folders}, M.Tick{now})) == Core.Split.rest(Core.fire(pending, now)) : List<&2, M.Dispatch>}

# Only ticks run anything: every other message runs nothing.
law enqueue_runs_nothing:
  for +s: M.State
  for +action: M.Action
  for +label: String
  for +item: U32
  {Core.Out.run(Core.step(s, M.Enqueue{action, label, item})) == [] : List<&2, M.Dispatch>}

law answer_runs_nothing:
  for +s: M.State
  for +item: U32
  for +key: String
  {Core.Out.run(Core.step(s, M.Answer{item, key})) == [] : List<&2, M.Dispatch>}

# The inbox
# ---------

# A newly seen agent that is blocked asks you.
law new_blocked_agent_asks:
  for +pane: String
  for +name: String
  for +kind: String
  for +cwd: String
  for +title: String
  for +seq: U32
  for +session: String
  for +screen: String
  {Core.change(None{}, M.Agent{pane, name, kind, M.Blocked{}, cwd, title, seq, session, screen}) == Core.BecameBlocked{} : Core.Change}

# A working agent that becomes ready reports a finished turn.
law finished_turn_reports:
  for +p: M.Agent
  for +pane: String
  for +name: String
  for +kind: String
  for +cwd: String
  for +title: String
  for +seq: U32
  for +session: String
  for +screen: String
  {Core.change(Some{M.Agent{pane, name, kind, M.Working{}, cwd, title, seq, session, screen}}, M.Agent{pane, name, kind, M.Idle{}, cwd, title, seq, session, screen}) == Core.FinishedTurn{} : Core.Change}

# A question card goes away once its agent is no longer blocked.
law answered_question_clears:
  for +pane: String
  for +name: String
  for +kind: String
  for +cwd: String
  for +title: String
  for +seq: U32
  for +session: String
  for +screen: String
  {Core.item_live.of(M.IAsk{}, Some{M.Agent{pane, name, kind, M.Working{}, cwd, title, seq, session, screen}}) == False{} : Bool}

# Routing
# -------

# Jev never acts on a session choice below the confidence threshold.
law unsure_target_never_acts:
  for +is_new: Bool
  for +agent: Maybe<&2, M.Agent>
  for +text: String
  for +home: String
  for +default: String
  for +threshold: U32
  for +seen: List<&2, R.Seen>
  for +folders: List<&2, M.Folder>
  for +target: Maybe<&2, R.Pick>
  for +folder: Maybe<&2, R.Pick>
  for +side: U32
  {R.is_go(R.decide.target(False{}, is_new, agent, text, home, default, threshold, seen, folders, target, folder, side)) == False{} : Bool}

# ...nor on a folder choice below the confidence threshold.
law unsure_folder_never_acts:
  for +m: Maybe<&2, M.Folder>
  for +text: String
  for +home: String
  for +default: String
  for +seen: List<&2, R.Seen>
  for +folders: List<&2, M.Folder>
  for +target: Maybe<&2, R.Pick>
  for +folder: Maybe<&2, R.Pick>
  {R.is_go(R.decide.folder.pick(False{}, m, text, home, default, seen, folders, target, folder)) == False{} : Bool}

# A side question never types into a blocked agent's TUI, whatever the harness.
law blocked_agent_gets_no_native_btw:
  for +kind: String
  {R.side_for(kind, M.Blocked{}) != R.Native{} : R.Side}

# Jev is offered at most k folders.
law rank_is_bounded:
  for +text: String
  for +fs: List<&2, M.Folder>
  for +k: Nat
  {Nat.is_le(List.length(&2, M.Folder, Ix.rank(text, fs, k)), k) == True{} : Bool}
