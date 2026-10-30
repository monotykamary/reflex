# The herdr-core adapter against a real, disposable core (scripts/test-core.py
# starts it with fake agents): which terminals are agents and what they are,
# a prompt typed in and answered, keys, reads, a start and a close — and
# which backend each kind of pane id goes to.
import Base
import ../Model.bend as M
import ../Hc.bend as Hc
import ../Term.bend as Term
import ../Js.bend as Js
import ../vendor/strict-json/json.bend as J

def env_or(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      ""

def agents(xs: List<&2, M.Agent>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}, t}:
      "agent " ++ name ++ " kind=" ++ kind ++ " status=" ++ M.Status.show(status) ++ " session=" ++ session ++ "\n" ++ agents(t)

def listed(r: Result<&1, &1, U32 & String, Hc.Listed>) -> String:
  match r:
    case Done{Hc.Listed{xs, down}}:
      agents(xs)
    case Fail{(c, m)}:
      "list failed: " ++ m ++ "\n"

def res(r: Result<&1, &1, U32 & String, J.JSON>) -> String:
  match r:
    case Done{v}:
      "ok"
    case Fail{(c, m)}:
      "fail " ++ m

def txt(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{v}:
      v
    case Fail{(c, m)}:
      "fail " ++ m

def has.pick(yes: Bool, v: String) -> String:
  match yes:
    case True{}:
      "yes"
    case False{}:
      "no: " ++ v

def has(r: Result<&1, &1, U32 & String, String>, +probe: String) -> String:
  match r:
    case Done{+v}:
      has.pick(String.contains(v, probe), v)
    case Fail{(c, m)}:
      "fail " ++ m

def show_b(b: Bool) -> String:
  match b:
    case True{}:
      "yes"
    case False{}:
      "no"


def route(+p: String) -> String:
  p ++ " core=" ++ show_b(Term.core(p)) ++ " at=" ++ Term.at("/herdr.sock", "/core.sock", "/m", p) ++ " bare=" ++ Term.bare(p) ++ " on=" ++ Term.pane_on("work", p) ++ "\n"

def got_labels(r: Result<&1, &1, U32 & String, J.JSON>) -> String:
  match r:
    case Done{+v}:
      Hc.label(v, "reflex.kind") ++ "," ++ Hc.label(v, "reflex.session") ++ " argv0=" ++ Hc.argv0(Js.get(v, "argv"))
    case Fail{(c, m)}:
      "fail " ++ m


def main() -> IO(Unit):
  do IO<Unit>:
    e : Result<&1, &1, U32 & String, String> <- IO.get_env("REFLEX_TEST_CORE")
    +s : String = env_or(e)
    h : Result<&1, &1, U32 & String, String> <- IO.get_env("REFLEX_TEST_HOME")
    +home : String = env_or(h)
    IO.print(route("t7") ++ route("box/t12") ++ route("wBE:p1") ++ route("work/wBE:p1") ++ route(""))
    IO.print("uuid " ++ Hc.uuid(305419896, 2596069104, 4294967295, 0))
    l : Result<&1, &1, U32 & String, Hc.Listed> <- Hc.list_agents(s, home)
    IO.print(listed(l))
    st : String <- Hc.pane_status(s, "echo")
    IO.print("echo status " ++ st)
    p : Result<&1, &1, U32 & String, J.JSON> <- Hc.prompt(s, "echo", "hello there")
    IO.print("prompt " ++ res(p))
    w : Result<&1, &1, U32 & String, J.JSON> <- Hc.prompt(s, "slow", "too soon")
    IO.print("prompt before ready " ++ res(w))
    b : Result<&1, &1, U32 & String, J.JSON> <- Hc.prompt(s, "asks", "over a question")
    IO.print("prompt while blocked " ++ res(b))
    IO.sleep(4500)
    r : Result<&1, &1, U32 & String, String> <- Hc.read_pane(s, "echo", "recent_unwrapped", 20)
    IO.print("echo answered " ++ has(r, "got:hello there"))
    k : Result<&1, &1, U32 & String, J.JSON> <- Hc.press(s, "echo", "k e y s enter")
    IO.sleep(4000)
    r2 : Result<&1, &1, U32 & String, String> <- Hc.read_pane(s, "echo", "visible", 20)
    IO.print("keys " ++ res(k) ++ " " ++ has(r2, "got:keys"))
    a : Result<&1, &1, U32 & String, String> <- Hc.run(s, "/bin/sh", "rx9-1", "", "/tmp", "pi", "sess-1", ["--version"], "")
    IO.print("run " ++ txt(a))
    IO.sleep(1500)
    g : Result<&1, &1, U32 & String, J.JSON> <- Hc.call(s, "terminal.get", "{\"terminal\":\"rx9-1\"}", 3000)
    IO.print("run labels " ++ got_labels(g))
    c : Result<&1, &1, U32 & String, J.JSON> <- Hc.close_pane(s, "rx9-1")
    IO.print("close " ++ res(c))
    gone : String <- Hc.pane_status(s, "rx9-1")
    IO.print("closed status [" ++ gone ++ "]")
    up : Bool <- Hc.up(s)
    down : Bool <- Hc.up("/nonexistent/core.sock")
    IO.print("up " ++ show_b(up) ++ " " ++ show_b(down))