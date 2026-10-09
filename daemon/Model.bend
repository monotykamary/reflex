import Base
import ./Js.bend as Js

# Domain model of reflexd. Everything here is plain data: the daemon's state,
# the events that change it and the actions it may perform. Core.step is the
# only function that changes a State.

# An agent's lifecycle state, as Herdr reports it ("done" is Finished here).
type Status is Data:
  Idle{}
  Working{}
  Blocked{}
  Finished{}
  Unknown{}

# A coding agent living in a Herdr pane.
type Agent is Data:
  Agent{
    pane: String,
    name: String,
    kind: String,
    status: Status,
    cwd: String,
    title: String,
    seq: U32,
    session: String,
    screen: String,
  }

# A folder where a new session may start (built by Index from the scan).
type Folder is Data:
  Folder{
    path: String,
    name: String,
    desc: String,
    recent: String,
    branch: String,
    age: U32,
    uses: U32,
  }

# What reflexd can do to the world. Every action goes through the undo window.
type Action is Data:
  # submit a prompt to an existing agent (herdr agent.prompt)
  Prompt{pane: String, text: String}
  # open a workspace in cwd, start a harness there, then prompt it
  Spawn{cwd: String, kind: String, text: String}
  # press one key in an agent's pane, e.g. "1" to answer a numbered question
  Press{pane: String, key: String}
  # the harness's own side-question command, typed into its TUI (/btw)
  SideNative{pane: String, text: String}
  # fork the agent's session headlessly and ask there; the reply comes back
  # as an inbox item and the original agent is never touched
  SideFork{pane: String, kind: String, cwd: String, session: String, text: String}

# One answer an inbox item offers (pressed as 1, 2, 3...).
type Opt is Data:
  Opt{key: String, label: String, action: Action}

type Sort is Data:
  # an agent is blocked on a question or approval
  IAsk{}
  # an agent finished a turn
  IDone{}
  # an answer to a side question
  IReply{}
  # routing was not confident: pick where the request goes
  IRoute{}
  # something reflexd wants you to know (an error, a receipt)
  INote{}

type Item is Data:
  Item{
    id: U32,
    kind: Sort,
    pane: String,
    agent: String,
    title: String,
    body: String,
    opts: List<&2, Opt>,
    at: U32,
  }

# An action waiting out its undo window.
type Dispatch is Data:
  Dispatch{id: U32, action: Action, label: String, due: U32, item: U32}

# What happened to a dispatch once it ran.
type Receipt is Data:
  Receipt{id: U32, label: String, ok: Bool, detail: String, at: U32}

type State is Data:
  State{
    now: U32,
    next: U32,
    undo: U32,
    herdr: Bool,
    agents: List<&2, Agent>,
    inbox: List<&2, Item>,
    pending: List<&2, Dispatch>,
    receipts: List<&2, Receipt>,
    folders: List<&2, Folder>,
  }

type Msg is Data:
  # the clock moved (ms since the daemon started)
  Tick{now: U32}
  # a fresh view of Herdr's agents (ok = Herdr answered)
  Polled{ok: Bool, agents: List<&2, Agent>}
  # the folder index was (re)built
  Indexed{folders: List<&2, Folder>}
  # schedule an action after the undo window; `item` is resolved when it runs
  Enqueue{action: Action, label: String, item: U32}
  # undo a pending action
  Cancel{id: U32}
  # answer an inbox item with one of its options
  Answer{item: U32, key: String}
  # clear an inbox item
  Dismiss{item: U32}
  # add an inbox item
  Post{kind: Sort, pane: String, agent: String, title: String, body: String, opts: List<&2, Opt>}
  # a dispatch finished running
  Receipted{id: U32, label: String, ok: Bool, detail: String}
  # read the state as JSON
  Query{}
  # read what routing needs
  Context{}

type Reply is Data:
  RText{json: String}
  RContext{agents: List<&2, Agent>, folders: List<&2, Folder>}

type Out is Data:
  Out{state: State, run: List<&2, Dispatch>, reply: Reply}

def State.empty(+undo: U32) -> State:
  State{0, 1, undo, False{}, [], [], [], [], []}

# Status text
# -----------

def Status.pick(idle: Bool, working: Bool, blocked: Bool, done: Bool) -> Status:
  match idle working blocked done:
    case True{} _ _ _:
      Idle{}
    case _ True{} _ _:
      Working{}
    case _ _ True{} _:
      Blocked{}
    case _ _ _ True{}:
      Finished{}
    case _ _ _ _:
      Unknown{}

def Status.read(+s: String) -> Status:
  Status.pick(String.eq(s, "idle"), String.eq(s, "working"), String.eq(s, "blocked"), String.eq(s, "done"))

def Status.show(s: Status) -> String:
  match s:
    case Idle{}:
      "idle"
    case Working{}:
      "working"
    case Blocked{}:
      "blocked"
    case Finished{}:
      "done"
    case Unknown{}:
      "unknown"

def Sort.show(k: Sort) -> String:
  match k:
    case IAsk{}:
      "ask"
    case IDone{}:
      "ready"
    case IReply{}:
      "reply"
    case IRoute{}:
      "route"
    case INote{}:
      "note"

# JSON rendering
# --------------

def Action.json(a: Action) -> String:
  match a:
    case Prompt{pane, text}:
      Js.obj([Js.kv("type", Js.str("prompt")), Js.kv("pane", Js.str(pane)), Js.kv("text", Js.str(text))])
    case Spawn{cwd, kind, text}:
      Js.obj([Js.kv("type", Js.str("spawn")), Js.kv("cwd", Js.str(cwd)), Js.kv("kind", Js.str(kind)), Js.kv("text", Js.str(text))])
    case Press{pane, key}:
      Js.obj([Js.kv("type", Js.str("press")), Js.kv("pane", Js.str(pane)), Js.kv("key", Js.str(key))])
    case SideNative{pane, text}:
      Js.obj([Js.kv("type", Js.str("btw")), Js.kv("pane", Js.str(pane)), Js.kv("text", Js.str(text))])
    case SideFork{pane, kind, cwd, session, text}:
      Js.obj([Js.kv("type", Js.str("fork")), Js.kv("pane", Js.str(pane)), Js.kv("kind", Js.str(kind)), Js.kv("cwd", Js.str(cwd)), Js.kv("text", Js.str(text))])

def Agent.json(a: Agent) -> String:
  match a:
    case Agent{pane, name, kind, status, cwd, title, seq, session, screen}:
      Js.obj([
        Js.kv("pane", Js.str(pane)),
        Js.kv("name", Js.str(name)),
        Js.kv("kind", Js.str(kind)),
        Js.kv("status", Js.str(Status.show(status))),
        Js.kv("cwd", Js.str(cwd)),
        Js.kv("title", Js.str(title)),
        Js.kv("seq", Js.num(seq)),
        Js.kv("session", Js.str(session)),
      ])

def Opt.json(o: Opt) -> String:
  match o:
    case Opt{key, label, action}:
      Js.obj([Js.kv("key", Js.str(key)), Js.kv("label", Js.str(label)), Js.kv("action", Action.json(action))])

def Opt.jsons(os: List<&2, Opt>) -> List<&2, String>:
  match os:
    case Nil{}:
      []
    case Con{h, t}:
      Opt.json(h) <> Opt.jsons(t)

def Item.json(i: Item) -> String:
  match i:
    case Item{id, kind, pane, agent, title, body, opts, at}:
      Js.obj([
        Js.kv("id", Js.num(id)),
        Js.kv("kind", Js.str(Sort.show(kind))),
        Js.kv("pane", Js.str(pane)),
        Js.kv("agent", Js.str(agent)),
        Js.kv("title", Js.str(title)),
        Js.kv("body", Js.str(body)),
        Js.kv("options", Js.arr(Opt.jsons(opts))),
        Js.kv("at", Js.num(at)),
      ])

def Dispatch.json(+now: U32, d: Dispatch) -> String:
  match d:
    case Dispatch{id, action, label, +due, item}:
      Js.obj([
        Js.kv("id", Js.num(id)),
        Js.kv("label", Js.str(label)),
        Js.kv("action", Action.json(action)),
        Js.kv("due", Js.num(due)),
        Js.kv("left", Js.num(U32.sub(due, U32.min(due, now)))),
        Js.kv("item", Js.num(item)),
      ])

def Receipt.json(r: Receipt) -> String:
  match r:
    case Receipt{id, label, ok, detail, at}:
      Js.obj([
        Js.kv("id", Js.num(id)),
        Js.kv("label", Js.str(label)),
        Js.kv("ok", Js.bool(ok)),
        Js.kv("detail", Js.str(detail)),
        Js.kv("at", Js.num(at)),
      ])

def Agent.jsons(xs: List<&2, Agent>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{h, t}:
      Agent.json(h) <> Agent.jsons(t)

def Item.jsons(xs: List<&2, Item>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{h, t}:
      Item.json(h) <> Item.jsons(t)

def Dispatch.jsons(+now: U32, xs: List<&2, Dispatch>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{h, t}:
      Dispatch.json(now, h) <> Dispatch.jsons(now, t)

def Receipt.jsons(xs: List<&2, Receipt>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{h, t}:
      Receipt.json(h) <> Receipt.jsons(t)

def State.json(s: State) -> String:
  match s:
    case State{+now, next, undo, herdr, agents, inbox, pending, receipts, folders}:
      Js.obj([
        Js.kv("now", Js.num(now)),
        Js.kv("undo", Js.num(undo)),
        Js.kv("herdr", Js.bool(herdr)),
        Js.kv("folders", Js.nat(List.length(&2, Folder, folders))),
        Js.kv("agents", Js.arr(Agent.jsons(agents))),
        Js.kv("inbox", Js.arr(Item.jsons(inbox))),
        Js.kv("pending", Js.arr(Dispatch.jsons(now, pending))),
        Js.kv("receipts", Js.arr(Receipt.jsons(receipts))),
      ])
