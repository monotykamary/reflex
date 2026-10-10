import Base
import ./Host.bend as H
import ./Js.bend as Js
import ./Model.bend as M
import ./Core.bend as Core
import ./Herdr.bend as Herdr
import ./Index.bend as Ix
import ./Route.bend as R
import ./Past.bend as P
import ./Http.bend as Http
import ./Fs.bend as Fs
import ./vendor/strict-json/json.bend as J

# reflexd: the IO shell around Core.step.
#
#   actor   one computation owns the State; every change is Core.step
#   ticker  posts Tick so the undo window can expire
#   poller  posts Herdr's agents (with a screen for agents that changed)
#   indexer runs reflex-scan.sh and posts the folder index
#   http    one computation per connection: the JSON API and the web remote
#   exec    one computation per dispatch that leaves its undo window
#
# Loops are bounded by Nat fuel (no unsafe recursion); the bounds outlast any
# realistic uptime.

type Cfg is Data:
  Cfg{
    sock: String,
    bind: String,
    port: U32,
    token: String,
    jev: String,
    harness: String,
    threshold: U32,
    home: String,
    data: String,
    web: String,
    scan: String,
    fork: String,
    undo: U32,
    shown: Bool,
  }

type Env is Data:
  Env{msg: M.Msg, reply: Maybe<&2, Chan(M.Reply)>}

def RS() -> Type:
  Result<&1, &1, U32 & String, String>

def forever() -> Nat:
  4294967295n

# Config
# ------

def env_or(r: Result<&1, &1, U32 & String, String>, default: String) -> String:
  match r:
    case Done{v}:
      Js.or_else(v, default)
    case Fail{e}:
      default

def env(name: String, default: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return env_or(r, default)

def u32_env(name: String, +default: U32) -> IO(U32):
  do IO<U32>:
    v : String <- env(name, "")
    return Js.u32_or(U32.read(v), default)

def rand_or(r: Result<&1, &1, U32 & String, U32>) -> String:
  match r:
    case Done{n}:
      U32.show(n)
    case Fail{e}:
      "0"

def fresh_token() -> IO(String):
  do IO<String>:
    a : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    b : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    return "rx" ++ rand_or(a) ++ rand_or(b)

def token_or.if(empty: Bool, given: String) -> IO(String):
  match empty:
    case True{}:
      fresh_token()
    case False{}:
      IO.pure(String, given)

def token_or(+given: String) -> IO(String):
  token_or.if(String.is_empty(given), given)

def default_sock(+home: String, +session: String) -> String:
  Js.or_else.pick(String.is_empty(session), home ++ "/.config/herdr/sessions/" ++ session ++ "/herdr.sock", home ++ "/.config/herdr/herdr.sock")

def load() -> IO(Cfg):
  do IO<Cfg>:
    +home : String <- env("HOME", "/tmp")
    session : String <- env("HERDR_SESSION", "")
    sock : String <- env("REFLEX_HERDR_SOCKET", default_sock(home, session))
    bind : String <- env("REFLEX_BIND", "127.0.0.1")
    port : U32 <- u32_env("REFLEX_PORT", 47823)
    +given : String <- env("REFLEX_TOKEN", "")
    token : String <- token_or(given)
    jev : String <- env("REFLEX_JEV", "jev-fabric")
    harness : String <- env("REFLEX_HARNESS", "claude")
    threshold : U32 <- u32_env("REFLEX_THRESHOLD", 6000)
    data : String <- env("REFLEX_DATA", home ++ "/Library/Application Support/Reflex")
    web : String <- env("REFLEX_WEB", "web")
    scan : String <- env("REFLEX_SCAN", "reflex-scan.sh")
    fork : String <- env("REFLEX_FORK", "reflex-fork.sh")
    undo : U32 <- u32_env("REFLEX_UNDO_MS", 0)
    return Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, String.is_empty(given)}

def Cfg.sock(c: Cfg) -> String:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      sock

def Cfg.token(c: Cfg) -> String:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      token

def Cfg.home(c: Cfg) -> String:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      home

def Cfg.data(c: Cfg) -> String:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      data

def Cfg.web(c: Cfg) -> String:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      web

def Cfg.scan(c: Cfg) -> String:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      scan

def Cfg.fork(c: Cfg) -> String:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      fork

def Cfg.jev(c: Cfg) -> String:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      jev

def Cfg.harness(c: Cfg) -> String:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      harness

def Cfg.threshold(c: Cfg) -> U32:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      threshold

def Cfg.undo(c: Cfg) -> U32:
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      undo

# A token the daemon made up is printed once so it can be used; one given in
# REFLEX_TOKEN never reaches the log.
def shown_token(shown: Bool, token: String) -> String:
  match shown:
    case True{}:
      token
    case False{}:
      "(from REFLEX_TOKEN)"

def Cfg.ready(c: Cfg) -> String:
  match c:
    case Cfg{sock, bind, +port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      Js.obj([Js.kv("ready", Js.obj([
        Js.kv("url", Js.str("http://" ++ bind ++ ":" ++ U32.show(port))),
        Js.kv("port", Js.num(port)),
        Js.kv("token", Js.str(shown_token(shown, token))),
        Js.kv("herdr", Js.str(sock)),
        Js.kv("harness", Js.str(harness)),
        Js.kv("data", Js.str(data)),
      ]))])

def Cfg.listen(c: Cfg) -> IO(Result<&1, &1, U32 & String, Listener>):
  match c:
    case Cfg{sock, bind, port, token, jev, harness, threshold, home, data, web, scan, fork, undo, shown}:
      TCP.listen(bind, port)

# Talking to the actor
# --------------------

def post(+chan: Chan(Env), msg: M.Msg) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, Env, Unit> <- Chan.send(Env, chan, Env{msg, None{}})
    return Unit{}

def reply_of(m: Maybe<&1, M.Reply>) -> M.Reply:
  match m:
    case Some{r}:
      r
    case None{}:
      M.RText{"{\"ok\":false,\"error\":\"actor gone\"}"}

# Send a message and wait for the actor's reply.
def ask(+chan: Chan(Env), msg: M.Msg) -> IO(M.Reply):
  do IO<M.Reply>:
    +back : Chan(M.Reply) <- Chan.new(M.Reply, 1)
    sent : Result<&1, &1, Env, Unit> <- Chan.send(Env, chan, Env{msg, Some{back}})
    got : Maybe<&1, M.Reply> <- Chan.recv(M.Reply, back)
    return reply_of(got)

def text_of(r: M.Reply) -> String:
  match r:
    case M.RText{json}:
      json
    case M.RContext{agents, folders}:
      "{}"

def ask_text(+chan: Chan(Env), msg: M.Msg) -> IO(String):
  do IO<String>:
    r : M.Reply <- ask(chan, msg)
    return text_of(r)

# Running dispatches
# ------------------

def ok_detail(r: Result<&1, &1, U32 & String, J.JSON>, done: String) -> Result<&1, &1, U32 & String, String>:
  match r:
    case Done{v}:
      Done{done}
    case Fail{e}:
      Fail{e}

def stdout_of.status(ok: Bool, out: String, err: String, +status: U32) -> Result<&1, &1, U32 & String, String>:
  match ok:
    case True{}:
      Done{out}
    case False{}:
      Fail{(status, Js.or_else(String.trim(err), String.trim(out)))}

def stdout_of(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> Result<&1, &1, U32 & String, String>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{(+status, (out, err))}:
      stdout_of.status(U32.is_eq(status, 0), out, err, status)

def rbind(-A: Type, -B: Type, r: Result<&1, &1, U32 & String, A>, f: A -> IO(Result<&1, &1, U32 & String, B>)) -> IO(Result<&1, &1, U32 & String, B>):
  match r:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, B>, Fail{e})
    case Done{x}:
      f(x)

def text_or(r: Result<&1, &1, U32 & String, String>, prev: String) -> String:
  match r:
    case Done{t}:
      t
    case Fail{e}:
      prev

# Waiting for a TUI to finish answering: read the pane until two reads agree.
type Settle is Data:
  Settle{text: String, calm: U32}

def settle.calm(same: Bool, +calm: U32) -> U32:
  match same:
    case True{}:
      (calm + 1 : U32)
    case False{}:
      0

def settle.step.if(done: Bool, +sock: String, +pane: String, +text: String, +calm: U32) -> IO(Settle):
  match done:
    case True{}:
      IO.pure(Settle, Settle{text, calm})
    case False{}:
      do IO<Settle>:
        IO.sleep(1500)
        r : Result<&1, &1, U32 & String, String> <- Herdr.read_pane(sock, pane, "visible", 80)
        +cur : String = text_or(r, text)
        return Settle{cur, settle.calm(String.eq(cur, text), calm)}

def settle.step(+sock: String, +pane: String, st: Settle) -> IO(Settle):
  match st:
    case Settle{+text, +calm}:
      settle.step.if(U32.is_ge(calm, 2), sock, pane, text, calm)

def settle(fuel: Nat, +sock: String, +pane: String, st: Settle) -> IO(Settle):
  match fuel:
    case 0n:
      IO.pure(Settle, st)
    case 1n+p:
      do IO<Settle>:
        next : Settle <- settle.step(sock, pane, st)
        settle(p, sock, pane, next)

def Settle.text(s: Settle) -> String:
  match s:
    case Settle{text, calm}:
      text

# After a native /btw, collect what the agent showed and post it as a reply.
def capture_btw(+cfg: Cfg, +chan: Chan(Env), +pane: String, +label: String) -> IO(Unit):
  do IO<Unit>:
    IO.sleep(2500)
    st : Settle <- settle(30n, Cfg.sock(cfg), pane, Settle{"", 0})
    post(chan, M.Post{M.IReply{}, pane, label, "btw answer", Core.tail_lines(Settle.text(st), 30n), []})

# The actor
# ---------

def answer(reply: Maybe<&2, Chan(M.Reply)>, r: M.Reply) -> IO(Unit):
  match reply:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{back}:
      do IO<Unit>:
        s : Result<&1, &1, M.Reply, Unit> <- Chan.send(M.Reply, back, r)
        return Unit{}

def post_fork_reply(+chan: Chan(Env), +pane: String, +label: String, r: Result<&1, &1, U32 & String, String>) -> IO(Result<&1, &1, U32 & String, String>):
  match r:
    case Done{+out}:
      do IO<Result<&1, &1, U32 & String, String>>:
        post(chan, M.Post{M.IReply{}, pane, label, "btw answer (forked session)", String.trim(out), []})
        return Done{"answered in a fork"}
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, String>, Fail{e})

# Ids restart with reflexd but herdr keeps agent names, so a random suffix
# keeps a fresh "rx1" from colliding with one an earlier run started.
def name_suffix(r: Result<&1, &1, U32 & String, U32>) -> String:
  match r:
    case Done{n}:
      U32.show((n % 10000 : U32))
    case Fail{e}:
      "0"

def agent_name(+id: U32, r: Result<&1, &1, U32 & String, U32>) -> String:
  "rx" ++ U32.show(id) ++ "-" ++ name_suffix(r)

# A freshly started agent can refuse its first prompt for a moment
# (agent_not_ready) while Herdr registers it; retry that, and only that.
type PTry is Data:
  PTry{settled: Bool, ok: Bool, detail: String}

def retryable(+msg: String) -> Bool:
  String.contains(msg, "agent_not_ready") || String.contains(msg, "not an active")

def ptry_of(r: Result<&1, &1, U32 & String, J.JSON>) -> PTry:
  match r:
    case Done{v}:
      PTry{True{}, True{}, "sent"}
    case Fail{(code, +msg)}:
      PTry{Core.bool_not(retryable(msg)), False{}, msg}

def prompt_step(+sock: String, +pane: String, +text: String, st: PTry) -> IO(PTry):
  match st:
    case PTry{True{}, ok, detail}:
      IO.pure(PTry, PTry{True{}, ok, detail})
    case PTry{False{}, ok, detail}:
      do IO<PTry>:
        IO.sleep(700)
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.prompt(sock, pane, text)
        return ptry_of(r)

def prompt_retry(fuel: Nat, +sock: String, +pane: String, +text: String, st: PTry) -> IO(PTry):
  match fuel:
    case 0n:
      IO.pure(PTry, st)
    case 1n+p:
      do IO<PTry>:
        next : PTry <- prompt_step(sock, pane, text, st)
        prompt_retry(p, sock, pane, text, next)

def record_use(ok: Bool, +cfg: Cfg, +cwd: String) -> IO(Unit):
  match ok:
    case True{}:
      do IO<Unit>:
        u : Result<&1, &1, U32 & String, Unit> <- Fs.put(Cfg.data(cfg) ++ "/usage.tsv", "a", cwd ++ "\n")
        return Unit{}
    case False{}:
      IO.pure(Unit, Unit{})

def spawn_result(+name: String, +pane: String, st: PTry) -> Result<&1, &1, U32 & String, String>:
  match st:
    case PTry{settled, True{}, detail}:
      Done{"started " ++ name ++ " in " ++ pane}
    case PTry{settled, False{}, detail}:
      Fail{(1, "started " ++ name ++ " but could not prompt it: " ++ detail)}

def PTry.ok(st: PTry) -> Bool:
  match st:
    case PTry{settled, ok, detail}:
      ok

def spawned(+cfg: Cfg, +cwd: String, +name: String, +pane: String, +text: String, r: Result<&1, &1, U32 & String, J.JSON>) -> IO(Result<&1, &1, U32 & String, String>):
  match r:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, String>, Fail{e})
    case Done{v}:
      do IO<Result<&1, &1, U32 & String, String>>:
        +st : PTry <- prompt_retry(15n, Cfg.sock(cfg), pane, text, PTry{False{}, False{}, ""})
        record_use(PTry.ok(st), cfg, cwd)
        return spawn_result(name, pane, st)

def spawn_in(+cfg: Cfg, +id: U32, +cwd: String, +kind: String, +text: String, w: Result<&1, &1, U32 & String, String>) -> IO(Result<&1, &1, U32 & String, String>):
  match w:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, String>, Fail{e})
    case Done{+pane}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
        +name : String <- IO.pure(String, agent_name(id, r))
        st : Result<&1, &1, U32 & String, J.JSON> <- Herdr.start_agent(Cfg.sock(cfg), name, kind, pane)
        spawned(cfg, cwd, name, pane, text, st)

def resumed_result(+name: String, +pane: String, r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, String>:
  match r:
    case Done{v}:
      Done{"resumed " ++ name ++ " in " ++ pane}
    case Fail{e}:
      Fail{e}

# Started: prompt it when there is a request, else it is simply back.
def resumed(empty: Bool, +cfg: Cfg, +cwd: String, +name: String, +pane: String, +text: String, r: Result<&1, &1, U32 & String, J.JSON>) -> IO(Result<&1, &1, U32 & String, String>):
  match empty:
    case True{}:
      IO.pure(Result<&1, &1, U32 & String, String>, resumed_result(name, pane, r))
    case False{}:
      spawned(cfg, cwd, name, pane, text, r)

def resume_in(+cfg: Cfg, +id: U32, +cwd: String, +kind: String, +args: List<&2, String>, +text: String, w: Result<&1, &1, U32 & String, String>) -> IO(Result<&1, &1, U32 & String, String>):
  match w:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, String>, Fail{e})
    case Done{+pane}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
        +name : String <- IO.pure(String, agent_name(id, r))
        st : Result<&1, &1, U32 & String, J.JSON> <- Herdr.start_agent_args(Cfg.sock(cfg), name, kind, pane, args)
        resumed(String.is_empty(text), cfg, cwd, name, pane, text, st)

def perform(+cfg: Cfg, +chan: Chan(Env), +id: U32, +label: String, a: M.Action) -> IO(Result<&1, &1, U32 & String, String>):
  match a:
    case M.Prompt{pane, text}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.prompt(Cfg.sock(cfg), pane, text)
        return ok_detail(r, "sent")
    case M.Press{pane, +key}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.press(Cfg.sock(cfg), pane, key)
        return ok_detail(r, "pressed " ++ key)
    case M.SideNative{+pane, text}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.prompt(Cfg.sock(cfg), pane, "/btw " ++ text)
        IO.spawn(Unit, capture_btw(cfg, chan, pane, label))
        return ok_detail(r, "asked with /btw")
    case M.SideFork{+pane, kind, cwd, session, text}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(Cfg.fork(cfg), [kind, cwd, session, text], "", 4194304, 300000)
        post_fork_reply(chan, pane, label, stdout_of(r))
    case M.Resume{+cwd, +kind, +session, +mode, +text}:
      do IO<Result<&1, &1, U32 & String, String>>:
        w : Result<&1, &1, U32 & String, String> <- Herdr.new_workspace(Cfg.sock(cfg), cwd, Core.base_name(cwd))
        resume_in(cfg, id, cwd, kind, R.resume_args(kind, mode, session), text, w)
    case M.Spawn{+cwd, +kind, +text}:
      do IO<Result<&1, &1, U32 & String, String>>:
        # A new project folder may not exist yet; mkdir -p is a no-op otherwise.
        m : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("/bin/mkdir", ["-p", cwd], "", 4096, 5000)
        w : Result<&1, &1, U32 & String, String> <- Herdr.new_workspace(Cfg.sock(cfg), cwd, Core.base_name(cwd))
        spawn_in(cfg, id, cwd, kind, text, w)

def receipt(+id: U32, +label: String, r: Result<&1, &1, U32 & String, String>) -> M.Msg:
  match r:
    case Done{d}:
      M.Receipted{id, label, True{}, d}
    case Fail{(code, msg)}:
      M.Receipted{id, label, False{}, msg}

def exec(+cfg: Cfg, +chan: Chan(Env), d: M.Dispatch) -> IO(Unit):
  match d:
    case M.Dispatch{+id, action, +label, due, item}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, String> <- perform(cfg, chan, id, label, action)
        post(chan, receipt(id, label, r))

def exec_all(ds: List<&2, M.Dispatch>, +cfg: Cfg, +chan: Chan(Env)) -> IO(Unit):
  match ds:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{d, t}:
      do IO<Unit>:
        IO.spawn(Unit, exec(cfg, chan, d))
        exec_all(t, cfg, chan)

def handle.out(+cfg: Cfg, +chan: Chan(Env), out: M.Out, reply: Maybe<&2, Chan(M.Reply)>) -> IO(M.State):
  match out:
    case M.Out{state, run, r}:
      do IO<M.State>:
        answer(reply, r)
        exec_all(run, cfg, chan)
        return state

def env_of(m: Maybe<&1, Env>) -> Env:
  match m:
    case Some{e}:
      e
    case None{}:
      Env{M.Query{}, None{}}

def handle(+cfg: Cfg, +chan: Chan(Env), s: M.State, e: Env) -> IO(M.State):
  match e:
    case Env{msg, reply}:
      handle.out(cfg, chan, Core.step(s, msg), reply)

def actor(fuel: Nat, +cfg: Cfg, +chan: Chan(Env), s: M.State) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        m : Maybe<&1, Env> <- Chan.recv(Env, chan)
        next : M.State <- handle(cfg, chan, s, env_of(m))
        actor(p, cfg, chan, next)

# Ticker, poller, indexer
# -----------------------

def ticker(fuel: Nat, +chan: Chan(Env), +start: Nat) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        IO.sleep(150)
        now : Nat <- IO.now()
        post(chan, M.Tick{U32.from_nat(Nat.sub(now, start))})
        ticker(p, chan, start)

def wants_screen(prev: Maybe<&2, M.Agent>, +a: M.Agent) -> Bool:
  match prev:
    case None{}:
      Core.is_blocked(Core.Agent.status(a)) || Core.is_ready(Core.Agent.status(a))
    case Some{+p}:
      (Core.bool_not(U32.is_eq(Core.Agent.seq(p), Core.Agent.seq(a))) || Core.bool_not(String.eq(M.Status.show(Core.Agent.status(p)), M.Status.show(Core.Agent.status(a))))) && (Core.is_blocked(Core.Agent.status(a)) || Core.is_ready(Core.Agent.status(a)))

def source_for(s: M.Status) -> String:
  match s:
    case M.Blocked{}:
      "detection"
    case other:
      "recent_unwrapped"

def with_screen(a: M.Agent, r: Result<&1, &1, U32 & String, String>) -> M.Agent:
  match a:
    case M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}:
      M.Agent{pane, name, kind, status, cwd, title, seq, session, text_or(r, "")}

def screen_for(want: Bool, +sock: String, a: M.Agent) -> IO(M.Agent):
  match want a:
    case False{} _:
      IO.pure(M.Agent, a)
    case True{} M.Agent{+pane, name, kind, +status, cwd, title, seq, session, screen}:
      do IO<M.Agent>:
        r : Result<&1, &1, U32 & String, String> <- Herdr.read_pane(sock, pane, source_for(status), 40)
        return with_screen(M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}, r)

def screens(cur: List<&2, M.Agent>, +sock: String, +prev: List<&2, M.Agent>) -> IO(List<&2, M.Agent>):
  match cur:
    case Nil{}:
      IO.pure(List<&2, M.Agent>, [])
    case Con{+a, t}:
      do IO<List<&2, M.Agent>>:
        h : M.Agent <- screen_for(wants_screen(Core.find_agent(prev, Core.Agent.pane(a)), a), sock, a)
        rest : List<&2, M.Agent> <- screens(t, sock, prev)
        return h <> rest

type Snap is Data:
  Snap{ok: Bool, agents: List<&2, M.Agent>}

def snap(r: Result<&1, &1, U32 & String, List<&2, M.Agent>>, +sock: String, +prev: List<&2, M.Agent>) -> IO(Snap):
  match r:
    case Fail{e}:
      IO.pure(Snap, Snap{False{}, prev})
    case Done{cur}:
      do IO<Snap>:
        xs : List<&2, M.Agent> <- screens(cur, sock, prev)
        return Snap{True{}, xs}

def poll.post(+chan: Chan(Env), +s: Snap) -> IO(List<&2, M.Agent>):
  match s:
    case Snap{ok, +agents}:
      do IO<List<&2, M.Agent>>:
        post(chan, M.Polled{ok, agents})
        return agents

def poller(fuel: Nat, +cfg: Cfg, +chan: Chan(Env), prev: List<&2, M.Agent>) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, List<&2, M.Agent>> <- Herdr.list_agents(Cfg.sock(cfg))
        s : Snap <- snap(r, Cfg.sock(cfg), prev)
        cur : List<&2, M.Agent> <- poll.post(chan, s)
        IO.sleep(700)
        poller(p, cfg, chan, cur)

def reindex(+cfg: Cfg, +chan: Chan(Env)) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(Cfg.scan(cfg), [], "", 33554432, 180000)
    post(chan, M.Indexed{Ix.parse(text_or(stdout_of(r), ""))})

def indexer(fuel: Nat, +cfg: Cfg, +chan: Chan(Env)) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        reindex(cfg, chan)
        IO.sleep(900000)
        indexer(p, cfg, chan)

# Routing a request
# -----------------

def seen_of(a: M.Agent, r: Result<&1, &1, U32 & String, String>) -> R.Seen:
  R.Seen{a, text_or(r, "")}

def read_seen(xs: List<&2, M.Agent>, +sock: String) -> IO(List<&2, R.Seen>):
  match xs:
    case Nil{}:
      IO.pure(List<&2, R.Seen>, [])
    case Con{+a, t}:
      do IO<List<&2, R.Seen>>:
        r : Result<&1, &1, U32 & String, String> <- Herdr.read_pane(sock, Core.Agent.pane(a), "recent_unwrapped", 40)
        rest : List<&2, R.Seen> <- read_seen(t, sock)
        return seen_of(a, r) <> rest

def take_agents(xs: List<&2, M.Agent>, n: Nat) -> List<&2, M.Agent>:
  match xs n:
    case Nil{} _:
      []
    case Con{h, t} 0n:
      []
    case Con{h, t} 1n+p:
      h <> take_agents(t, p)

# Earlier sessions the app found (sessions.tsv), the most relevant few.
def pasts_file(+cfg: Cfg) -> String:
  Cfg.data(cfg) ++ "/sessions.tsv"

def read_pasts(+cfg: Cfg) -> IO(List<&2, P.Past>):
  do IO<List<&2, P.Past>>:
    r : Result<&1, &1, U32 & String, String> <- Fs.read(pasts_file(cfg), 8388608)
    return P.parse(text_or(r, ""))

def jev_args() -> List<String>:
  ["--", "serve", "--timeout-ms", "60000", "1", "60000"]

def route_json(d: String, extra: String) -> String:
  "{\"ok\":true,\"route\":" ++ d ++ extra ++ "}"

def act(dry: Bool, +chan: Chan(Env), +text: String, d: R.Decision) -> IO(String):
  match dry d:
    case True{} _:
      IO.pure(String, route_json(R.Decision.json(d), ""))
    case False{} R.Go{+action, +label, +why}:
      do IO<String>:
        r : String <- ask_text(chan, M.Enqueue{action, label, 0})
        return route_json(R.Decision.json(R.Go{action, label, why}), ",\"dispatch\":" ++ r)
    case False{} R.Choose{+title, +opts, +why}:
      do IO<String>:
        r : String <- ask_text(chan, M.Post{M.IRoute{}, "", "reflex", title, text, opts})
        return route_json(R.Decision.json(R.Choose{title, opts, why}), ",\"posted\":" ++ r)
    case False{} R.Broke{+message}:
      do IO<String>:
        r : String <- ask_text(chan, M.Post{M.INote{}, "", "reflex", "could not route", message, []})
        return route_json(R.Decision.json(R.Broke{message}), "")

def retry(again: Bool, d: R.Decision, dry: Bool, +cfg: Cfg, +chan: Chan(Env), +text: String, +harness: String, +line: String, +seen: List<&2, R.Seen>, +cands: List<&2, M.Folder>, +pasts: List<&2, P.Past>) -> IO(String):
  match again:
    case False{}:
      act(dry, chan, text, d)
    case True{}:
      do IO<String>:
        IO.sleep(300)
        out : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(Cfg.jev(cfg), jev_args(), line, 4194304, 65000)
        act(dry, chan, text, R.decide_output(text_or(stdout_of(out), ""), text, Cfg.home(cfg), harness, Cfg.threshold(cfg), seen, cands, pasts))

def route_ctx(dry: Bool, +cfg: Cfg, +chan: Chan(Env), +text: String, +harness: String, +memory: String, ctx: M.Reply) -> IO(String):
  match ctx:
    case M.RContext{agents, folders}:
      do IO<String>:
        +seen : List<&2, R.Seen> <- read_seen(take_agents(agents, 12n), Cfg.sock(cfg))
        +cands : List<&2, M.Folder> = Ix.rank(text, folders, 8n)
        all : List<&2, P.Past> <- read_pasts(cfg)
        +pasts : List<&2, P.Past> = P.rank(text, all, 5n)
        +line : String = R.request(text, Cfg.home(cfg), seen, cands, pasts, memory)
        out : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(Cfg.jev(cfg), jev_args(), line, 4194304, 65000)
        +d : R.Decision = R.decide_output(text_or(stdout_of(out), ""), text, Cfg.home(cfg), harness, Cfg.threshold(cfg), seen, cands, pasts)
        retry(R.transient(d), d, dry, cfg, chan, text, harness, line, seen, cands, pasts)
    case M.RText{json}:
      IO.pure(String, "{\"ok\":false,\"error\":\"no context\"}")

def route(dry: Bool, +cfg: Cfg, +chan: Chan(Env), +text: String, +harness: String, +memory: String) -> IO(String):
  do IO<String>:
    ctx : M.Reply <- ask(chan, M.Context{})
    route_ctx(dry, cfg, chan, text, harness, memory, ctx)

# Jev's ranking of every candidate, live, for the Ask bar's list. Dry.
def candidates_ctx(+cfg: Cfg, +text: String, +harness: String, +memory: String, ctx: M.Reply) -> IO(String):
  match ctx:
    case M.RContext{agents, folders}:
      do IO<String>:
        +seen : List<&2, R.Seen> <- read_seen(take_agents(agents, 12n), Cfg.sock(cfg))
        +cands : List<&2, M.Folder> = Ix.rank(text, folders, 8n)
        all : List<&2, P.Past> <- read_pasts(cfg)
        +pasts : List<&2, P.Past> = P.rank(text, all, 5n)
        +line : String = R.request(text, Cfg.home(cfg), seen, cands, pasts, memory)
        t0 : Nat <- IO.now()
        out : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(Cfg.jev(cfg), jev_args(), line, 4194304, 65000)
        t1 : Nat <- IO.now()
        return R.candidates_output(text_or(stdout_of(out), ""), text, Cfg.home(cfg), harness, Cfg.threshold(cfg), seen, cands, pasts, U32.from_nat(Nat.sub(t1, t0)))
    case M.RText{json}:
      IO.pure(String, "{\"ok\":false,\"error\":\"no context\"}")

# The JSON request for the candidates routing would show Jev (for a UI or a
# debugging session), without calling Jev.
def explain_ctx(+cfg: Cfg, +text: String, +memory: String, ctx: M.Reply) -> IO(String):
  match ctx:
    case M.RContext{agents, folders}:
      do IO<String>:
        +seen : List<&2, R.Seen> <- read_seen(take_agents(agents, 12n), Cfg.sock(cfg))
        all : List<&2, P.Past> <- read_pasts(cfg)
        return "{\"ok\":true,\"jev\":" ++ String.trim(R.request(text, Cfg.home(cfg), seen, Ix.rank(text, folders, 8n), P.rank(text, all, 5n), memory)) ++ "}"
    case M.RText{json}:
      IO.pure(String, "{\"ok\":false}")

# A side question for one specific agent (from its popout), routed by the
# same per-harness rules as a routed "btw".
def side_agent(m: Maybe<&2, M.Agent>, +cfg: Cfg, +chan: Chan(Env), +text: String) -> IO(String):
  match m:
    case None{}:
      IO.pure(String, "{\"ok\":false,\"error\":\"no agent in that pane\"}")
    case Some{a}:
      act(False{}, chan, text, R.agent_decision(True{}, a, text, Cfg.home(cfg), Cfg.harness(cfg)))

def side_ctx(+cfg: Cfg, +chan: Chan(Env), +pane: String, +text: String, ctx: M.Reply) -> IO(String):
  match ctx:
    case M.RContext{agents, folders}:
      side_agent(Core.find_agent(agents, pane), cfg, chan, text)
    case M.RText{json}:
      IO.pure(String, "{\"ok\":false}")

# One tiny typed Jev call, to prove the credentials and measure latency.
def ping_line() -> String:
  "{\"id\":1,\"op\":\"jev\",\"request\":{\"state\":\"Reflex setup check.\",\"questions\":{\"ready\":{\"type\":\"noul\",\"instructions\":\"Is this a setup check?\"}}}}\n"

def ping_json(r: Result<&1, &1, U32 & String, J.JSON>, +ms: U32) -> String:
  match r:
    case Done{v}:
      Js.obj([Js.kv("ok", "true"), Js.kv("ms", Js.num(ms))])
    case Fail{(code, msg)}:
      Js.obj([Js.kv("ok", "false"), Js.kv("ms", Js.num(ms)), Js.kv("error", Js.str(msg))])

def ok(json: String) -> IO(String):
  IO.pure(String, Http.json(200, json))

def jev_ping(+cfg: Cfg) -> IO(String):
  do IO<String>:
    t0 : Nat <- IO.now()
    out : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(Cfg.jev(cfg), jev_args(), ping_line(), 1048576, 45000)
    t1 : Nat <- IO.now()
    ok(ping_json(R.response(text_or(stdout_of(out), "")), U32.from_nat(Nat.sub(t1, t0))))

def folders_json(+home: String, fs: List<&2, M.Folder>) -> List<&2, String>:
  match fs:
    case Nil{}:
      []
    case Con{M.Folder{+path, name, desc, recent, branch, age, uses}, t}:
      Js.obj([Js.kv("path", Js.str(path)), Js.kv("short", Js.str(R.short(home, path))), Js.kv("name", Js.str(name)), Js.kv("desc", Js.str(desc)), Js.kv("branch", Js.str(branch)), Js.kv("ageHours", Js.num(age))]) <> folders_json(home, t)

def folders_ctx(+home: String, +q: String, ctx: M.Reply) -> String:
  match ctx:
    case M.RContext{agents, folders}:
      "{\"ok\":true,\"folders\":" ++ Js.arr(folders_json(home, Ix.rank(q, folders, 12n))) ++ "}"
    case M.RText{json}:
      "{\"ok\":false}"

# HTTP
# ----

type Ep is Data:
  EState{}
  ERoute{}
  ECandidates{}
  EExplain{}
  ESend{}
  ESpawn{}
  ECancel{}
  EAnswer{}
  EDismiss{}
  EPane{}
  EFolders{}
  EReindex{}
  EHealth{}
  ESide{}
  EFocus{}
  EKeys{}
  EText{}
  EClose{}
  ESessions{}
  EResume{}
  EJevPing{}
  EStatic{}
  EMissing{}

type Row is Data:
  Row{path: String, ep: Ep}

def rows() -> List<&2, Row>:
  [
    Row{"/api/state", EState{}},
    Row{"/api/route", ERoute{}},
    Row{"/api/candidates", ECandidates{}},
    Row{"/api/explain", EExplain{}},
    Row{"/api/send", ESend{}},
    Row{"/api/spawn", ESpawn{}},
    Row{"/api/cancel", ECancel{}},
    Row{"/api/answer", EAnswer{}},
    Row{"/api/dismiss", EDismiss{}},
    Row{"/api/pane", EPane{}},
    Row{"/api/folders", EFolders{}},
    Row{"/api/reindex", EReindex{}},
    Row{"/api/health", EHealth{}},
    Row{"/api/side", ESide{}},
    Row{"/api/focus", EFocus{}},
    Row{"/api/keys", EKeys{}},
    Row{"/api/text", EText{}},
    Row{"/api/close", EClose{}},
    Row{"/api/sessions", ESessions{}},
    Row{"/api/resume", EResume{}},
    Row{"/api/jev/ping", EJevPing{}},
  ]

def ep_pick(hit: Bool, ep: Ep, rest: Ep) -> Ep:
  match hit:
    case True{}:
      ep
    case False{}:
      rest

def ep_find(rs: List<&2, Row>, +path: String, fallback: Ep) -> Ep:
  match rs:
    case Nil{}:
      fallback
    case Con{Row{p, ep}, t}:
      ep_pick(String.eq(p, path), ep, ep_find(t, path, fallback))

def fallback_ep(api: Bool) -> Ep:
  match api:
    case True{}:
      EMissing{}
    case False{}:
      EStatic{}

def ep_of(+path: String) -> Ep:
  ep_find(rows(), path, fallback_ep(String.starts_with(path, "/api/")))

def needs_token(ep: Ep) -> Bool:
  match ep:
    case EStatic{}:
      False{}
    case EHealth{}:
      False{}
    case other:
      True{}

def body_of.r(r: Result<&1, &1, U32 & String, J.JSON>) -> J.JSON:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      J.Obj{[]}

def body_of(+raw: String) -> J.JSON:
  body_of.r(Js.read(raw))

def static_name.pick(root: Bool, path: String) -> String:
  match root:
    case True{}:
      "index.html"
    case False{}:
      String.drop(path, 1n)

def static_name(+path: String) -> String:
  static_name.pick(String.eq(path, "/") || String.eq(path, ""), path)

def safe_char(c: Char) -> Bool:
  match c:
    case Chr{+n}:
      (U32.is_le(97, n) && U32.is_le(n, 122)) || (U32.is_le(65, n) && U32.is_le(n, 90)) || (U32.is_le(48, n) && U32.is_le(n, 57)) || U32.is_eq(n, 45) || U32.is_eq(n, 95) || U32.is_eq(n, 46)

def safe_name(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      safe_char(c) && safe_name(t)

def static_read(+name: String, r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{body}:
      Http.response(200, Http.content_type(name), body)
    case Fail{e}:
      Http.response(404, "text/plain", "not found")

def serve_static.if(safe: Bool, +cfg: Cfg, +name: String) -> IO(String):
  match safe:
    case False{}:
      IO.pure(String, Http.response(404, "text/plain", "not found"))
    case True{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, String> <- Fs.read(Cfg.web(cfg) ++ "/" ++ name, 8388608)
        return static_read(name, r)

def serve_static(+cfg: Cfg, +name: String) -> IO(String):
  serve_static.if(safe_name(name) && Core.bool_not(String.starts_with(name, ".")), cfg, name)

def pane_read(ansi: Bool, sock: String, pane: String, lines: U32) -> IO(Result<&1, &1, U32 & String, String>):
  match ansi:
    case True{}:
      Herdr.read_pane_ansi(sock, pane, "recent", lines)
    case False{}:
      Herdr.read_pane(sock, pane, "recent_unwrapped", lines)

def pane_json(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{t}:
      Js.obj([Js.kv("ok", "true"), Js.kv("text", Js.str(t))])
    case Fail{(c, m)}:
      Js.obj([Js.kv("ok", "false"), Js.kv("error", Js.str(m))])

def is_true(+s: String) -> Bool:
  String.eq(s, "true") || String.eq(s, "1")

def endpoint(ep: Ep, +cfg: Cfg, +chan: Chan(Env), +req: Http.Req, +body: J.JSON) -> IO(String):
  match ep:
    case EState{}:
      do IO<String>:
        r : String <- ask_text(chan, M.Query{})
        ok(r)
    case ERoute{}:
      do IO<String>:
        r : String <- route(is_true(Js.text_at(body, "dry")), cfg, chan, Js.text_at(body, "text"), Js.or_else(Js.text_at(body, "harness"), Cfg.harness(cfg)), Js.text_at(body, "memory"))
        ok(r)
    case ECandidates{}:
      do IO<String>:
        ctx : M.Reply <- ask(chan, M.Context{})
        r : String <- candidates_ctx(cfg, Js.text_at(body, "text"), Js.or_else(Js.text_at(body, "harness"), Cfg.harness(cfg)), Js.text_at(body, "memory"), ctx)
        ok(r)
    case EExplain{}:
      do IO<String>:
        ctx : M.Reply <- ask(chan, M.Context{})
        r : String <- explain_ctx(cfg, Js.text_at(body, "text"), Js.text_at(body, "memory"), ctx)
        ok(r)
    case ESend{}:
      do IO<String>:
        r : String <- ask_text(chan, M.Enqueue{M.Prompt{Js.text_at(body, "pane"), Js.text_at(body, "text")}, "→ " ++ Js.or_else(Js.text_at(body, "label"), Js.text_at(body, "pane")), 0})
        ok(r)
    case ESpawn{}:
      do IO<String>:
        r : String <- ask_text(chan, M.Enqueue{M.Spawn{Js.text_at(body, "cwd"), Js.or_else(Js.text_at(body, "kind"), Cfg.harness(cfg)), Js.text_at(body, "text")}, "new " ++ Js.or_else(Js.text_at(body, "kind"), Cfg.harness(cfg)) ++ " in " ++ R.leaf(Js.text_at(body, "cwd")), 0})
        ok(r)
    case ECancel{}:
      do IO<String>:
        r : String <- ask_text(chan, M.Cancel{Js.as_u32(Js.get(body, "id"), 0)})
        ok(r)
    case EAnswer{}:
      do IO<String>:
        r : String <- ask_text(chan, M.Answer{Js.as_u32(Js.get(body, "item"), 0), Js.text_at(body, "key")})
        ok(r)
    case EDismiss{}:
      do IO<String>:
        r : String <- ask_text(chan, M.Dismiss{Js.as_u32(Js.get(body, "item"), 0)})
        ok(r)
    case EPane{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, String> <- pane_read(String.eq(Http.Req.query(req, "format"), "ansi"), Cfg.sock(cfg), Http.Req.query(req, "id"), Js.u32_or(U32.read(Http.Req.query(req, "lines")), 120))
        ok(pane_json(r))
    case EFolders{}:
      do IO<String>:
        ctx : M.Reply <- ask(chan, M.Context{})
        ok(folders_ctx(Cfg.home(cfg), Http.Req.query(req, "q"), ctx))
    case EReindex{}:
      do IO<String>:
        IO.spawn(Unit, reindex(cfg, chan))
        ok("{\"ok\":true}")
    case EHealth{}:
      ok("{\"ok\":true,\"service\":\"reflexd\"}")
    case ESide{}:
      do IO<String>:
        ctx : M.Reply <- ask(chan, M.Context{})
        r : String <- side_ctx(cfg, chan, Js.text_at(body, "pane"), Js.text_at(body, "text"), ctx)
        ok(r)
    case EJevPing{}:
      jev_ping(cfg)
    case EFocus{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.focus(Cfg.sock(cfg), Js.text_at(body, "pane"))
        ok(pane_json(ok_detail(r, "focused")))
    case EKeys{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.press(Cfg.sock(cfg), Js.text_at(body, "pane"), Js.text_at(body, "key"))
        ok(pane_json(ok_detail(r, "pressed")))
    case EText{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.send_text(Cfg.sock(cfg), Js.text_at(body, "pane"), Js.text_at(body, "text"))
        ok(pane_json(ok_detail(r, "typed")))
    case EClose{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.close_pane(Cfg.sock(cfg), Js.text_at(body, "pane"))
        ok(pane_json(ok_detail(r, "closed")))
    case ESessions{}:
      do IO<String>:
        all : List<&2, P.Past> <- read_pasts(cfg)
        ok(Js.obj([Js.kv("ok", "true"), Js.kv("sessions", Js.arr(P.jsons(all)))]))
    case EResume{}:
      do IO<String>:
        r : String <- ask_text(chan, M.Enqueue{M.Resume{Js.text_at(body, "cwd"), Js.or_else(Js.text_at(body, "kind"), "claude"), Js.text_at(body, "session"), Js.or_else(Js.text_at(body, "mode"), "resume"), Js.text_at(body, "text")}, "resume " ++ Js.or_else(Js.text_at(body, "label"), R.leaf(Js.text_at(body, "cwd"))), 0})
        ok(r)
    case EStatic{}:
      serve_static(cfg, static_name(Http.Req.path(req)))
    case EMissing{}:
      IO.pure(String, Http.json(404, "{\"ok\":false,\"error\":\"no such endpoint\"}"))

def authorized(need: Bool, +cfg: Cfg, +req: Http.Req) -> Bool:
  match need:
    case False{}:
      True{}
    case True{}:
      String.eq(Http.token(req), Cfg.token(cfg))

def dispatch.auth(allowed: Bool, ep: Ep, +cfg: Cfg, +chan: Chan(Env), +req: Http.Req) -> IO(String):
  match allowed:
    case False{}:
      IO.pure(String, Http.json(401, "{\"ok\":false,\"error\":\"bad token\"}"))
    case True{}:
      endpoint(ep, cfg, chan, req, body_of(Http.Req.body(req)))

def dispatch.ep(+ep: Ep, +cfg: Cfg, +chan: Chan(Env), +req: Http.Req) -> IO(String):
  dispatch.auth(authorized(needs_token(ep), cfg, req), ep, cfg, chan, req)

def dispatch(+cfg: Cfg, +chan: Chan(Env), +req: Http.Req) -> IO(String):
  dispatch.ep(ep_of(Http.Req.path(req)), cfg, chan, req)

def sent(m: Socket & Result<&1, &1, (U32 & String) & String, Unit>) -> IO(Unit):
  (s, r) = m
  Socket.close(s)

def respond(s: Socket, resp: String) -> IO(Unit):
  do IO<Unit>:
    m : Socket & Result<&1, &1, (U32 & String) & String, Unit> <- TCP.send(s, resp)
    sent(m)

def conn.read(+cfg: Cfg, +chan: Chan(Env), m: Socket & Result<&1, &1, U32 & String, String>) -> IO(Unit):
  (s, r) = m
  match r:
    case Fail{e}:
      Socket.close(s)
    case Done{raw}:
      do IO<Unit>:
        resp : String <- dispatch(cfg, chan, Http.parse(raw))
        respond(s, resp)

def conn(+cfg: Cfg, +chan: Chan(Env), s: Socket) -> IO(Unit):
  do IO<Unit>:
    m : Socket & Result<&1, &1, U32 & String, String> <- H.Host.http_read(s, 1048576, 10000)
    conn.read(cfg, chan, m)

def accepted(+cfg: Cfg, +chan: Chan(Env), m: Listener & Result<&1, &1, U32 & String, Socket>) -> IO(Listener):
  (l, r) = m
  match r:
    case Fail{e}:
      IO.pure(Listener, l)
    case Done{s}:
      do IO<Listener>:
        IO.spawn(Unit, conn(cfg, chan, s))
        return l

def acceptor(fuel: Nat, +cfg: Cfg, +chan: Chan(Env), l: Listener) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        m : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
        l2 : Listener <- accepted(cfg, chan, m)
        acceptor(p, cfg, chan, l2)

# Parent watch
# ------------
# With REFLEX_EXIT_WITH_PARENT=1 (the app sets it), reflexd exits once its
# parent is gone, so a crashed app never leaves a daemon holding the port.

def watch.check(gone: Bool) -> IO(Unit):
  match gone:
    case True{}:
      IO.die(Unit, 0, "reflexd: parent exited")
    case False{}:
      IO.pure(Unit, Unit{})

def watchdog(fuel: Nat, +parent: U32) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        IO.sleep(2000)
        now : U32 <- H.Host.ppid()
        watch.check(Core.bool_not(U32.is_eq(now, parent)))
        watchdog(p, parent)

def watch.start(on: Bool, +parent: U32) -> IO(Unit):
  match on:
    case True{}:
      IO.spawn(Unit, watchdog(forever(), parent))
    case False{}:
      IO.pure(Unit, Unit{})

# main
# ----

def main() -> IO(Unit):
  do IO<Unit>:
    +cfg : Cfg <- load()
    mk : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("/bin/mkdir", ["-p", Cfg.data(cfg)], "", 4096, 5000)
    l : Listener <- IO.try(Listener, Cfg.listen(cfg))
    +chan : Chan(Env) <- Chan.new(Env, 4096)
    start : Nat <- IO.now()
    IO.print(Cfg.ready(cfg))
    IO.spawn(Unit, ticker(forever(), chan, start))
    IO.spawn(Unit, poller(forever(), cfg, chan, []))
    IO.spawn(Unit, indexer(forever(), cfg, chan))
    IO.spawn(Unit, acceptor(forever(), cfg, chan, l))
    exit_with_parent : String <- env("REFLEX_EXIT_WITH_PARENT", "")
    parent : U32 <- H.Host.ppid()
    watch.start(String.eq(exit_with_parent, "1"), parent)
    actor(forever(), cfg, chan, M.State.empty(Cfg.undo(cfg)))
