import Base
import ./Js.bend as Js
import ./Index.bend as Ix

# Past: earlier agent conversations that could be resumed — Claude's, pi's
# and Codex's saved sessions, and Claude's background sessions. The app reads
# the harnesses' own session files and writes them to sessions.tsv, one line
# per session (sessions already live in herdr left out):
#
#   agent  id  cwd  title  last_prompt  age_hours  state
#
# state: past (saved, not running) | background (a stopped `claude --bg`)
#        | running (a running `claude --bg`: attach to it)
#        | elsewhere (open in another terminal: fork it, never write twice)
#
# Parsing and ranking are pure. Jev is offered a short, relevant list: the
# request's words found in a session's title, last prompt or folder first,
# then recency.

type Past is Data:
  Past{agent: String, id: String, cwd: String, title: String, last: String, age: U32, state: String}

# Parsing
# -------

def past_of(fields: List<&2, String>) -> Maybe<&2, Past>:
  match fields:
    case Con{agent, Con{id, Con{cwd, Con{title, Con{last, Con{age, Con{state, rest}}}}}}}:
      Some{Past{agent, id, cwd, title, last, Ix.u32_or(U32.read(age)), state}}
    case other:
      None{}

def add_past(m: Maybe<&2, Past>, rest: List<&2, Past>) -> List<&2, Past>:
  match m:
    case Some{p}:
      p <> rest
    case None{}:
      rest

def parse_lines(lines: List<&2, String>) -> List<&2, Past>:
  match lines:
    case Nil{}:
      []
    case Con{l, t}:
      add_past(past_of(String.split(l, '\t')), parse_lines(t))

def parse(tsv: String) -> List<&2, Past>:
  parse_lines(String.lines(tsv))

# Ranking
# -------

def toks_hits(toks: List<&2, String>, +hay: String) -> U32:
  match toks:
    case Nil{}:
      0
    case Con{+t, rest}:
      (Ix.bonus(String.contains(hay, t), Ix.weight(t)) + toks_hits(rest, hay) : U32)

type Scored is Data:
  Scored{score: U32, age: U32, p: Past}

def score.of(+hits: U32, +age: U32, p: Past) -> Scored:
  Scored{(hits * 4 + Ix.recency(age) : U32), age, p}

def score(+toks: List<&2, String>, p: Past) -> Scored:
  match p:
    case Past{+agent, +id, +cwd, +title, +last, +age, +state}:
      score.of(toks_hits(toks, String.to_lower(title ++ " " ++ last ++ " " ++ cwd)), age, Past{agent, id, cwd, title, last, age, state})

def scored_le(a: Scored, b: Scored) -> Bool:
  match a b:
    case Scored{+x, +ax, pa} Scored{+y, +ay, pb}:
      U32.is_gt(x, y) || (U32.is_eq(x, y) && U32.is_le(ax, ay))

def scored_all(+toks: List<&2, String>, xs: List<&2, Past>) -> List<&2, Scored>:
  match xs:
    case Nil{}:
      []
    case Con{p, t}:
      score(toks, p) <> scored_all(toks, t)

def pasts_of(xs: List<&2, Scored>, k: Nat) -> List<&2, Past>:
  match xs k:
    case Nil{} _:
      []
    case Con{h, t} 0n:
      []
    case Con{Scored{s, a, p}, t} 1n+n:
      p <> pasts_of(t, n)

# The k sessions most worth offering Jev for this request.
def rank(text: String, xs: List<&2, Past>, +k: Nat) -> List<&2, Past>:
  pasts_of(List.sort(~Scored, ~scored_le, scored_all(Ix.tokens(text), xs)), k)

# JSON
# ----

def Past.json(p: Past) -> String:
  match p:
    case Past{agent, id, cwd, title, last, age, state}:
      Js.obj([
        Js.kv("agent", Js.str(agent)),
        Js.kv("id", Js.str(id)),
        Js.kv("cwd", Js.str(cwd)),
        Js.kv("title", Js.str(title)),
        Js.kv("last", Js.str(last)),
        Js.kv("ageHours", Js.num(age)),
        Js.kv("state", Js.str(state)),
      ])

def jsons(xs: List<&2, Past>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{p, t}:
      Past.json(p) <> jsons(t)
