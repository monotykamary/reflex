import Base
import ./Host.bend as H
import ./Js.bend as Js
import ./Model.bend as M
import ./Fs.bend as Fs
import ./vendor/strict-json/json.bend as J

# herdr-core (`hc`) socket client: JSON-RPC 2.0, one request per connection
# in plain mode. Requests are built and responses read by pure code; `call`
# is the only effect.
#
# The core runs terminals, not agents: a terminal is an agent here when its
# program reports itself through OSC 7501 (`status.app`), when Reflex
# started it (label reflex.kind) or when it runs a coding agent we know by
# name (Codex says nothing through 7501 yet). Its status is only what the
# program reported: one that never did is Unknown, never guessed.
#
# Terminals are addressed "t7" here and "box/t7" on a machine this core
# added; the local core answers for both, so every call goes to one socket.

def nb(b: Bool) -> Bool:
  match b:
    case True{}:
      False{}
    case False{}:
      True{}

# a when c holds, else b.
def when(c: Bool, a: String, b: String) -> String:
  match c:
    case True{}:
      a
    case False{}:
      b

def request(method: String, params: String) -> String:
  Js.obj([Js.kv("jsonrpc", Js.str("2.0")), Js.kv("id", "1"), Js.kv("method", Js.str(method)), Js.kv("params", params)]) ++ "\n"

# "blocked: t3 is blocked on a question" — the stable kind first, so callers
# can tell a refusal worth retrying from a real failure.
def error_text(e: Maybe<&2, J.JSON>) -> String:
  match e:
    case Some{+x}:
      Js.as_text(Js.path(["data", "kind"], Some{x})) ++ ": " ++ Js.text_at(x, "message")
    case None{}:
      "herdr-core: no result"

def answer.pick(err: Maybe<&2, J.JSON>, res: Maybe<&2, J.JSON>) -> Result<&1, &1, U32 & String, J.JSON>:
  match res:
    case Some{x}:
      Done{x}
    case None{}:
      Fail{(1, error_text(err))}

def answer(+v: J.JSON) -> Result<&1, &1, U32 & String, J.JSON>:
  answer.pick(Js.get(v, "error"), Js.get(v, "result"))

def answer_parsed(r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, J.JSON>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{+v}:
      answer(v)

def answer_line(r: Result<&1, &1, U32 & String, String>) -> Result<&1, &1, U32 & String, J.JSON>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{line}:
      answer_parsed(Js.read(line))

def call(sock: String, method: String, params: String, timeout_ms: U32) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  do IO<Result<&1, &1, U32 & String, J.JSON>>:
    r : Result<&1, &1, U32 & String, String> <- H.Host.unix_call(sock, request(method, params), 8388608, timeout_ms)
    return answer_line(r)

# Reading terminals
# -----------------

def last.go(xs: List<&2, String>, +prev: String) -> String:
  match xs:
    case Nil{}:
      prev
    case Con{+x, t}:
      last.go(t, x)

# "/opt/homebrew/bin/codex" -> "codex".
def base(+path: String) -> String:
  last.go(String.split(path, '/'), path)

def first_text(xs: List<&2, J.JSON>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{+x, t}:
      Js.text_of(x)

# The program a terminal runs, by name: argv[0] of `key` ("argv", or the
# foreground job's).
def argv0(v: Maybe<&2, J.JSON>) -> String:
  base(first_text(Js.as_list(v)))

def known.list() -> List<&2, String>:
  ["claude", "pi", "codex", "grok", "opencode", "gemini", "amp", "droid", "cursor-agent", "copilot", "qwen", "aider", "goose", "crush", "kimi"]

def known.in(xs: List<&2, String>, +name: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{+x, t}:
      String.eq(x, name) || known.in(t, name)

# A coding agent Reflex knows by its command.
def known(+name: String) -> Bool:
  known.in(known.list(), name)

def if_known(+name: String) -> String:
  when(known(name), name, "")

# The word an agent's 7501 report names itself by, as Reflex's kinds have it.
def app_kind(+app: String) -> String:
  when(String.eq(app, "claude-code"), "claude", when(String.eq(app, "codex-cli"), "codex", app))

def label(+t: J.JSON, key: String) -> String:
  Js.as_text(Js.path(["labels", key], Some{t}))

def shells() -> List<&2, String>:
  ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "nu", "login"]

# A login shell's argv[0] is "-zsh".
def unlogin(+name: String) -> String:
  when(String.starts_with(name, "-"), String.drop(name, 1n), name)

# The foreground job is a shell: the agent it ran has quit (Reflex starts
# agents in a login shell that stays), or none has started yet.
def at_shell(+t: J.JSON) -> Bool:
  known.in(shells(), unlogin(argv0(Js.path(["foreground", "argv"], Some{t}))))

# What it is: the kind Reflex started it as, else what its program says it
# is, else a known agent in the foreground, else a known agent it started as.
def kind_of.any(+t: J.JSON) -> String:
  Js.or_else(label(t, "reflex.kind"), Js.or_else(app_kind(Js.as_text(Js.path(["status", "app"], Some{t}))), Js.or_else(if_known(argv0(Js.path(["foreground", "argv"], Some{t}))), if_known(argv0(Js.get(t, "argv"))))))

# ...and none while a shell is in front with nothing reported: an agent
# that quit leaves the list (the core clears its status when the shell gets
# the terminal back, and it is a plain shell again).
def kind_of(+t: J.JSON) -> String:
  when(at_shell(t) && String.is_empty(Js.as_text(Js.path(["status", "app"], Some{t}))), "", kind_of.any(t))

# 7501's words as Reflex's: "error" (the turn ended badly) is a finished
# turn to look at; anything unreported is Unknown.
def status_word(+s: String) -> String:
  when(String.eq(s, "error"), "done", s)

def status_of(+t: J.JSON) -> M.Status:
  M.Status.read(status_word(Js.as_text(Js.path(["status", "state"], Some{t}))))

# Reflex's seq only has to change when the status does: the low digits of
# the time it last changed (ms since the epoch) do, and fit a U32.
def digits9(+lex: String) -> String:
  String.reverse(String.take(String.reverse(lex), 9n))

def seq_of(+t: J.JSON) -> U32:
  Js.u32_or(U32.read(digits9(Js.as_text(Js.get(t, "status_ms")))), 0)

def cwd_of(+t: J.JSON) -> String:
  Js.or_else(Js.as_text(Js.path(["foreground", "cwd"], Some{t})), Js.text_at(t, "cwd"))

def agent_of(+t: J.JSON) -> M.Agent:
  M.Agent{
    Js.text_at(t, "address"),
    Js.or_else(Js.text_at(t, "name"), Js.text_at(t, "address")),
    kind_of(t),
    status_of(t),
    cwd_of(t),
    Js.text_at(t, "title"),
    seq_of(t),
    label(t, "reflex.session"),
    "",
  }

def agents_of.put(keep: Bool, a: M.Agent, rest: List<&2, M.Agent>) -> List<&2, M.Agent>:
  match keep:
    case True{}:
      a <> rest
    case False{}:
      rest

# The live terminals that hold agents.
def agents_of(xs: List<&2, J.JSON>) -> List<&2, M.Agent>:
  match xs:
    case Nil{}:
      []
    case Con{+t, rest}:
      agents_of.put(nb(String.is_empty(kind_of(t))), agent_of(t), agents_of(rest))

# What the core listed: its agents, and the machines whose line is down
# right now (their terminals are left out, not gone: keep them a while).
type Listed is Data:
  Listed{agents: List<&2, M.Agent>, down: List<&2, String>}

def down.put(up: Bool, +name: String, rest: List<&2, String>) -> List<&2, String>:
  match up:
    case True{}:
      rest
    case False{}:
      name <> rest

def down_of(xs: List<&2, J.JSON>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{+x, t}:
      down.put(String.eq(Js.text_at(x, "state"), "connected"), Js.text_at(x, "name"), down_of(t))

# Sessions
# --------
# Reflex starts Claude and pi with a session id it chose (`--session-id`)
# and labels the terminal with it. A Claude started some other way names its
# session in ~/.claude/sessions/<pid>.json once it has one.

def fg_pid(+t: J.JSON) -> String:
  Js.as_text(Js.path(["foreground", "pid"], Some{t}))

def session_file(+home: String, +pid: String) -> String:
  home ++ "/.claude/sessions/" ++ pid ++ ".json"

def session_in.v(r: Result<&1, &1, U32 & String, J.JSON>) -> String:
  match r:
    case Fail{e}:
      ""
    case Done{+v}:
      Js.text_at(v, "sessionId")

def session_in(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Fail{e}:
      ""
    case Done{text}:
      session_in.v(Js.read(text))

def with_session(a: M.Agent, +s: String) -> M.Agent:
  match a:
    case M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}:
      M.Agent{pane, name, kind, status, cwd, title, seq, s, screen}

def here(+pane: String) -> Bool:
  nb(String.contains(pane, "/"))

# A Claude on this Mac with no session from Reflex: its own file's.
def fill_session.want(+a: M.Agent) -> Bool:
  match a:
    case M.Agent{+pane, name, +kind, status, cwd, title, seq, +session, screen}:
      String.is_empty(session) && String.eq(kind, "claude") && here(pane)

def fill_session.if(want: Bool, +home: String, +t: J.JSON, a: M.Agent) -> IO(M.Agent):
  match want:
    case False{}:
      IO.pure(M.Agent, a)
    case True{}:
      do IO<M.Agent>:
        r : Result<&1, &1, U32 & String, String> <- Fs.read(session_file(home, fg_pid(t)), 65536)
        return with_session(a, session_in(r))

def fill_sessions(xs: List<&2, J.JSON>, +home: String) -> IO(List<&2, M.Agent>):
  match xs:
    case Nil{}:
      IO.pure(List<&2, M.Agent>, [])
    case Con{+t, rest}:
      do IO<List<&2, M.Agent>>:
        +a : M.Agent = agent_of(t)
        h : M.Agent <- fill_session.if(fill_session.want(a), home, t, a)
        tail : List<&2, M.Agent> <- fill_sessions(rest, home)
        return agents_of.put(nb(String.is_empty(kind_of(t))), h, tail)

def list.of(r: Result<&1, &1, U32 & String, J.JSON>, +home: String) -> IO(Result<&1, &1, U32 & String, Listed>):
  match r:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, Listed>, Fail{e})
    case Done{+v}:
      do IO<Result<&1, &1, U32 & String, Listed>>:
        agents : List<&2, M.Agent> <- fill_sessions(Js.as_list(Js.get(v, "terminals")), home)
        return Done{Listed{agents, down_of(Js.as_list(Js.get(v, "machines")))}}

# Every agent the core runs, this Mac's and its connected machines' alike.
def list_agents(sock: String, +home: String) -> IO(Result<&1, &1, U32 & String, Listed>):
  do IO<Result<&1, &1, U32 & String, Listed>>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "terminal.list", "{}", 3000)
    list.of(r, home)

# Requests
# --------

def p_terminal(t: String) -> String:
  Js.obj([Js.kv("terminal", Js.str(t))])

def read_text(r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, String>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{+v}:
      Done{Js.text_at(v, "text")}

# The screen, plus `lines` of history above it. herdr's sources map onto
# that: "visible" is the screen alone, the rest a screen and some history.
def read_lines.pick(visible: Bool, +lines: U32) -> U32:
  match visible:
    case True{}:
      0
    case False{}:
      lines

def read_lines(+source: String, +lines: U32) -> U32:
  read_lines.pick(String.eq(source, "visible"), lines)

def read_pane(sock: String, pane: String, +source: String, +lines: U32) -> IO(Result<&1, &1, U32 & String, String>):
  do IO<Result<&1, &1, U32 & String, String>>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "terminal.read", Js.obj([Js.kv("terminal", Js.str(pane)), Js.kv("lines", Js.num(read_lines(source, lines)))]), 3000)
    return read_text(r)

def status_text(r: Result<&1, &1, U32 & String, J.JSON>) -> String:
  match r:
    case Done{+v}:
      status_word(Js.as_text(Js.path(["status", "state"], Some{v})))
    case Fail{e}:
      ""

# What the program last reported ("idle", "working", "blocked", "done");
# "" when it never did, or it is gone.
def pane_status(sock: String, pane: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "terminal.get", p_terminal(pane), 3000)
    return status_text(r)

def reports(+kind: String) -> Bool:
  String.eq(kind, "claude") || String.eq(kind, "pi")

def get.ready.if(waiting: Bool, t: J.JSON) -> Result<&1, &1, U32 & String, J.JSON>:
  match waiting:
    case True{}:
      Fail{(1, "agent_not_ready: it has not said it is ready yet")}
    case False{}:
      Done{t}

def get.ready(r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, J.JSON>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{+t}:
      get.ready.if(reports(kind_of.any(t)) && String.is_empty(Js.as_text(Js.path(["status", "state"], Some{t}))), t)

def send.go(r: Result<&1, &1, U32 & String, J.JSON>, sock: String, +pane: String, +text: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  match r:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, J.JSON>, Fail{e})
    case Done{t}:
      call(sock, "terminal.send", Js.obj([Js.kv("terminal", Js.str(pane)), Js.kv("text", Js.str(text))]), 20000)

# A prompt: pasted, then Enter, once nobody has typed for a moment. The core
# refuses one while the agent waits on you (kind "blocked"); an agent that
# reports its status but hasn't yet (still starting) is refused here, as
# herdr's agent_not_ready was, so the caller retries.
def prompt(sock: String, +pane: String, +text: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  do IO<Result<&1, &1, U32 & String, J.JSON>>:
    +s : String = sock
    g : Result<&1, &1, U32 & String, J.JSON> <- call(s, "terminal.get", p_terminal(pane), 3000)
    send.go(get.ready(g), s, pane, text)

def words.put(empty: Bool, w: String, rest: List<&2, String>) -> List<&2, String>:
  match empty:
    case True{}:
      rest
    case False{}:
      w <> rest

def words(ws: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      []
    case Con{+w, t}:
      words.put(String.is_empty(w), w, words(t))

# herdr's key names as the core's: "ctrl-c" is "ctrl+c", "escape" "esc".
def key_name(+k: String) -> String:
  when(String.eq(k, "escape"), "esc", when(String.eq(k, "return"), "enter", String.join(String.split(k, '-'), "+")))

def key_names(ks: List<&2, String>) -> List<&2, String>:
  match ks:
    case Nil{}:
      []
    case Con{+k, t}:
      key_name(k) <> key_names(t)

# One key, or several separated by spaces ("down down enter").
def p_keys(pane: String, key: String) -> String:
  Js.obj([Js.kv("terminal", Js.str(pane)), Js.kv("keys", Js.strs(key_names(words(String.split(key, ' ')))))])

def press(sock: String, pane: String, key: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  call(sock, "terminal.keys", p_keys(pane, key), 10000)

def close.rm(r: Result<&1, &1, U32 & String, J.JSON>, sock: String, pane: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  match r:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, J.JSON>, Fail{e})
    case Done{v}:
      do IO<Result<&1, &1, U32 & String, J.JSON>>:
        g : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "terminal.rm", p_terminal(pane), 5000)
        return Done{v}

# End the program (hangup, terminate, kill) and drop its record.
def close_pane(sock: String, +pane: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  do IO<Result<&1, &1, U32 & String, J.JSON>>:
    +s : String = sock
    r : Result<&1, &1, U32 & String, J.JSON> <- call(s, "terminal.kill", p_terminal(pane), 15000)
    close.rm(r, s, pane)

# Starting agents
# ---------------

def hex.digit(+n: U32) -> String:
  String.take(String.drop("0123456789abcdef", U32.to_nat(n)), 1n)

def hex.go(fuel: Nat, +n: U32) -> String:
  match fuel:
    case 0n:
      ""
    case 1n+p:
      hex.go(p, U32.div(n, 16)) ++ hex.digit((n % 16 : U32))

def hex8(+n: U32) -> String:
  hex.go(8n, n)

def mid(+s: String, +from: Nat, +n: Nat) -> String:
  String.take(String.drop(s, from), n)

def uuid.of(+s: String) -> String:
  mid(s, 0n, 8n) ++ "-" ++ mid(s, 8n, 4n) ++ "-4" ++ mid(s, 13n, 3n) ++ "-8" ++ mid(s, 17n, 3n) ++ "-" ++ mid(s, 20n, 12n)

# A version-4 UUID from four random words (Claude wants a real UUID).
def uuid(+a: U32, +b: U32, +c: U32, +d: U32) -> String:
  uuid.of(hex8(a) ++ hex8(b) ++ hex8(c) ++ hex8(d))

def cmd_of.pick(codex: Bool, +kind: String) -> List<&2, String>:
  match codex:
    case True{}:
      # Codex runs its commands in a shared daemon unless told not to:
      # outside this terminal, unseen.
      ["codex", "--no-daemon"]
    case False{}:
      [kind]

def cmd_of(+kind: String) -> List<&2, String>:
  cmd_of.pick(String.eq(kind, "codex"), kind)

# [x], unless it is empty.
def maybe_one(empty: Bool, +x: String) -> List<&2, String>:
  match empty:
    case True{}:
      []
    case False{}:
      [x]

def text_arg(+text: String) -> List<&2, String>:
  maybe_one(String.is_empty(String.trim(text)), text)

# The agent's command line: its command, how to bring its session back (or
# the id to start one with), then the request as its first prompt.
def argv(+kind: String, args: List<&2, String>, +text: String) -> List<&2, String>:
  List.append(&2, String, List.append(&2, String, cmd_of(kind), args), text_arg(text))

def session_kv(+session: String) -> List<&2, String>:
  maybe_one(String.is_empty(session), Js.kv("reflex.session", Js.str(session)))

def labels(+kind: String, +session: String) -> String:
  Js.obj(List.append(&2, String, [Js.kv("reflex.kind", Js.str(kind))], session_kv(session)))

def on_kv(+m: String) -> List<&2, String>:
  maybe_one(String.is_empty(m), Js.kv("on", Js.str(m)))

def strs(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{x, t}:
      Js.str(x) <> strs(t)

# A shell that runs `"$@"` (fish and nu don't): yours, else zsh.
def posix(+shell: String) -> String:
  when(String.eq(base(shell), "fish") || String.eq(base(shell), "nu"), "/bin/zsh", shell)


def wrap.pick(here: Bool, +shell: String, xs: List<&2, String>) -> List<&2, String>:
  match here:
    case True{}:
      List.append(&2, String, [posix(shell), "-lic", "\"$@\"; exec \"$0\" -li", posix(shell)], xs)
    case False{}:
      # That machine's own login shell, found there.
      List.append(&2, String, ["sh", "-c", "s=\"${SHELL:-/bin/sh}\"; case \"${s##*/}\" in fish|nu) s=/bin/sh;; esac; exec \"$s\" -lic '\"$@\"; exec \"$0\" -li' \"$s\" \"$@\"", "sh"], xs)

# Never a child of whatever terminal reflexd was started from (children end
# with their parent), and kept: a program lost to a crash or reboot comes
# back as a shell in its folder.
#
# Run in your login shell (`shell`), which stays when the agent quits, as
# the Herdr app does: the agent finds what your shell sets up (PATH, keys),
# and the terminal is still yours afterwards. Elsewhere `sh` starts it the
# same way and hands over to that machine's shell.
def wrap(+shell: String, +m: String, xs: List<&2, String>) -> List<&2, String>:
  wrap.pick(String.is_empty(m), shell, xs)

def p_run(+shell: String, +name: String, +m: String, +cwd: String, +kind: String, +session: String, xs: List<&2, String>) -> String:
  Js.obj(List.append(&2, String, [Js.kv("name", Js.str(name)), Js.kv("cwd", Js.str(cwd)), Js.kv("argv", Js.arr(strs(wrap(shell, m, xs)))), Js.kv("labels", labels(kind, session)), Js.kv("no_parent", "true"), Js.kv("keep", "true"), Js.kv("env", Js.obj([Js.kv("TERM", Js.str("xterm-256color")), Js.kv("COLORTERM", Js.str("truecolor"))]))], on_kv(m)))

def address(r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, String>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{+v}:
      Done{Js.text_at(v, "address")}

# Start an agent in a new terminal, on this Mac or machine m, in cwd (there):
# its address ("t7", "box/t7").
def run(sock: String, +shell: String, +name: String, +m: String, +cwd: String, +kind: String, +session: String, args: List<&2, String>, +text: String) -> IO(Result<&1, &1, U32 & String, String>):
  do IO<Result<&1, &1, U32 & String, String>>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "terminal.run", p_run(shell, name, m, cwd, kind, session, argv(kind, args, text)), 30000)
    return address(r)

# Machines
# --------

def names_of.put(keep: Bool, +name: String, rest: List<&2, String>) -> List<&2, String>:
  match keep:
    case True{}:
      name <> rest
    case False{}:
      rest

def names_of(xs: List<&2, J.JSON>, +connected: Bool) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{+x, t}:
      names_of.put(nb(connected) || String.eq(Js.text_at(x, "state"), "connected"), Js.text_at(x, "name"), names_of(t, connected))

def machine_names(r: Result<&1, &1, U32 & String, J.JSON>, +connected: Bool) -> List<&2, String>:
  match r:
    case Fail{e}:
      []
    case Done{+v}:
      names_of(Js.as_list(Js.get(v, "machines")), connected)

# The machines this core has added, by name (only those it reaches now,
# when `connected`).
def machines(sock: String, +connected: Bool) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "machine.list", "{}", 3000)
    return machine_names(r, connected)

def up.of(r: Result<&1, &1, U32 & String, J.JSON>) -> Bool:
  match r:
    case Fail{e}:
      False{}
    case Done{v}:
      True{}

# Whether the core answers at all.
def up(sock: String) -> IO(Bool):
  do IO<Bool>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "server.status", "{}", 2000)
    return up.of(r)
