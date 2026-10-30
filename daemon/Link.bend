import Base
import ./Host.bend as H
import ./Js.bend as Js
import ./vendor/strict-json/json.bend as J

# The app's socket (REFLEX_LINK_SOCKET, else <data>/link.sock): what only
# the app has, for reflexd.
# herdr-core streams a terminal to whoever attaches; the app attaches for
# the phone and keeps its screen, so the phone's colored screens, its typing
# and its size for a herdr-core agent come through here (herdr's pane reads
# and `terminal session control` did this for its panes). One JSON line
# asked, one answered, per connection (see the app's PhoneLink).


def request(method: String, params: String) -> String:
  Js.obj([Js.kv("method", Js.str(method)), Js.kv("params", params)]) ++ "\n"

def answer(r: Result<&1, &1, U32 & String, String>) -> Result<&1, &1, U32 & String, J.JSON>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{line}:
      Js.read(line)

def call(+sock: String, method: String, params: String, timeout_ms: U32) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  do IO<Result<&1, &1, U32 & String, J.JSON>>:
    r : Result<&1, &1, U32 & String, String> <- H.Host.unix_call(sock, request(method, params), 8388608, timeout_ms)
    return answer(r)

def text_of.ok(ok: Bool, text: String, err: String) -> Result<&1, &1, U32 & String, String>:
  match ok:
    case True{}:
      Done{text}
    case False{}:
      Fail{(1, err)}


def text_of(r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, String>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{+v}:
      text_of.ok(Js.as_bool(Js.get(v, "ok")), Js.text_at(v, "text"), Js.text_at(v, "error"))

# The terminal's screen with its colors, as the app's viewer has it.
def screen(+sock: String, pane: String) -> IO(Result<&1, &1, U32 & String, String>):
  do IO<Result<&1, &1, U32 & String, String>>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "screen", Js.obj([Js.kv("terminal", Js.str(pane))]), 8000)
    return text_of(r)

def ok_of.pick(ok: Bool, +v: J.JSON) -> Result<&1, &1, U32 & String, J.JSON>:
  match ok:
    case True{}:
      Done{v}
    case False{}:
      Fail{(1, Js.text_at(v, "error"))}


def ok_of(r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, J.JSON>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{+v}:
      ok_of.pick(Js.as_bool(Js.get(v, "ok")), v)

# Literal keys, no Enter (the phone's keyboard, typed live).
def typed(+sock: String, pane: String, text: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  do IO<Result<&1, &1, U32 & String, J.JSON>>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "type", Js.obj([Js.kv("terminal", Js.str(pane)), Js.kv("text", Js.str(text))]), 8000)
    return ok_of(r)

def scroll_kv.pick(yes: Bool, +s: String, +n: U32) -> List<&2, String>:
  match yes:
    case True{}:
      [Js.kv("scroll", Js.str(s)), Js.kv("n", Js.num(n))]
    case False{}:
      []


def scroll_kv(+s: String, +n: U32) -> List<&2, String>:
  scroll_kv.pick(String.eq(s, "up") || String.eq(s, "down"), s, n)

def control_json(r: Result<&1, &1, U32 & String, J.JSON>) -> String:
  match r:
    case Fail{(c, m)}:
      Js.obj([Js.kv("ok", "false"), Js.kv("error", Js.str(m))])
    case Done{+v}:
      Js.obj([Js.kv("ok", Js.bool(Js.as_bool(Js.get(v, "ok")))), Js.kv("held", Js.bool(Js.as_bool(Js.get(v, "held")))), Js.kv("error", Js.str(Js.text_at(v, "error")))])


# The phone's size (and a scroll): {"ok", "held", "error"} as the phone reads it.
def control(+sock: String, pane: String, +cols: U32, +rows: U32, take: Bool, +scroll: String, +n: U32) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, J.JSON> <- call(sock, "control", Js.obj(List.append(&2, String, [Js.kv("terminal", Js.str(pane)), Js.kv("cols", Js.num(cols)), Js.kv("rows", Js.num(rows)), Js.kv("take", Js.bool(take))], scroll_kv(scroll, n))), 8000)
    return control_json(r)