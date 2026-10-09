import Base
import ./Js.bend as Js
import ./Model.bend as M

# Core: the pure heart of reflexd. `step` folds one message into the state and
# says which dispatches must run now. It performs no IO, so every rule below
# (the undo window, exactly-once dispatch, inbox transitions) is a plain
# function that LAWS.bend can state facts about.

# Small helpers
# -------------

def bool_and(a: Bool, b: Bool) -> Bool:
  match a:
    case True{}:
      b
    case False{}:
      False{}

def bool_not(a: Bool) -> Bool:
  match a:
    case True{}:
      False{}
    case False{}:
      True{}

def is_blocked(s: M.Status) -> Bool:
  match s:
    case M.Blocked{}:
      True{}
    case other:
      False{}

def is_working(s: M.Status) -> Bool:
  match s:
    case M.Working{}:
      True{}
    case other:
      False{}

def is_ready(s: M.Status) -> Bool:
  match s:
    case M.Idle{}:
      True{}
    case M.Finished{}:
      True{}
    case other:
      False{}

def u32_lt(+a: U32, +b: U32) -> Bool:
  U32.is_lt(a, b)

def take(xs: List<&2, M.Item>, n: Nat) -> List<&2, M.Item>:
  match xs n:
    case Nil{} _:
      []
    case Con{h, t} 0n:
      []
    case Con{h, t} 1n+p:
      h <> take(t, p)

def take_receipts(xs: List<&2, M.Receipt>, n: Nat) -> List<&2, M.Receipt>:
  match xs n:
    case Nil{} _:
      []
    case Con{h, t} 0n:
      []
    case Con{h, t} 1n+p:
      h <> take_receipts(t, p)

# The undo window
# ---------------

type Split is Data:
  Split{due: List<&2, M.Dispatch>, rest: List<&2, M.Dispatch>}

def split_put(d: M.Dispatch, ripe: Bool, s: Split) -> Split:
  match ripe s:
    case True{} Split{due, rest}:
      Split{d <> due, rest}
    case False{} Split{due, rest}:
      Split{due, d <> rest}

def Dispatch.ripe(+now: U32, +d: M.Dispatch) -> Bool:
  match d:
    case M.Dispatch{id, action, label, +due, item}:
      U32.is_le(due, now)

# Dispatches whose undo window has passed, and the ones still waiting.
def fire(pending: List<&2, M.Dispatch>, +now: U32) -> Split:
  match pending:
    case Nil{}:
      Split{[], []}
    case Con{+h, t}:
      split_put(h, Dispatch.ripe(now, h), fire(t, now))

def Dispatch.id(d: M.Dispatch) -> U32:
  match d:
    case M.Dispatch{id, action, label, due, item}:
      id

def Dispatch.item(d: M.Dispatch) -> U32:
  match d:
    case M.Dispatch{id, action, label, due, item}:
      item

def keep_dispatch(keep: Bool, d: M.Dispatch, rest: List<&2, M.Dispatch>) -> List<&2, M.Dispatch>:
  match keep:
    case True{}:
      d <> rest
    case False{}:
      rest

# Undo: the pending list without dispatch `id`.
def cancel(pending: List<&2, M.Dispatch>, +id: U32) -> List<&2, M.Dispatch>:
  match pending:
    case Nil{}:
      []
    case Con{+h, t}:
      keep_dispatch(bool_not(U32.is_eq(Dispatch.id(h), id)), h, cancel(t, id))

def has_dispatch(pending: List<&2, M.Dispatch>, +id: U32) -> Bool:
  match pending:
    case Nil{}:
      False{}
    case Con{+h, t}:
      U32.is_eq(Dispatch.id(h), id) || has_dispatch(t, id)

# Inbox items
# -----------

def Item.id(i: M.Item) -> U32:
  match i:
    case M.Item{id, kind, pane, agent, title, body, opts, at}:
      id

def keep_item(keep: Bool, i: M.Item, rest: List<&2, M.Item>) -> List<&2, M.Item>:
  match keep:
    case True{}:
      i <> rest
    case False{}:
      rest

def drop_item(items: List<&2, M.Item>, +id: U32) -> List<&2, M.Item>:
  match items:
    case Nil{}:
      []
    case Con{+h, t}:
      keep_item(bool_not(U32.is_eq(Item.id(h), id)), h, drop_item(t, id))

# Items cleared by a list of dispatches that just ran.
def drop_ran(ran: List<&2, M.Dispatch>, items: List<&2, M.Item>) -> List<&2, M.Item>:
  match ran:
    case Nil{}:
      items
    case Con{+d, t}:
      drop_ran(t, drop_item(items, Dispatch.item(d)))

def pick_item(hit: Bool, h: M.Item, rest: Maybe<&2, M.Item>) -> Maybe<&2, M.Item>:
  match hit:
    case True{}:
      Some{h}
    case False{}:
      rest

def find_item(items: List<&2, M.Item>, +id: U32) -> Maybe<&2, M.Item>:
  match items:
    case Nil{}:
      None{}
    case Con{+h, t}:
      pick_item(U32.is_eq(Item.id(h), id), h, find_item(t, id))

def pick_opt(hit: Bool, h: M.Opt, rest: Maybe<&2, M.Opt>) -> Maybe<&2, M.Opt>:
  match hit:
    case True{}:
      Some{h}
    case False{}:
      rest

def Opt.key(o: M.Opt) -> String:
  match o:
    case M.Opt{key, label, action}:
      key

def find_opt(opts: List<&2, M.Opt>, +key: String) -> Maybe<&2, M.Opt>:
  match opts:
    case Nil{}:
      None{}
    case Con{+h, t}:
      pick_opt(String.eq(Opt.key(h), key), h, find_opt(t, key))

# Reading numbered options off a blocked agent's screen
# ----------------------------------------------------
# A line like "❯ 1. Yes" or "  2) No, and tell Claude" becomes Opt{"2", ...}.

def is_marker(+c: U32) -> Bool:
  U32.is_eq(c, 10095) || U32.is_eq(c, 62) || U32.is_eq(c, 8250) || U32.is_eq(c, 9654) || U32.is_eq(c, 9679)

def strip_marker.if(s: String, t: String, marker: Bool) -> String:
  match marker:
    case True{}:
      String.trim_start(t)
    case False{}:
      s

def strip_marker(+s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{Chr{+c}, t}:
      strip_marker.if(s, t, is_marker(c))

def is_digit19(+c: U32) -> Bool:
  U32.is_le(49, c) && U32.is_le(c, 57)

def is_sep(+c: U32) -> Bool:
  U32.is_eq(c, 46) || U32.is_eq(c, 41)

def opt_of.if(ok: Bool, +d: U32, rest: String, +pane: String) -> Maybe<&2, M.Opt>:
  match ok:
    case True{}:
      Some{M.Opt{SCon{Chr{d}, SNil{}}, String.trim(rest), M.Press{pane, SCon{Chr{d}, SNil{}}}}}
    case False{}:
      None{}

def opt_of(s: String, +pane: String) -> Maybe<&2, M.Opt>:
  match s:
    case SCon{Chr{+d}, SCon{Chr{+p}, SCon{Chr{+sp}, rest}}}:
      opt_of.if(is_digit19(d) && is_sep(p) && U32.is_eq(sp, 32), d, rest, pane)
    case other:
      None{}

def has_key(opts: List<&2, M.Opt>, +key: String) -> Bool:
  match opts:
    case Nil{}:
      False{}
    case Con{+h, t}:
      String.eq(Opt.key(h), key) || has_key(t, key)

def add_opt.if(dup: Bool, o: M.Opt, opts: List<&2, M.Opt>) -> List<&2, M.Opt>:
  match dup:
    case True{}:
      opts
    case False{}:
      List.append(&2, M.Opt, opts, [o])

def add_opt(m: Maybe<&2, M.Opt>, +opts: List<&2, M.Opt>) -> List<&2, M.Opt>:
  match m:
    case None{}:
      opts
    case Some{+o}:
      add_opt.if(has_key(opts, Opt.key(o)), o, opts)

def options_go(lines: List<&2, String>, +pane: String, acc: List<&2, M.Opt>) -> List<&2, M.Opt>:
  match lines:
    case Nil{}:
      acc
    case Con{l, t}:
      options_go(t, pane, add_opt(opt_of(strip_marker(String.trim_start(l)), pane), acc))

def options(screen: String, +pane: String) -> List<&2, M.Opt>:
  options_go(String.lines(screen), pane, [])

# The last n non-empty lines of a screen, for an inbox card.
def nonempty.put(empty: Bool, h: String, rest: List<&2, String>) -> List<&2, String>:
  match empty:
    case True{}:
      rest
    case False{}:
      h <> rest

def nonempty(lines: List<&2, String>) -> List<&2, String>:
  match lines:
    case Nil{}:
      []
    case Con{+h, t}:
      nonempty.put(String.is_empty(String.trim(h)), h, nonempty(t))

def tail_lines(screen: String, n: Nat) -> String:
  String.join(List.reverse(&2, String, List.take(&2, String, List.reverse(&2, String, nonempty(String.lines(screen))), n)), "\n")

# Agent transitions
# -----------------

type Change is Data:
  NoChange{}
  BecameBlocked{}
  FinishedTurn{}

def change.blocked(seen: Bool) -> Change:
  match seen:
    case True{}:
      NoChange{}
    case False{}:
      BecameBlocked{}

def change.finished(was_working: Bool) -> Change:
  match was_working:
    case True{}:
      FinishedTurn{}
    case False{}:
      NoChange{}

def change.of(was_blocked: Bool, was_working: Bool, same_seq: Bool, now_blocked: Bool, now_ready: Bool) -> Change:
  match now_blocked now_ready:
    case True{} _:
      change.blocked(bool_and(was_blocked, same_seq))
    case False{} True{}:
      change.finished(was_working)
    case False{} False{}:
      NoChange{}

def Agent.pane(a: M.Agent) -> String:
  match a:
    case M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}:
      pane

def Agent.status(a: M.Agent) -> M.Status:
  match a:
    case M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}:
      status

def Agent.seq(a: M.Agent) -> U32:
  match a:
    case M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}:
      seq

def pick_agent(hit: Bool, h: M.Agent, rest: Maybe<&2, M.Agent>) -> Maybe<&2, M.Agent>:
  match hit:
    case True{}:
      Some{h}
    case False{}:
      rest

def find_agent(agents: List<&2, M.Agent>, +pane: String) -> Maybe<&2, M.Agent>:
  match agents:
    case Nil{}:
      None{}
    case Con{+h, t}:
      pick_agent(String.eq(Agent.pane(h), pane), h, find_agent(t, pane))

def change(prev: Maybe<&2, M.Agent>, +cur: M.Agent) -> Change:
  match prev:
    case None{}:
      change.of(False{}, False{}, False{}, is_blocked(Agent.status(cur)), False{})
    case Some{+p}:
      change.of(is_blocked(Agent.status(p)), is_working(Agent.status(p)),
        U32.is_eq(Agent.seq(p), Agent.seq(cur)),
        is_blocked(Agent.status(cur)), is_ready(Agent.status(cur)))

def base_name.pick(empty: Bool, h: String, last: String) -> String:
  match empty:
    case True{}:
      last
    case False{}:
      h

def base_name.go(cs: List<&2, String>, last: String) -> String:
  match cs:
    case Nil{}:
      last
    case Con{+h, t}:
      base_name.go(t, base_name.pick(String.is_empty(h), h, last))

def base_name(path: String) -> String:
  base_name.go(String.split(path, '/'), "")

def agent_label(kind: String, cwd: String) -> String:
  kind ++ " · " ++ base_name(cwd)

def item_for(c: Change, +id: U32, +now: U32, a: M.Agent) -> Maybe<&2, M.Item>:
  match c a:
    case NoChange{} _:
      None{}
    case BecameBlocked{} M.Agent{+pane, name, +kind, status, +cwd, title, seq, session, +screen}:
      Some{M.Item{id, M.IAsk{}, pane, agent_label(kind, cwd), "needs you", tail_lines(screen, 14n), options(screen, pane), now}}
    case FinishedTurn{} M.Agent{+pane, name, +kind, status, +cwd, title, seq, session, +screen}:
      Some{M.Item{id, M.IDone{}, pane, agent_label(kind, cwd), "finished", tail_lines(screen, 10n), [], now}}

type Fold is Data:
  Fold{next: U32, items: List<&2, M.Item>}

def fold_put(m: Maybe<&2, M.Item>, f: Fold) -> Fold:
  match m f:
    case None{} _:
      f
    case Some{i} Fold{+next, items}:
      Fold{(next + 1 : U32), i <> items}

def Fold.next(f: Fold) -> U32:
  match f:
    case Fold{next, items}:
      next

# New inbox items for every agent whose state changed since `prev`.
def transitions(cur: List<&2, M.Agent>, +prev: List<&2, M.Agent>, +now: U32, +f: Fold) -> Fold:
  match cur:
    case Nil{}:
      f
    case Con{+a, t}:
      transitions(t, prev, now, fold_put(item_for(change(find_agent(prev, Agent.pane(a)), a), Fold.next(f), now, a), f))

# An Ask card goes once its agent is no longer blocked; a Done card once its
# agent works again or disappears.
def item_live.of(kind: M.Sort, here: Maybe<&2, M.Agent>) -> Bool:
  match kind here:
    case M.IAsk{} None{}:
      False{}
    case M.IAsk{} Some{a}:
      is_blocked(Agent.status(a))
    case M.IDone{} None{}:
      False{}
    case M.IDone{} Some{a}:
      bool_not(is_working(Agent.status(a)))
    case _ _:
      True{}

def item_live(+agents: List<&2, M.Agent>, +i: M.Item) -> Bool:
  match i:
    case M.Item{id, kind, +pane, agent, title, body, opts, at}:
      item_live.of(kind, find_agent(agents, pane))

def prune(items: List<&2, M.Item>, +agents: List<&2, M.Agent>) -> List<&2, M.Item>:
  match items:
    case Nil{}:
      []
    case Con{+h, t}:
      keep_item(item_live(agents, h), h, prune(t, agents))

# step
# ----

def reply(json: String) -> M.Reply:
  M.RText{json}

def ok_reply() -> M.Reply:
  M.RText{"{\"ok\":true}"}

def err_reply(msg: String) -> M.Reply:
  M.RText{Js.obj([Js.kv("ok", "false"), Js.kv("error", Js.str(msg))])}

def on_polled.fold(f: Fold, now: U32, undo: U32, inbox: List<&2, M.Item>, pending: List<&2, M.Dispatch>, receipts: List<&2, M.Receipt>, folders: List<&2, M.Folder>, +agents: List<&2, M.Agent>) -> M.Out:
  match f:
    case Fold{next, fresh}:
      M.Out{M.State{now, next, undo, True{}, agents, take(List.append(&2, M.Item, fresh, prune(inbox, agents)), 60n), pending, receipts, folders}, [], ok_reply()}

def on_polled(s: M.State, ok: Bool, +agents: List<&2, M.Agent>) -> M.Out:
  match s ok:
    case M.State{now, next, undo, herdr, prev, inbox, pending, receipts, folders} False{}:
      M.Out{M.State{now, next, undo, False{}, prev, inbox, pending, receipts, folders}, [], ok_reply()}
    case M.State{+now, next, undo, herdr, +prev, inbox, pending, receipts, folders} True{}:
      on_polled.fold(transitions(agents, prev, now, Fold{next, []}), now, undo, inbox, pending, receipts, folders, agents)

def on_tick.split(sp: Split, now: U32, next: U32, undo: U32, herdr: Bool, agents: List<&2, M.Agent>, inbox: List<&2, M.Item>, receipts: List<&2, M.Receipt>, folders: List<&2, M.Folder>) -> M.Out:
  match sp:
    case Split{+due, rest}:
      M.Out{M.State{now, next, undo, herdr, agents, drop_ran(due, inbox), rest, receipts, folders}, due, ok_reply()}

def on_tick(s: M.State, +now: U32) -> M.Out:
  match s:
    case M.State{old, next, undo, herdr, agents, inbox, pending, receipts, folders}:
      on_tick.split(fire(pending, now), now, next, undo, herdr, agents, inbox, receipts, folders)

def enqueue.with(+d: M.Dispatch, +now: U32, next: U32, undo: U32, herdr: Bool, agents: List<&2, M.Agent>, inbox: List<&2, M.Item>, pending: List<&2, M.Dispatch>, receipts: List<&2, M.Receipt>, folders: List<&2, M.Folder>) -> M.Out:
  M.Out{M.State{now, (next + 1 : U32), undo, herdr, agents, inbox, List.append(&2, M.Dispatch, pending, [d]), receipts, folders}, [], reply(M.Dispatch.json(now, d))}

def enqueue(s: M.State, action: M.Action, label: String, item: U32) -> M.Out:
  match s:
    case M.State{+now, +next, +undo, herdr, agents, inbox, pending, receipts, folders}:
      enqueue.with(M.Dispatch{next, action, label, (now + undo : U32), item}, now, next, undo, herdr, agents, inbox, pending, receipts, folders)

def on_cancel(s: M.State, +id: U32) -> M.Out:
  match s:
    case M.State{now, next, undo, herdr, agents, inbox, +pending, receipts, folders}:
      M.Out{M.State{now, next, undo, herdr, agents, inbox, cancel(pending, id), receipts, folders}, [], reply(Js.obj([Js.kv("ok", "true"), Js.kv("cancelled", Js.bool(has_dispatch(pending, id)))]))}

def on_dismiss(s: M.State, +id: U32) -> M.Out:
  match s:
    case M.State{now, next, undo, herdr, agents, inbox, pending, receipts, folders}:
      M.Out{M.State{now, next, undo, herdr, agents, drop_item(inbox, id), pending, receipts, folders}, [], ok_reply()}

def opt_label(item: M.Item, o: M.Opt) -> String:
  match item o:
    case M.Item{id, kind, pane, agent, title, body, opts, at} M.Opt{key, label, action}:
      agent ++ " ← " ++ key ++ ". " ++ label

def Opt.action(o: M.Opt) -> M.Action:
  match o:
    case M.Opt{key, label, action}:
      action

def on_answer.opt(s: M.State, +item: M.Item, m: Maybe<&2, M.Opt>) -> M.Out:
  match m:
    case None{}:
      M.Out{s, [], err_reply("no such option")}
    case Some{+o}:
      enqueue(s, Opt.action(o), opt_label(item, o), Item.id(item))

def Item.opts(i: M.Item) -> List<&2, M.Opt>:
  match i:
    case M.Item{id, kind, pane, agent, title, body, opts, at}:
      opts

def on_answer.item(s: M.State, m: Maybe<&2, M.Item>, +key: String) -> M.Out:
  match m:
    case None{}:
      M.Out{s, [], err_reply("no such item")}
    case Some{+i}:
      on_answer.opt(s, i, find_opt(Item.opts(i), key))

def State.inbox(s: M.State) -> List<&2, M.Item>:
  match s:
    case M.State{now, next, undo, herdr, agents, inbox, pending, receipts, folders}:
      inbox

def on_answer(+s: M.State, +id: U32, +key: String) -> M.Out:
  on_answer.item(s, find_item(State.inbox(s), id), key)

def on_post(s: M.State, kind: M.Sort, pane: String, agent: String, title: String, body: String, opts: List<&2, M.Opt>) -> M.Out:
  match s:
    case M.State{+now, +next, undo, herdr, agents, inbox, pending, receipts, folders}:
      M.Out{M.State{now, (next + 1 : U32), undo, herdr, agents, take(M.Item{next, kind, pane, agent, title, body, opts, now} <> inbox, 60n), pending, receipts, folders}, [], reply(Js.obj([Js.kv("ok", "true"), Js.kv("item", Js.num(next))]))}

def failure_items(ok: Bool, +id: U32, +now: U32, label: String, detail: String) -> List<&2, M.Item>:
  match ok:
    case True{}:
      []
    case False{}:
      [M.Item{id, M.INote{}, "", "reflex", "failed: " ++ label, detail, [], now}]

def on_receipt(s: M.State, +id: U32, +label: String, +ok: Bool, +detail: String) -> M.Out:
  match s:
    case M.State{+now, +next, undo, herdr, agents, inbox, pending, receipts, folders}:
      M.Out{M.State{now, (next + 1 : U32), undo, herdr, agents, take(List.append(&2, M.Item, failure_items(ok, next, now, label, detail), inbox), 60n), pending, take_receipts(M.Receipt{id, label, ok, detail, now} <> receipts, 30n), folders}, [], ok_reply()}

def on_indexed(s: M.State, fs: List<&2, M.Folder>) -> M.Out:
  match s:
    case M.State{now, next, undo, herdr, agents, inbox, pending, receipts, folders}:
      M.Out{M.State{now, next, undo, herdr, agents, inbox, pending, receipts, fs}, [], ok_reply()}

def on_context(s: M.State) -> M.Out:
  match s:
    case M.State{now, next, undo, herdr, +agents, inbox, pending, receipts, +folders}:
      M.Out{M.State{now, next, undo, herdr, agents, inbox, pending, receipts, folders}, [], M.RContext{agents, folders}}

def on_query(+s: M.State) -> M.Out:
  M.Out{s, [], reply(M.State.json(s))}

def step(s: M.State, m: M.Msg) -> M.Out:
  match m:
    case M.Tick{now}:
      on_tick(s, now)
    case M.Polled{ok, agents}:
      on_polled(s, ok, agents)
    case M.Indexed{folders}:
      on_indexed(s, folders)
    case M.Enqueue{action, label, item}:
      enqueue(s, action, label, item)
    case M.Cancel{id}:
      on_cancel(s, id)
    case M.Answer{item, key}:
      on_answer(s, item, key)
    case M.Dismiss{item}:
      on_dismiss(s, item)
    case M.Post{kind, pane, agent, title, body, opts}:
      on_post(s, kind, pane, agent, title, body, opts)
    case M.Receipted{id, label, ok, detail}:
      on_receipt(s, id, label, ok, detail)
    case M.Query{}:
      on_query(s)
    case M.Context{}:
      on_context(s)

# Observations used by LAWS.bend
# ------------------------------

def Split.due(s: Split) -> List<&2, M.Dispatch>:
  match s:
    case Split{due, rest}:
      due

def Split.rest(s: Split) -> List<&2, M.Dispatch>:
  match s:
    case Split{due, rest}:
      rest

def all_ripe(+now: U32, ds: List<&2, M.Dispatch>) -> Bool:
  match ds:
    case Nil{}:
      True{}
    case Con{+d, t}:
      Dispatch.ripe(now, d) && all_ripe(now, t)

def none_ripe(+now: U32, ds: List<&2, M.Dispatch>) -> Bool:
  match ds:
    case Nil{}:
      True{}
    case Con{+d, t}:
      bool_not(Dispatch.ripe(now, d)) && none_ripe(now, t)

def Out.run(o: M.Out) -> List<&2, M.Dispatch>:
  match o:
    case M.Out{state, run, reply}:
      run

def Out.pending(o: M.Out) -> List<&2, M.Dispatch>:
  match o:
    case M.Out{M.State{now, next, undo, herdr, agents, inbox, pending, receipts, folders}, run, reply}:
      pending
