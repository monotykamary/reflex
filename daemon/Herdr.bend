import Base
import ./Host.bend as H
import ./Js.bend as Js
import ./Model.bend as M
import ./vendor/strict-json/json.bend as J

# Herdr socket client. Requests are built and responses read by pure code;
# `call` is the only effect: one JSONL request per Unix-socket connection.

def Res() -> Type:
  Result<&1, &1, U32 & String, J.JSON>

def request(method: String, params: String) -> String:
  Js.obj([Js.kv("id", Js.str("reflex")), Js.kv("method", Js.str(method)), Js.kv("params", params)]) ++ "\n"

def error_text(e: Maybe<&2, J.JSON>) -> String:
  match e:
    case Some{+x}:
      Js.text_at(x, "code") ++ ": " ++ Js.text_at(x, "message")
    case None{}:
      "herdr: no result"

def answer.pick(err: Maybe<&2, J.JSON>, res: Maybe<&2, J.JSON>) -> Result<&1, &1, U32 & String, J.JSON>:
  match res:
    case Some{x}:
      Done{x}
    case None{}:
      Fail{(1, error_text(err))}

# A response line: its result, or its error as text.
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

# Reading agents
# --------------

def session_of(+a: J.JSON) -> String:
  Js.as_text(Js.path(["agent_session", "value"], Some{a}))

def cwd_of(fg: String, cwd: String) -> String:
  Js.or_else(fg, cwd)

def agent_of(+a: J.JSON) -> M.Agent:
  M.Agent{
    Js.text_at(a, "pane_id"),
    Js.text_at(a, "name"),
    Js.text_at(a, "agent"),
    M.Status.read(Js.text_at(a, "agent_status")),
    cwd_of(Js.text_at(a, "foreground_cwd"), Js.text_at(a, "cwd")),
    Js.text_at(a, "terminal_title_stripped"),
    Js.as_u32(Js.get(a, "state_change_seq"), 0),
    session_of(a),
    "",
  }

def agents_of(xs: List<&2, J.JSON>) -> List<&2, M.Agent>:
  match xs:
    case Nil{}:
      []
    case Con{+h, t}:
      agent_of(h) <> agents_of(t)

def agents(r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, List<&2, M.Agent>>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{+v}:
      Done{agents_of(Js.as_list(Js.get(v, "agents")))}

def read_text(r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, String>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{+v}:
      Done{Js.as_text(Js.path(["read", "text"], Some{v}))}

# Requests
# --------

def p_agent_list() -> String:
  "{}"

def p_read(pane: String, source: String, +lines: U32) -> String:
  Js.obj([Js.kv("pane_id", Js.str(pane)), Js.kv("source", Js.str(source)), Js.kv("lines", Js.num(lines)), Js.kv("strip_ansi", "true")])

def p_prompt(target: String, text: String) -> String:
  Js.obj([Js.kv("target", Js.str(target)), Js.kv("text", Js.str(text))])

def p_keys(pane: String, key: String) -> String:
  Js.obj([Js.kv("pane_id", Js.str(pane)), Js.kv("keys", Js.strs([key]))])

def p_workspace(cwd: String, label: String) -> String:
  Js.obj([Js.kv("cwd", Js.str(cwd)), Js.kv("label", Js.str(label)), Js.kv("focus", "false")])

def p_start(name: String, kind: String, pane: String) -> String:
  Js.obj([Js.kv("name", Js.str(name)), Js.kv("kind", Js.str(kind)), Js.kv("pane_id", Js.str(pane)), Js.kv("timeout_ms", "45000")])

def root_pane(r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, String>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{+v}:
      Done{Js.as_text(Js.path(["root_pane", "pane_id"], Some{v}))}

# IO wrappers
# -----------

def list_agents(sock: String) -> IO(Result<&1, &1, U32 & String, List<&2, M.Agent>>):
  do IO<Result<&1, &1, U32 & String, List<&2, M.Agent>>>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "agent.list", p_agent_list(), 3000)
    return agents(r)

def p_read_ansi(pane: String, source: String, +lines: U32) -> String:
  Js.obj([Js.kv("pane_id", Js.str(pane)), Js.kv("source", Js.str(source)), Js.kv("lines", Js.num(lines)), Js.kv("format", Js.str("ansi")), Js.kv("strip_ansi", "false")])

# The pane with its colors (SGR escapes), for a terminal-like view.
def read_pane_ansi(sock: String, pane: String, source: String, lines: U32) -> IO(Result<&1, &1, U32 & String, String>):
  do IO<Result<&1, &1, U32 & String, String>>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "pane.read", p_read_ansi(pane, source, lines), 3000)
    return read_text(r)

def read_pane(sock: String, pane: String, source: String, lines: U32) -> IO(Result<&1, &1, U32 & String, String>):
  do IO<Result<&1, &1, U32 & String, String>>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "pane.read", p_read(pane, source, lines), 3000)
    return read_text(r)

def prompt(sock: String, target: String, text: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  call(sock, "agent.prompt", p_prompt(target, text), 10000)

def press(sock: String, pane: String, key: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  call(sock, "pane.send_keys", p_keys(pane, key), 5000)

def new_workspace(sock: String, cwd: String, label: String) -> IO(Result<&1, &1, U32 & String, String>):
  do IO<Result<&1, &1, U32 & String, String>>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "workspace.create", p_workspace(cwd, label), 10000)
    return root_pane(r)

def start_agent(sock: String, name: String, kind: String, pane: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  call(sock, "agent.start", p_start(name, kind, pane), 50000)

def focus(sock: String, target: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  call(sock, "agent.focus", Js.obj([Js.kv("target", Js.str(target))]), 5000)
