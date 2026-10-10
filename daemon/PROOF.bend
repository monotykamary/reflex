import Base
import ./Model.bend as M
import ./Core.bend as Core
import ./Route.bend as R
import ./Past.bend as P
import ./Index.bend as Ix
import ./LAWS.bend as Laws

# Proofs of LAWS.bend. Run `bend PROOF.bend` (or --verdict for the kernel).

# The undo window
# ---------------

# One step of `fire`: putting h into a split preserves "every due is ripe".
def fired_step(now: U32, h: M.Dispatch, b: Bool, sp: Core.Split) -> {Core.Dispatch.ripe(now, h) == b : Bool} -> {Core.all_ripe(now, Core.Split.due(sp)) == True{} : Bool} -> {Core.all_ripe(now, Core.Split.due(Core.split_put(h, b, sp))) == True{} : Bool}:
  match b sp:
    case True{} Core.Split{due, rest}:
      e => ih =>
        %Equal.sym(Bool, Core.Dispatch.ripe(now, h), True{}, e) : {Bool.and(_, Core.all_ripe(now, due)) == True{} : Bool}
        ih
    case False{} Core.Split{due, rest}:
      e => ih => ih

def Laws.fired_are_ripe(ps, now):
  match ps:
    case Nil{}:
      {==}
    case Con{+h, t}:
      fired_step(now, h, Core.Dispatch.ripe(now, h), Core.fire(t, now), {==}, Laws.fired_are_ripe(t, now))

def kept_step(now: U32, h: M.Dispatch, b: Bool, sp: Core.Split) -> {Core.Dispatch.ripe(now, h) == b : Bool} -> {Core.none_ripe(now, Core.Split.rest(sp)) == True{} : Bool} -> {Core.none_ripe(now, Core.Split.rest(Core.split_put(h, b, sp))) == True{} : Bool}:
  match b sp:
    case True{} Core.Split{due, rest}:
      e => ih => ih
    case False{} Core.Split{due, rest}:
      e => ih =>
        %Equal.sym(Bool, Core.Dispatch.ripe(now, h), False{}, e) : {Bool.and(Core.bool_not(_), Core.none_ripe(now, rest)) == True{} : Bool}
        ih

def Laws.kept_are_unripe(ps, now):
  match ps:
    case Nil{}:
      {==}
    case Con{+h, t}:
      kept_step(now, h, Core.Dispatch.ripe(now, h), Core.fire(t, now), {==}, Laws.kept_are_unripe(t, now))

# n + (1 + m) == 1 + (n + m)
def add_succ(n: Nat, m: Nat) -> {Nat.add(n, 1n+m) == 1n+Nat.add(n, m) : Nat}:
  match n:
    case 0n:
      {==}
    case 1n+p:
      %Equal.sym(Nat, Nat.add(p, 1n+m), 1n+Nat.add(p, m), add_succ(p, m)) : {1n+_ == 1n+1n+Nat.add(p, m) : Nat}
      {==}

def len(xs: List<&2, M.Dispatch>) -> Nat:
  List.length(&2, M.Dispatch, xs)

def part_step(h: M.Dispatch, b: Bool, sp: Core.Split, n: Nat) -> {Nat.add(len(Core.Split.due(sp)), len(Core.Split.rest(sp))) == n : Nat} -> {Nat.add(len(Core.Split.due(Core.split_put(h, b, sp))), len(Core.Split.rest(Core.split_put(h, b, sp)))) == 1n+n : Nat}:
  match b sp:
    case True{} Core.Split{due, rest}:
      ih =>
        %Equal.sym(Nat, Nat.add(len(due), len(rest)), n, ih) : {1n+_ == 1n+n : Nat}
        {==}
    case False{} Core.Split{due, rest}:
      ih =>
        %Equal.sym(Nat, Nat.add(len(due), 1n+len(rest)), 1n+Nat.add(len(due), len(rest)), add_succ(len(due), len(rest))) : {_ == 1n+n : Nat}
        %Equal.sym(Nat, Nat.add(len(due), len(rest)), n, ih) : {1n+_ == 1n+n : Nat}
        {==}

def Laws.fire_partitions(ps, now):
  match ps:
    case Nil{}:
      {==}
    case Con{+h, t}:
      part_step(h, Core.Dispatch.ripe(now, h), Core.fire(t, now), len(t), Laws.fire_partitions(t, now))

def cancel_step(h: M.Dispatch, id: U32, b: Bool, rest: List<&2, M.Dispatch>) -> {U32.is_eq(Core.Dispatch.id(h), id) == b : Bool} -> {Core.has_dispatch(rest, id) == False{} : Bool} -> {Core.has_dispatch(Core.keep_dispatch(Core.bool_not(b), h, rest), id) == False{} : Bool}:
  match b:
    case True{}:
      e => ih => ih
    case False{}:
      e => ih =>
        %Equal.sym(Bool, U32.is_eq(Core.Dispatch.id(h), id), False{}, e) : {Bool.or(_, Core.has_dispatch(rest, id)) == False{} : Bool}
        ih

def Laws.cancel_removes(ps, id):
  match ps:
    case Nil{}:
      {==}
    case Con{+h, t}:
      cancel_step(h, id, U32.is_eq(Core.Dispatch.id(h), id), Core.cancel(t, id), {==}, Laws.cancel_removes(t, id))

def tick_run(sp: Core.Split, now: U32, next: U32, undo: U32, herdr: Bool, agents: List<&2, M.Agent>, inbox: List<&2, M.Item>, receipts: List<&2, M.Receipt>, folders: List<&2, M.Folder>) -> {Core.Out.run(Core.on_tick.split(sp, now, next, undo, herdr, agents, inbox, receipts, folders)) == Core.Split.due(sp) : List<&2, M.Dispatch>}:
  match sp:
    case Core.Split{due, rest}:
      {==}

def Laws.tick_runs_ripe(now0, next, undo, herdr, agents, inbox, pending, receipts, folders, now):
  tick_run(Core.fire(pending, now), now, next, undo, herdr, agents, inbox, receipts, folders)

def tick_keep(sp: Core.Split, now: U32, next: U32, undo: U32, herdr: Bool, agents: List<&2, M.Agent>, inbox: List<&2, M.Item>, receipts: List<&2, M.Receipt>, folders: List<&2, M.Folder>) -> {Core.Out.pending(Core.on_tick.split(sp, now, next, undo, herdr, agents, inbox, receipts, folders)) == Core.Split.rest(sp) : List<&2, M.Dispatch>}:
  match sp:
    case Core.Split{due, rest}:
      {==}

def Laws.tick_keeps_unripe(now0, next, undo, herdr, agents, inbox, pending, receipts, folders, now):
  tick_keep(Core.fire(pending, now), now, next, undo, herdr, agents, inbox, receipts, folders)

def Laws.enqueue_runs_nothing(s, action, label, item):
  match s:
    case M.State{now, next, undo, herdr, agents, inbox, pending, receipts, folders}:
      {==}

def answer_opt(+s: M.State, +item: M.Item, m: Maybe<&2, M.Opt>) -> {Core.Out.run(Core.on_answer.opt(s, item, m)) == [] : List<&2, M.Dispatch>}:
  match m:
    case None{}:
      {==}
    case Some{+o}:
      Laws.enqueue_runs_nothing(s, Core.Opt.action(o), Core.opt_label(item, o), Core.Item.id(item))

def answer_item(+s: M.State, m: Maybe<&2, M.Item>, +key: String) -> {Core.Out.run(Core.on_answer.item(s, m, key)) == [] : List<&2, M.Dispatch>}:
  match m:
    case None{}:
      {==}
    case Some{+i}:
      answer_opt(s, i, Core.find_opt(Core.Item.opts(i), key))

def Laws.answer_runs_nothing(s, item, key):
  answer_item(s, Core.find_item(Core.State.inbox(s), item), key)

# The inbox
# ---------

def Laws.new_blocked_agent_asks(pane, name, kind, cwd, title, seq, session, screen):
  {==}

def Laws.finished_turn_reports(p, pane, name, kind, cwd, title, seq, session, screen):
  {==}

def Laws.answered_question_clears(pane, name, kind, cwd, title, seq, session, screen):
  {==}

# Routing
# -------

def Laws.unsure_target_never_acts(is_new, agent, text, home, default, threshold, seen, folders, target, folder, side):
  {==}

def Laws.unsure_folder_never_acts(m, text, home, default, seen, folders, target, folder):
  {==}

def Laws.unsure_resume_changes_nothing(key, pasts, d, text):
  {==}

def Laws.live_session_beats_resume(m, d, text):
  {==}

def side_tag(s: R.Side) -> Type:
  match s:
    case R.Native{}:
      Empty
    case R.Forked{}:
      Unit
    case R.NoSide{}:
      Unit

def blocked_side(c: Bool, p: Bool) -> {R.side_for.of(c, p, True{}) != R.Native{} : R.Side}:
  match c p:
    case True{} _:
      e =>
        %e : side_tag(_)
        Unit{}
    case False{} True{}:
      e =>
        %e : side_tag(_)
        Unit{}
    case False{} False{}:
      e =>
        %e : side_tag(_)
        Unit{}

def Laws.blocked_agent_gets_no_native_btw(kind):
  blocked_side(String.eq(kind, "claude"), String.eq(kind, "pi"))

def take_bounded(xs: List<&2, M.Folder>, k: Nat) -> {Nat.is_le(List.length(&2, M.Folder, Ix.take(xs, k)), k) == True{} : Bool}:
  match xs k:
    case Nil{} 0n:
      {==}
    case Nil{} 1n+p:
      {==}
    case Con{+h, t} 0n:
      {==}
    case Con{+h, t} 1n+p:
      take_bounded(t, p)

def parts_bounded(p: Ix.Parts, k: Nat) -> {Nat.is_le(List.length(&2, M.Folder, Ix.rank.parts(p, k)), k) == True{} : Bool}:
  match p:
    case Ix.Parts{pinned, matched, others}:
      take_bounded(List.append(&2, M.Folder, Ix.folders_of(pinned), List.append(&2, M.Folder, Ix.folders_of(List.sort(~Ix.Scored, ~Ix.scored_le, matched)), Ix.folders_of(List.sort(~Ix.Scored, ~Ix.by_age_le, others)))), k)

def Laws.rank_is_bounded(text, fs, k):
  parts_bounded(Ix.partition(Ix.tokens(text), Ix.scored_all(Ix.tokens(text), fs)), k)
