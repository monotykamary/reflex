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

# Where the app forwards other machines' herdr sockets (see Herdr: Machines),
# and `list` there names the machines it keeps a tunnel to.
def Cfg.machines(+c: Cfg) -> String:
  Cfg.data(c) ++ "/machines"

# The herdr socket a pane lives behind.
def Cfg.at(+c: Cfg, pane: String) -> String:
  Herdr.at(Cfg.sock(c), Cfg.machines(c), pane)

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
    st : Settle <- settle(30n, Cfg.at(cfg, pane), Herdr.bare(pane), Settle{"", 0})
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

# A freshly started agent refuses prompts (agent_not_ready) until it is
# ready: a moment while Herdr registers it — or as long as it waits on you,
# like Claude's "Do you trust this folder?" in a new folder (Herdr types
# nothing into that dialog; it refuses). Retry that, and only that, for up
# to ten minutes, so the request goes in once you answer.
type PTry is Data:
  PTry{settled: Bool, ok: Bool, detail: String}

def retryable(+msg: String) -> Bool:
  String.contains(msg, "agent_not_ready") || String.contains(msg, "not an active") || String.contains(msg, "agent_blocked")

def ptry_of(r: Result<&1, &1, U32 & String, J.JSON>) -> PTry:
  match r:
    case Done{v}:
      PTry{True{}, True{}, "sent"}
    case Fail{(code, +msg)}:
      PTry{Core.bool_not(retryable(msg)), False{}, msg}

def prompt_now(+sock: String, +pane: String, +text: String) -> IO(PTry):
  do IO<PTry>:
    r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.prompt(sock, pane, text)
    return ptry_of(r)

def ready_status(+s: String) -> Bool:
  String.eq(s, "idle") || String.eq(s, "done")

def prompt_when.settled(ok: Bool, +sock: String, +pane: String, +text: String, st: PTry) -> IO(PTry):
  match ok:
    case True{}:
      prompt_now(sock, pane, text)
    case False{}:
      IO.pure(PTry, st)

def prompt_when.ready(ready: Bool, +sock: String, +pane: String, +text: String, st: PTry) -> IO(PTry):
  match ready:
    case True{}:
      do IO<PTry>:
        IO.sleep(1500)
        again : String <- Herdr.pane_status(sock, pane)
        prompt_when.settled(ready_status(again), sock, pane, text, st)
    case False{}:
      IO.pure(PTry, st)

# Refused before (it was not ready, or waiting on you): send only once it has
# been idle for a moment. Right after a dialog closes Herdr may take a prompt
# the agent's input never sees.
def prompt_held(first: Bool, +sock: String, +pane: String, +text: String, st: PTry) -> IO(PTry):
  match first:
    case True{}:
      prompt_now(sock, pane, text)
    case False{}:
      do IO<PTry>:
        s : String <- Herdr.pane_status(sock, pane)
        prompt_when.ready(ready_status(s), sock, pane, text, st)

def prompt_step(+sock: String, +pane: String, +text: String, st: PTry) -> IO(PTry):
  match st:
    case PTry{True{}, ok, detail}:
      IO.pure(PTry, PTry{True{}, ok, detail})
    case PTry{False{}, ok, +detail}:
      do IO<PTry>:
        IO.sleep(700)
        prompt_held(String.is_empty(detail), sock, pane, text, PTry{False{}, ok, detail})

def prompt_retry(fuel: Nat, +sock: String, +pane: String, +text: String, st: PTry) -> IO(PTry):
  match fuel:
    case 0n:
      IO.pure(PTry, st)
    case 1n+p:
      do IO<PTry>:
        next : PTry <- prompt_step(sock, pane, text, st)
        prompt_retry(p, sock, pane, text, next)

# A prompt taken as typing, or never taken
# ----------------------------------------
# Herdr pastes a prompt, then presses Enter 300 ms later. A TUI that is busy
# (just started, or on a Mac under load) can read both as one paste, and in
# a paste Enter is a new line: the words sit in its input and nothing runs.
# Or the paste lands before its input is listening and is lost: an idle,
# empty agent. So after each prompt, in the background, while the agent
# stays idle (at most six looks, 2.5 s apart): the request in its input box
# gets an Enter (an Enter on an empty input does nothing); the request
# nowhere on screen, twice running (a slow paste is not a lost one), is sent
# once more.

def screen_of(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{t}:
      t
    case Fail{e}:
      ""

# Whether to look again, whether the last look found the request nowhere,
# and whether it has been sent again (only ever once).
type Watch is Data:
  Watch{go: Bool, missing: Bool, resent: Bool}

def confirm.gone(missing: Bool, resent: Bool, +sock: String, +pane: String, +text: String) -> IO(Watch):
  match missing resent:
    case True{} False{}:
      do IO<Watch>:
        k : Result<&1, &1, U32 & String, J.JSON> <- Herdr.prompt(sock, pane, text)
        IO.print("prompt in " ++ pane ++ " never arrived: sent it again")
        return Watch{True{}, False{}, True{}}
    case True{} True{}:
      IO.pure(Watch, Watch{True{}, True{}, True{}})
    case False{} r:
      IO.pure(Watch, Watch{True{}, True{}, r})

def confirm.act(typed: Bool, gone: Bool, missing: Bool, resent: Bool, +sock: String, +pane: String, +text: String) -> IO(Watch):
  match typed gone:
    case True{} _:
      do IO<Watch>:
        k : Result<&1, &1, U32 & String, J.JSON> <- Herdr.press(sock, pane, "enter")
        IO.print("prompt in " ++ pane ++ " was typed but not sent: pressed Enter")
        return Watch{True{}, False{}, resent}
    case False{} True{}:
      confirm.gone(missing, resent, sock, pane, text)
    case False{} False{}:
      IO.pure(Watch, Watch{False{}, False{}, resent})

def confirm(fuel: Nat, w: Watch, +sock: String, +pane: String, +text: String, +probe: String) -> IO(Unit):
  match fuel w:
    case 0n _:
      IO.pure(Unit, Unit{})
    case 1n+p Watch{False{}, missing, resent}:
      IO.pure(Unit, Unit{})
    case 1n+p Watch{True{}, missing, resent}:
      do IO<Unit>:
        IO.sleep(2500)
        +s : String <- Herdr.pane_status(sock, pane)
        r : Result<&1, &1, U32 & String, String> <- Herdr.read_pane(sock, pane, "visible", 60)
        +screen : String <- IO.pure(String, screen_of(r))
        next : Watch <- confirm.act(Core.prompt_typed(s, screen, probe), Core.prompt_missing(s, screen, probe), missing, resent, sock, pane, text)
        confirm(p, next, sock, pane, text, probe)

def confirm.start(go: Bool, +sock: String, +pane: String, +text: String) -> IO(Unit):
  match go:
    case True{}:
      do IO<Unit>:
        IO.spawn(Unit, confirm(6n, Watch{True{}, False{}, False{}}, sock, pane, text, Core.probe(text)))
        return Unit{}
    case False{}:
      IO.pure(Unit, Unit{})


# A prompt to a live session: delivered, then watched until it runs.
def prompted(+sock: String, +pane: String, +text: String, r: Result<&1, &1, U32 & String, J.JSON>) -> IO(Result<&1, &1, U32 & String, String>):
  match r:
    case Done{v}:
      do IO<Result<&1, &1, U32 & String, String>>:
        confirm.start(True{}, sock, pane, text)
        return ok_detail(Done{v}, "sent")
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, String>, ok_detail(Fail{e}, "sent"))

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
      Fail{(1, "started " ++ name ++ " but could not give it your request (" ++ detail ++ ") — is it still waiting on you?")}

def PTry.ok(st: PTry) -> Bool:
  match st:
    case PTry{settled, ok, detail}:
      ok

# Started with nothing to say (a folder chosen with the bar empty): the agent
# is ready for you in its terminal; there is no prompt to deliver.
def prompt_if(empty: Bool, +sock: String, +pane: String, +text: String) -> IO(PTry):
  match empty:
    case True{}:
      IO.pure(PTry, PTry{True{}, True{}, ""})
    case False{}:
      prompt_retry(860n, sock, pane, text, PTry{False{}, False{}, ""})

# A session starts in the herdr of the Mac its folder is on: `sock` is that
# herdr's socket, `m` the machine ("" for this Mac) and `pane` herdr's own id
# there; the receipt names the pane as reflexd knows it ("work/w3:p1").
def spawned(+cfg: Cfg, +sock: String, +m: String, +cwd: String, +name: String, +pane: String, +text: String, r: Result<&1, &1, U32 & String, J.JSON>) -> IO(Result<&1, &1, U32 & String, String>):
  match r:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, String>, Fail{e})
    case Done{v}:
      do IO<Result<&1, &1, U32 & String, String>>:
        +st : PTry <- prompt_if(String.is_empty(String.trim(text)), sock, pane, text)
        record_use(PTry.ok(st), cfg, cwd)
        confirm.start(PTry.ok(st) && Core.bool_not(String.is_empty(String.trim(text))), sock, pane, text)
        return spawn_result(name, Herdr.pane_on(m, pane), st)

def spawn_in(+cfg: Cfg, +sock: String, +m: String, +id: U32, +cwd: String, +kind: String, +text: String, w: Result<&1, &1, U32 & String, String>) -> IO(Result<&1, &1, U32 & String, String>):
  match w:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, String>, Fail{e})
    case Done{+pane}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
        +name : String <- IO.pure(String, agent_name(id, r))
        st : Result<&1, &1, U32 & String, J.JSON> <- Herdr.start_agent(sock, name, kind, pane)
        spawned(cfg, sock, m, cwd, name, pane, text, st)

def resumed_result(+name: String, +pane: String, r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, String>:
  match r:
    case Done{v}:
      Done{"resumed " ++ name ++ " in " ++ pane}
    case Fail{e}:
      Fail{e}

# Started: prompt it when there is a request, else it is simply back.
def resumed(empty: Bool, +cfg: Cfg, +sock: String, +m: String, +cwd: String, +name: String, +pane: String, +text: String, r: Result<&1, &1, U32 & String, J.JSON>) -> IO(Result<&1, &1, U32 & String, String>):
  match empty:
    case True{}:
      IO.pure(Result<&1, &1, U32 & String, String>, resumed_result(name, Herdr.pane_on(m, pane), r))
    case False{}:
      spawned(cfg, sock, m, cwd, name, pane, text, r)

def resume_in(+cfg: Cfg, +sock: String, +m: String, +id: U32, +cwd: String, +kind: String, +args: List<&2, String>, +text: String, w: Result<&1, &1, U32 & String, String>) -> IO(Result<&1, &1, U32 & String, String>):
  match w:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, String>, Fail{e})
    case Done{+pane}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
        +name : String <- IO.pure(String, agent_name(id, r))
        st : Result<&1, &1, U32 & String, J.JSON> <- Herdr.start_agent_args(sock, name, kind, pane, args)
        resumed(String.is_empty(text), cfg, sock, m, cwd, name, pane, text, st)

# A new project folder may not exist yet; mkdir -p is a no-op otherwise. On
# another Mac the folder comes from its own index: it is there.
def mkdir_here(here: Bool, +path: String) -> IO(Unit):
  match here:
    case True{}:
      do IO<Unit>:
        m : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("/bin/mkdir", ["-p", path], "", 4096, 5000)
        return Unit{}
    case False{}:
      IO.pure(Unit, Unit{})

# A headless fork runs where the session's files are: on this Mac. One on
# another machine isn't forked (yet): its own terminal can take the question.
def side_fork(here: Bool, +cfg: Cfg, +chan: Chan(Env), +pane: String, +label: String, kind: String, cwd: String, session: String, text: String) -> IO(Result<&1, &1, U32 & String, String>):
  match here:
    case True{}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(Cfg.fork(cfg), [kind, cwd, session, text], "", 4194304, 300000)
        post_fork_reply(chan, pane, label, stdout_of(r))
    case False{}:
      IO.pure(Result<&1, &1, U32 & String, String>, Fail{(1, "a side question for an agent on " ++ Herdr.machine(pane) ++ " needs it free to take /btw: ask in its terminal")})

def perform(+cfg: Cfg, +chan: Chan(Env), +id: U32, +label: String, a: M.Action) -> IO(Result<&1, &1, U32 & String, String>):
  match a:
    case M.Prompt{+pane, +text}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.prompt(Cfg.at(cfg, pane), Herdr.bare(pane), text)
        prompted(Cfg.at(cfg, pane), Herdr.bare(pane), text, r)
    case M.Press{+pane, +key}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.press(Cfg.at(cfg, pane), Herdr.bare(pane), key)
        return ok_detail(r, "pressed " ++ key)
    case M.SideNative{+pane, text}:
      do IO<Result<&1, &1, U32 & String, String>>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.prompt(Cfg.at(cfg, pane), Herdr.bare(pane), "/btw " ++ text)
        IO.spawn(Unit, capture_btw(cfg, chan, pane, label))
        return ok_detail(r, "asked with /btw")
    case M.SideFork{+pane, kind, cwd, session, text}:
      side_fork(String.is_empty(Herdr.machine(pane)), cfg, chan, pane, label, kind, cwd, session, text)
    # A folder on another Mac ("work:/Users/you/VCS/app") starts there.
    case M.Resume{+cwd, +kind, +session, +mode, +text}:
      do IO<Result<&1, &1, U32 & String, String>>:
        +m : String = Ix.machine_of(cwd)
        +sock : String = Herdr.at.of(Cfg.sock(cfg), Cfg.machines(cfg), m)
        w : Result<&1, &1, U32 & String, String> <- Herdr.new_workspace(sock, Ix.path_on(cwd), Core.base_name(cwd))
        resume_in(cfg, sock, m, id, cwd, kind, R.resume_args(kind, mode, session), text, w)
    case M.Spawn{+cwd, +kind, +text}:
      do IO<Result<&1, &1, U32 & String, String>>:
        +m : String = Ix.machine_of(cwd)
        +sock : String = Herdr.at.of(Cfg.sock(cfg), Cfg.machines(cfg), m)
        mkdir_here(String.is_empty(m), cwd)
        w : Result<&1, &1, U32 & String, String> <- Herdr.new_workspace(sock, Ix.path_on(cwd), Core.base_name(cwd))
        spawn_in(cfg, sock, m, id, cwd, kind, text, w)

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
    # A blocked agent's screen is read every poll: its question can change
    # while it stays blocked (the next question, a ticked box, the review).
    case Some{+p}:
      Core.is_blocked(Core.Agent.status(a)) || ((Core.bool_not(U32.is_eq(Core.Agent.seq(p), Core.Agent.seq(a))) || Core.bool_not(String.eq(M.Status.show(Core.Agent.status(p)), M.Status.show(Core.Agent.status(a))))) && Core.is_ready(Core.Agent.status(a)))

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

def screen_for(want: Bool, +cfg: Cfg, a: M.Agent) -> IO(M.Agent):
  match want a:
    case False{} _:
      IO.pure(M.Agent, a)
    case True{} M.Agent{+pane, name, kind, +status, cwd, title, seq, session, screen}:
      do IO<M.Agent>:
        r : Result<&1, &1, U32 & String, String> <- Herdr.read_pane(Cfg.at(cfg, pane), Herdr.bare(pane), source_for(status), 40)
        return with_screen(M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}, r)

def screens(cur: List<&2, M.Agent>, +cfg: Cfg, +prev: List<&2, M.Agent>) -> IO(List<&2, M.Agent>):
  match cur:
    case Nil{}:
      IO.pure(List<&2, M.Agent>, [])
    case Con{+a, t}:
      do IO<List<&2, M.Agent>>:
        h : M.Agent <- screen_for(wants_screen(Core.find_agent(prev, Core.Agent.pane(a)), a), cfg, a)
        rest : List<&2, M.Agent> <- screens(t, cfg, prev)
        return h <> rest

type Snap is Data:
  Snap{ok: Bool, agents: List<&2, M.Agent>}

# Claude's own word on its sessions: ~/.claude/sessions/<pid>.json says
# "busy" while a turn runs and "shell" while a shell it started in the
# background still runs after the turn — which Herdr reports as done (Claude wakes and carries on when
# the shell finishes). Only files of live processes count.
# pi reports the same way through Reflex's pi extension (integrations/pi):
# ~/.pi/agent/reflex/sessions/<pid>.json while pi-fabric's background shells run.
def busy_script() -> String:
  "for f in \"$HOME\"/.claude/sessions/*.json \"$HOME\"/.pi/agent/reflex/sessions/*.json; do [ -f \"$f\" ] || continue; p=${f##*/}; p=${p%.json}; kill -0 \"$p\" 2>/dev/null && { cat \"$f\"; echo; }; done"

def busy_pick(busy: Bool, +sid: String) -> String:
  match busy:
    case True{}:
      sid
    case False{}:
      ""

def busy_of.r(r: Result<&1, &1, U32 & String, J.JSON>) -> String:
  match r:
    case Done{+v}:
      # "busy" during a turn; "shell" after it, while a background shell runs.
      # A session parked into a background job (parkedJobId) keeps the
      # "busy" it had when it was parked — its work runs in that job, which
      # reports itself — so its own "busy" is not believed.
      busy_pick((String.eq(Js.text_at(v, "status"), "busy") && String.is_empty(Js.text_at(v, "parkedJobId"))) || String.eq(Js.text_at(v, "status"), "shell"), Js.text_at(v, "sessionId"))
    case Fail{e}:
      ""

def busy_of(line: String) -> String:
  busy_of.r(Js.read(line))

def busy_put.if(empty: Bool, sid: String, rest: List<&2, String>) -> List<&2, String>:
  match empty:
    case True{}:
      rest
    case False{}:
      sid <> rest

def busy_put(+sid: String, rest: List<&2, String>) -> List<&2, String>:
  busy_put.if(String.is_empty(sid), sid, rest)

def busy_list(lines: List<&2, String>) -> List<&2, String>:
  match lines:
    case Nil{}:
      []
    case Con{l, t}:
      busy_put(busy_of(l), busy_list(t))

def read_busy() -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    out : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("/bin/sh", ["-c", busy_script()], "", 1048576, 3000)
    return busy_list(String.lines(text_or(stdout_of(out), "")))

# An agent's session is its id (Claude) or its session file (pi, as herdr
# reports it: …/<time>_<id>.jsonl); the status files carry the id.
def same_session(+session: String, +id: String) -> Bool:
  String.eq(session, id) || String.ends_with(session, "_" ++ id ++ ".jsonl")

def member(+x: String, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+h, t}:
      same_session(x, h) || member(x, t)

# Done or idle, but its shell still runs: still working.
def still_working(s: M.Status) -> M.Status:
  match s:
    case M.Finished{}:
      M.Working{}
    case M.Idle{}:
      M.Working{}
    case other:
      other

def busy_status(busy: Bool, s: M.Status) -> M.Status:
  match busy:
    case True{}:
      still_working(s)
    case False{}:
      s

def mark_busy(a: M.Agent, +busy: List<&2, String>) -> M.Agent:
  match a:
    case M.Agent{pane, name, +kind, status, cwd, title, seq, +session, screen}:
      M.Agent{pane, name, kind, busy_status((String.eq(kind, "claude") || String.eq(kind, "pi")) && R.bool_not(String.is_empty(session)) && member(session, busy), status), cwd, title, seq, session, screen}

def marks(xs: List<&2, M.Agent>, +busy: List<&2, String>) -> List<&2, M.Agent>:
  match xs:
    case Nil{}:
      []
    case Con{a, t}:
      mark_busy(a, busy) <> marks(t, busy)

# This Mac's agents (marked busy from its own session files), then the other
# machines'. If this Mac's herdr didn't answer, everything stays as it was.
def snap(r: Result<&1, &1, U32 & String, List<&2, M.Agent>>, remote: List<&2, M.Agent>, +cfg: Cfg, +prev: List<&2, M.Agent>) -> IO(Snap):
  match r:
    case Fail{e}:
      IO.pure(Snap, Snap{False{}, prev})
    case Done{cur}:
      do IO<Snap>:
        +busy : List<&2, String> <- read_busy()
        xs : List<&2, M.Agent> <- screens(List.append(&2, M.Agent, marks(cur, busy), remote), cfg, prev)
        return Snap{True{}, xs}

# Machines
# --------
# Other Macs' herdr (saved machines), polled through the sockets the app
# forwards: their agents join this Mac's with the machine in their pane id.

def trims(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      String.trim(x) <> trims(t)

def machine_names(r: Result<&1, &1, U32 & String, String>) -> List<&2, String>:
  Herdr.words(trims(String.lines(text_or(r, ""))))

def read_machines(+cfg: Cfg) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    r : Result<&1, &1, U32 & String, String> <- Fs.read(Cfg.machines(cfg) ++ "/list", 65536)
    return machine_names(r)

# A machine that didn't answer (its tunnel is reconnecting, it sleeps) keeps
# the agents it had, so coming back isn't a burst of new agents.
def remote_of(r: Result<&1, &1, U32 & String, List<&2, M.Agent>>, +m: String, prev: List<&2, M.Agent>) -> List<&2, M.Agent>:
  match r:
    case Fail{e}:
      Herdr.on(m, prev)
    case Done{xs}:
      Herdr.tags(m, xs)

def remotes(ms: List<&2, String>, +cfg: Cfg, +prev: List<&2, M.Agent>) -> IO(List<&2, M.Agent>):
  match ms:
    case Nil{}:
      IO.pure(List<&2, M.Agent>, [])
    case Con{+m, t}:
      do IO<List<&2, M.Agent>>:
        r : Result<&1, &1, U32 & String, List<&2, M.Agent>> <- Herdr.list_agents(Herdr.machine_sock(Cfg.machines(cfg), m))
        rest : List<&2, M.Agent> <- remotes(t, cfg, prev)
        return List.append(&2, M.Agent, remote_of(r, m, prev), rest)

def poll.post(+chan: Chan(Env), +s: Snap) -> IO(List<&2, M.Agent>):
  match s:
    case Snap{ok, +agents}:
      do IO<List<&2, M.Agent>>:
        post(chan, M.Polled{ok, agents})
        return agents

def poller(fuel: Nat, +cfg: Cfg, +chan: Chan(Env), +prev: List<&2, M.Agent>) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, List<&2, M.Agent>> <- Herdr.list_agents(Cfg.sock(cfg))
        ms : List<&2, String> <- read_machines(cfg)
        remote : List<&2, M.Agent> <- remotes(ms, cfg, prev)
        s : Snap <- snap(r, remote, cfg, prev)
        cur : List<&2, M.Agent> <- poll.post(chan, s)
        IO.sleep(700)
        poller(p, cfg, chan, cur)

# The index is this Mac's scan (kept in folders.tsv) and, for each machine
# with a tunnel, the folders the app scanned there (machines/<m>.folders,
# paths written "<m>:<path>"). A machine's folders changing re-reads them
# without scanning this Mac again.
def folders_cache(+cfg: Cfg) -> String:
  Cfg.data(cfg) ++ "/folders.tsv"

def machine_folders(ms: List<&2, String>, +cfg: Cfg) -> IO(String):
  match ms:
    case Nil{}:
      IO.pure(String, "")
    case Con{+m, t}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, String> <- Fs.read(Cfg.machines(cfg) ++ "/" ++ m ++ ".folders", 8388608)
        rest : String <- machine_folders(t, cfg)
        return text_or(r, "") ++ "\n" ++ rest

def merge(+cfg: Cfg, +chan: Chan(Env), here: String) -> IO(Unit):
  do IO<Unit>:
    ms : List<&2, String> <- read_machines(cfg)
    there : String <- machine_folders(ms, cfg)
    post(chan, M.Indexed{Ix.parse(here ++ "\n" ++ there)})

def reindex(+cfg: Cfg, +chan: Chan(Env)) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(Cfg.scan(cfg), [], "", 33554432, 180000)
    +here : String = text_or(stdout_of(r), "")
    w : Result<&1, &1, U32 & String, Unit> <- Fs.put(folders_cache(cfg), "w", here)
    merge(cfg, chan, here)

# Only the other Macs' folders changed: this Mac's from its last scan.
def remerge(+cfg: Cfg, +chan: Chan(Env)) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, String> <- Fs.read(folders_cache(cfg), 33554432)
    merge(cfg, chan, text_or(r, ""))

def reindex_pick(machines: Bool, +cfg: Cfg, +chan: Chan(Env)) -> IO(Unit):
  match machines:
    case True{}:
      remerge(cfg, chan)
    case False{}:
      reindex(cfg, chan)

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

def read_seen(xs: List<&2, M.Agent>, +cfg: Cfg) -> IO(List<&2, R.Seen>):
  match xs:
    case Nil{}:
      IO.pure(List<&2, R.Seen>, [])
    case Con{+a, t}:
      do IO<List<&2, R.Seen>>:
        r : Result<&1, &1, U32 & String, String> <- Herdr.read_pane(Cfg.at(cfg, Core.Agent.pane(a)), Herdr.bare(Core.Agent.pane(a)), "recent_unwrapped", 40)
        rest : List<&2, R.Seen> <- read_seen(t, cfg)
        return seen_of(a, r) <> rest

# What a request may go to. No machine named: every live session, and this
# Mac's folders and earlier sessions (new work starts here). "@work" in the
# bar: only work's sessions, folders and earlier sessions.
def scope_agents.if(all: Bool, +m: String, xs: List<&2, M.Agent>) -> List<&2, M.Agent>:
  match all:
    case True{}:
      xs
    case False{}:
      Herdr.on(m, xs)

def scope_agents(+m: String, xs: List<&2, M.Agent>) -> List<&2, M.Agent>:
  scope_agents.if(String.is_empty(m), m, xs)

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

def route_ctx(dry: Bool, +cfg: Cfg, +chan: Chan(Env), +text: String, +harness: String, +memory: String, +machine: String, ctx: M.Reply) -> IO(String):
  match ctx:
    case M.RContext{agents, folders}:
      do IO<String>:
        +seen : List<&2, R.Seen> <- read_seen(take_agents(scope_agents(machine, agents), 12n), cfg)
        +cands : List<&2, M.Folder> = Ix.rank(text, Ix.on(machine, folders), 8n)
        all : List<&2, P.Past> <- read_pasts(cfg)
        +pasts : List<&2, P.Past> = P.rank(text, P.on(machine, all), 5n)
        +line : String = R.request(text, Cfg.home(cfg), seen, cands, pasts, memory)
        out : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(Cfg.jev(cfg), jev_args(), line, 4194304, 65000)
        +d : R.Decision = R.decide_output(text_or(stdout_of(out), ""), text, Cfg.home(cfg), harness, Cfg.threshold(cfg), seen, cands, pasts)
        retry(R.transient(d), d, dry, cfg, chan, text, harness, line, seen, cands, pasts)
    case M.RText{json}:
      IO.pure(String, "{\"ok\":false,\"error\":\"no context\"}")

def route(dry: Bool, +cfg: Cfg, +chan: Chan(Env), +text: String, +harness: String, +memory: String, +machine: String) -> IO(String):
  do IO<String>:
    ctx : M.Reply <- ask(chan, M.Context{})
    route_ctx(dry, cfg, chan, text, harness, memory, machine, ctx)

# Jev's ranking of every candidate, live, for the Ask bar's list. Dry.
def candidates_ctx(+cfg: Cfg, +text: String, +harness: String, +memory: String, +machine: String, ctx: M.Reply) -> IO(String):
  match ctx:
    case M.RContext{agents, folders}:
      do IO<String>:
        +seen : List<&2, R.Seen> <- read_seen(take_agents(scope_agents(machine, agents), 12n), cfg)
        +cands : List<&2, M.Folder> = Ix.rank(text, Ix.on(machine, folders), 8n)
        all : List<&2, P.Past> <- read_pasts(cfg)
        +pasts : List<&2, P.Past> = P.rank(text, P.on(machine, all), 5n)
        +line : String = R.request(text, Cfg.home(cfg), seen, cands, pasts, memory)
        t0 : Nat <- IO.now()
        out : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(Cfg.jev(cfg), jev_args(), line, 4194304, 65000)
        t1 : Nat <- IO.now()
        return R.candidates_output(text_or(stdout_of(out), ""), text, Cfg.home(cfg), harness, Cfg.threshold(cfg), seen, cands, pasts, U32.from_nat(Nat.sub(t1, t0)))
    case M.RText{json}:
      IO.pure(String, "{\"ok\":false,\"error\":\"no context\"}")

# The JSON request for the candidates routing would show Jev (for a UI or a
# debugging session), without calling Jev.
def explain_ctx(+cfg: Cfg, +text: String, +memory: String, +machine: String, ctx: M.Reply) -> IO(String):
  match ctx:
    case M.RContext{agents, folders}:
      do IO<String>:
        +seen : List<&2, R.Seen> <- read_seen(take_agents(scope_agents(machine, agents), 12n), cfg)
        all : List<&2, P.Past> <- read_pasts(cfg)
        return "{\"ok\":true,\"jev\":" ++ String.trim(R.request(text, Cfg.home(cfg), seen, Ix.rank(text, Ix.on(machine, folders), 8n), P.rank(text, P.on(machine, all), 5n), memory)) ++ "}"
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

# The Ask bar's folders: every Mac's (no machine), this Mac's ("."), or one
# machine's.
def folder_scope.pick(all: Bool, here: Bool, +m: String, fs: List<&2, M.Folder>) -> List<&2, M.Folder>:
  match all here:
    case True{} _:
      fs
    case False{} True{}:
      Ix.on("", fs)
    case False{} False{}:
      Ix.on(m, fs)

def folder_scope(+m: String, fs: List<&2, M.Folder>) -> List<&2, M.Folder>:
  folder_scope.pick(String.is_empty(m), String.eq(m, "."), m, fs)

def folders_ctx(+home: String, +q: String, +machine: String, ctx: M.Reply) -> String:
  match ctx:
    case M.RContext{agents, folders}:
      "{\"ok\":true,\"folders\":" ++ Js.arr(folders_json(home, Ix.rank(q, folder_scope(machine, folders), 12n))) ++ "}"
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
  EPair{}
  ENote{}
  EKeys{}
  EText{}
  ETerm{}
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
    Row{"/api/pair", EPair{}},
    Row{"/api/note", ENote{}},
    Row{"/api/keys", EKeys{}},
    Row{"/api/text", EText{}},
    Row{"/api/term", ETerm{}},
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

# Pairing a phone: the app writes a one-time code to pair.txt (and wipes it
# after ten minutes); the phone trades it for its token here, once — the
# file is wiped as the token goes out. The QR never carries the token.
def pair_file(+cfg: Cfg) -> String:
  Cfg.data(cfg) ++ "/pair.txt"

def pair_reply(hit: Bool, +cfg: Cfg) -> IO(String):
  match hit:
    case True{}:
      do IO<String>:
        w : Result<&1, &1, U32 & String, Unit> <- Fs.put(pair_file(cfg), "w", "")
        ok(Js.obj([Js.kv("ok", "true"), Js.kv("token", Js.str(Cfg.token(cfg)))]))
    case False{}:
      IO.pure(String, Http.json(403, "{\"ok\":false,\"error\":\"used or expired\"}"))

def pair_check(+code: String, +given: String, +cfg: Cfg) -> IO(String):
  pair_reply(String.eq(code, given) && R.bool_not(String.is_empty(code)), cfg)

def needs_token(ep: Ep) -> Bool:
  match ep:
    case EStatic{}:
      False{}
    case EHealth{}:
      False{}
    case EPair{}:
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

# The phone's terminal (xterm.js) is vendored with its version in each file's
# name, so the phone keeps it; the page itself is always fresh.
def static_cache.pick(vendored: Bool) -> String:
  match vendored:
    case True{}:
      "public, max-age=31536000, immutable"
    case False{}:
      "no-store"

def static_read(+name: String, r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{body}:
      Http.response_with(200, Http.content_type(name), static_cache.pick(String.starts_with(name, "xterm-")), body)
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

# The phone reads a terminal it sized as it shows (`visible`, scrolled where
# herdr is); otherwise its recent rows.
def pane_read(ansi: Bool, sock: String, pane: String, +source: String, lines: U32) -> IO(Result<&1, &1, U32 & String, String>):
  match ansi:
    case True{}:
      Herdr.read_pane_ansi(sock, pane, Js.or_else.pick(Core.bool_not(String.eq(source, "visible")), source, "recent"), lines)
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

# The phone's size, and its swipes: one short-lived `herdr terminal session
# control` at the phone's columns and rows, carrying a scroll per notch (herdr
# makes each a wheel event for an agent that takes the mouse, or moves its own
# scrollback for a shell). A terminal another client holds (the Mac's window)
# is left as it is unless `take`, and the reply says it is held.
def scroll_cmds(n: Nat, +dir: String) -> String:
  match n:
    case 0n:
      ""
    case 1n+p:
      "{\"type\":\"terminal.scroll\",\"lines\":3,\"direction\":\"" ++ dir ++ "\"}\n" ++ scroll_cmds(p, dir)

def scroll_input.pick(none: Bool, +dir: String, n: U32) -> String:
  match none:
    case True{}:
      ""
    case False{}:
      scroll_cmds(U32.to_nat(U32.min(n, 40)), dir)

def scroll_input(+s: String, n: U32) -> String:
  scroll_input.pick(Core.bool_not(String.eq(s, "up") || String.eq(s, "down")), s, n)

def control_args.take(take: Bool, sock: String, pane: String, cols: String, rows: String) -> List<&1, String>:
  match take:
    case True{}:
      ["-u", "HERDR_SESSION", "HERDR_SOCKET_PATH=" ++ sock, "herdr", "terminal", "session", "control", pane, "--cols", cols, "--rows", rows, "--takeover"]
    case False{}:
      ["-u", "HERDR_SESSION", "HERDR_SOCKET_PATH=" ++ sock, "herdr", "terminal", "session", "control", pane, "--cols", cols, "--rows", rows]

def control_args(sock: String, pane: String, cols: U32, rows: U32, take: Bool) -> List<&1, String>:
  control_args.take(take, sock, pane, U32.show(U32.max(20, U32.min(cols, 400))), U32.show(U32.max(5, U32.min(rows, 200))))

def control_json(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> String:
  match r:
    case Fail{(c, m)}:
      Js.obj([Js.kv("ok", "false"), Js.kv("error", Js.str(m))])
    case Done{(+status, (+out, err))}:
      Js.obj([Js.kv("ok", Js.bool(U32.is_eq(status, 0))), Js.kv("held", Js.bool(String.contains(out, "already has an attached client"))), Js.kv("error", Js.str(String.trim(err)))])

def endpoint(ep: Ep, +cfg: Cfg, +chan: Chan(Env), +req: Http.Req, +body: J.JSON) -> IO(String):
  match ep:
    case EState{}:
      do IO<String>:
        r : String <- ask_text(chan, M.Query{})
        ok(r)
    case ERoute{}:
      do IO<String>:
        r : String <- route(is_true(Js.text_at(body, "dry")), cfg, chan, Js.text_at(body, "text"), Js.or_else(Js.text_at(body, "harness"), Cfg.harness(cfg)), Js.text_at(body, "memory"), Js.text_at(body, "machine"))
        ok(r)
    case ECandidates{}:
      do IO<String>:
        ctx : M.Reply <- ask(chan, M.Context{})
        r : String <- candidates_ctx(cfg, Js.text_at(body, "text"), Js.or_else(Js.text_at(body, "harness"), Cfg.harness(cfg)), Js.text_at(body, "memory"), Js.text_at(body, "machine"), ctx)
        ok(r)
    case EExplain{}:
      do IO<String>:
        ctx : M.Reply <- ask(chan, M.Context{})
        r : String <- explain_ctx(cfg, Js.text_at(body, "text"), Js.text_at(body, "memory"), Js.text_at(body, "machine"), ctx)
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
        IO.print("answer item " ++ U32.show(Js.as_u32(Js.get(body, "item"), 0)) ++ " key " ++ Js.text_at(body, "key") ++ " from " ++ Http.Req.header(req, "user-agent"))
        r : String <- ask_text(chan, M.Answer{Js.as_u32(Js.get(body, "item"), 0), Js.text_at(body, "key")})
        ok(r)
    case EDismiss{}:
      do IO<String>:
        r : String <- ask_text(chan, M.Dismiss{Js.as_u32(Js.get(body, "item"), 0)})
        ok(r)
    case EPane{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, String> <- pane_read(String.eq(Http.Req.query(req, "format"), "ansi"), Cfg.at(cfg, Http.Req.query(req, "id")), Herdr.bare(Http.Req.query(req, "id")), Http.Req.query(req, "source"), Js.u32_or(U32.read(Http.Req.query(req, "lines")), 120))
        ok(pane_json(r))
    case EFolders{}:
      do IO<String>:
        ctx : M.Reply <- ask(chan, M.Context{})
        ok(folders_ctx(Cfg.home(cfg), Http.Req.query(req, "q"), Http.Req.query(req, "machine"), ctx))
    case EReindex{}:
      do IO<String>:
        IO.spawn(Unit, reindex_pick(is_true(Js.text_at(body, "machines")), cfg, chan))
        ok("{\"ok\":true}")
    case EHealth{}:
      ok("{\"ok\":true,\"service\":\"reflexd\"}")
    case EPair{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, String> <- Fs.read(pair_file(cfg), 4096)
        pair_check(String.trim(text_or(r, "")), Js.text_at(body, "code"), cfg)
    case ESide{}:
      do IO<String>:
        ctx : M.Reply <- ask(chan, M.Context{})
        r : String <- side_ctx(cfg, chan, Js.text_at(body, "pane"), Js.text_at(body, "text"), ctx)
        ok(r)
    case EJevPing{}:
      jev_ping(cfg)
    case EFocus{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.focus(Cfg.at(cfg, Js.text_at(body, "pane")), Herdr.bare(Js.text_at(body, "pane")))
        ok(pane_json(ok_detail(r, "focused")))
    # A note from the app (a background session finished or needs you):
    # an inbox item that stays until you open or clear it.
    case ENote{}:
      do IO<String>:
        r : String <- ask_text(chan, M.Post{M.INote{}, Js.text_at(body, "pane"), Js.text_at(body, "agent"), Js.text_at(body, "title"), Js.text_at(body, "body"), []})
        ok(r)
    case EKeys{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.press(Cfg.at(cfg, Js.text_at(body, "pane")), Herdr.bare(Js.text_at(body, "pane")), Js.text_at(body, "key"))
        ok(pane_json(ok_detail(r, "pressed")))
    case EText{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.send_text(Cfg.at(cfg, Js.text_at(body, "pane")), Herdr.bare(Js.text_at(body, "pane")), Js.text_at(body, "text"))
        ok(pane_json(ok_detail(r, "typed")))
    case ETerm{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("/usr/bin/env", control_args(Cfg.at(cfg, Js.text_at(body, "pane")), Herdr.bare(Js.text_at(body, "pane")), Js.as_u32(Js.get(body, "cols"), 0), Js.as_u32(Js.get(body, "rows"), 0), is_true(Js.text_at(body, "take"))), scroll_input(Js.text_at(body, "scroll"), Js.as_u32(Js.get(body, "n"), 0)), 1048576, 8000)
        ok(control_json(r))
    case EClose{}:
      do IO<String>:
        r : Result<&1, &1, U32 & String, J.JSON> <- Herdr.close_pane(Cfg.at(cfg, Js.text_at(body, "pane")), Herdr.bare(Js.text_at(body, "pane")))
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

def sent(m: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>) -> IO(Unit):
  (s, r) = m
  Socket.close(s)

def respond(s: Socket, resp: String) -> IO(Unit):
  do IO<Unit>:
    m : Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit> <- TCP.send(s, resp)
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
