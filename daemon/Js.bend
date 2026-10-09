import Base
import ./vendor/strict-json/json.bend as J

# JSON helpers: reading fields out of a parsed J.JSON, and building JSON text.

# Reading
# -------

def pick(hit: Bool, value: J.JSON, rest: Maybe<&2, J.JSON>) -> Maybe<&2, J.JSON>:
  match hit:
    case True{}:
      Some{value}
    case False{}:
      rest

def find(fields: List<&2, J.JSON>, +key: String) -> Maybe<&2, J.JSON>:
  match fields:
    case Nil{}:
      None{}
    case Con{J.Member{name, value}, t}:
      pick(String.eq(name, key), value, find(t, key))
    case Con{other, t}:
      find(t, key)

def get(v: J.JSON, key: String) -> Maybe<&2, J.JSON>:
  match v:
    case J.Obj{fields}:
      find(fields, key)
    case other:
      None{}

def bool_text(ok: Bool) -> String:
  match ok:
    case True{}:
      "true"
    case False{}:
      "false"

def text_of(x: J.JSON) -> String:
  match x:
    case J.Str{s}:
      s
    case J.Num{lex}:
      lex
    case J.Boolean{ok}:
      bool_text(ok)
    case other:
      ""

def as_text(v: Maybe<&2, J.JSON>) -> String:
  match v:
    case Some{x}:
      text_of(x)
    case None{}:
      ""

def u32_or(m: Maybe<&2, U32>, +fallback: U32) -> U32:
  match m:
    case Some{n}:
      n
    case None{}:
      fallback

def u32_of(x: J.JSON, +fallback: U32) -> U32:
  match x:
    case J.Num{lex}:
      u32_or(U32.read(lex), fallback)
    case J.Str{s}:
      u32_or(U32.read(s), fallback)
    case other:
      fallback

def as_u32(v: Maybe<&2, J.JSON>, +fallback: U32) -> U32:
  match v:
    case Some{x}:
      u32_of(x, fallback)
    case None{}:
      fallback

def bool_of(x: J.JSON) -> Bool:
  match x:
    case J.Boolean{ok}:
      ok
    case other:
      False{}

def as_bool(v: Maybe<&2, J.JSON>) -> Bool:
  match v:
    case Some{x}:
      bool_of(x)
    case None{}:
      False{}

def list_of(x: J.JSON) -> List<&2, J.JSON>:
  match x:
    case J.Arr{items}:
      items
    case other:
      []

def as_list(v: Maybe<&2, J.JSON>) -> List<&2, J.JSON>:
  match v:
    case Some{x}:
      list_of(x)
    case None{}:
      []

def path(keys: List<&2, String>, m: Maybe<&2, J.JSON>) -> Maybe<&2, J.JSON>:
  match keys m:
    case _ None{}:
      None{}
    case Nil{} Some{v}:
      Some{v}
    case Con{k, rest} Some{v}:
      path(rest, get(v, k))

def text_at(v: J.JSON, key: String) -> String:
  as_text(get(v, key))

def read(s: String) -> Result<&1, &1, U32 & String, J.JSON>:
  J.JSON.read(s)

# Building
# --------

def str(s: String) -> String:
  J.JSON.esc(s)

def num(+n: U32) -> String:
  U32.show(n)

def bool(b: Bool) -> String:
  bool_text(b)

def kv(k: String, v: String) -> String:
  "\"" ++ k ++ "\":" ++ v

def obj(parts: List<&2, String>) -> String:
  "{" ++ String.join(parts, ",") ++ "}"

def arr(parts: List<&2, String>) -> String:
  "[" ++ String.join(parts, ",") ++ "]"

def quote_all(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{h, t}:
      str(h) <> quote_all(t)

def strs(xs: List<&2, String>) -> String:
  arr(quote_all(xs))

def nat(+n: Nat) -> String:
  Nat.show(n)

def or_else.pick(empty: Bool, a: String, b: String) -> String:
  match empty:
    case True{}:
      b
    case False{}:
      a

# a, or b when a is empty
def or_else(+a: String, b: String) -> String:
  or_else.pick(String.is_empty(a), a, b)
