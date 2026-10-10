import Base
import ./Js.bend as Js
import ./Model.bend as M
import ./Past.bend as P
import ./vendor/strict-json/json.bend as J

# Route: turns a request plus what reflexd can see into one typed Jev call,
# and Jev's typed answer into a decision. Jev never writes text and never
# invents a target: it picks keys from candidate lists built here, and every
# key maps back to a candidate or the request goes to the inbox as a question.

# Candidates
# ----------

# An agent offered to Jev, with a little of what its pane shows.
type Seen is Data:
  Seen{agent: M.Agent, recent: String}

type Decision is Data:
  # act (after the undo window)
  Go{action: M.Action, label: String, why: String}
  # not confident: ask, offering numbered options
  Choose{title: String, opts: List<&2, M.Opt>, why: String}
  # routing could not run
  Broke{message: String}

# Text helpers
# ------------

def home_short.if(home: Bool, rest: String, path: String) -> String:
  match home:
    case True{}:
      "~" ++ rest
    case False{}:
      path

def bool_not(b: Bool) -> Bool:
  match b:
    case True{}:
      False{}
    case False{}:
      True{}

def Core_nonempty(+s: String) -> Bool:
  bool_not(String.is_empty(s))

# /Users/x/VCS/a -> ~/VCS/a when `home` is /Users/x
def short(+home: String, +path: String) -> String:
  home_short.if(String.starts_with(path, home) && Core_nonempty(home), String.drop(path, String.length(home)), path)

def clip.if(long: Bool, s: String, +n: Nat) -> String:
  match long:
    case True{}:
      String.take(s, n) ++ "…"
    case False{}:
      s

def clip(+s: String, +n: Nat) -> String:
  clip.if(Nat.is_gt(String.length(s), n), s, n)

def idx(+prefix: String, +i: Nat) -> String:
  prefix ++ Nat.show(i)

def nonblank.put(blank: Bool, h: String, rest: List<&2, String>) -> List<&2, String>:
  match blank:
    case True{}:
      rest
    case False{}:
      String.trim_end(h) <> rest

# blank, or a horizontal rule drawn by a TUI
def is_rule(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{Chr{+c}, t}:
      (U32.is_eq(c, 9472) || U32.is_eq(c, 9473) || U32.is_eq(c, 45) || U32.is_eq(c, 61) || U32.is_eq(c, 32)) && is_rule(t)

def nonblank(lines: List<&2, String>) -> List<&2, String>:
  match lines:
    case Nil{}:
      []
    case Con{+h, t}:
      nonblank.put(is_rule(String.trim(h)), h, nonblank(t))

def last_lines(+text: String, +n: Nat) -> String:
  String.join(List.reverse(&2, String, List.take(&2, String, List.reverse(&2, String, nonblank(String.lines(text))), n)), "\n")

def indent(lines: List<&2, String>) -> String:
  match lines:
    case Nil{}:
      ""
    case Con{h, t}:
      "    | " ++ h ++ "\n" ++ indent(t)

def title_part.if(empty: Bool, title: String) -> String:
  match empty:
    case True{}:
      ""
    case False{}:
      ", title: " ++ clip(title, 80n)

def title_part(+title: String) -> String:
  title_part.if(String.is_empty(title), title)

# The state Jev reads
# -------------------

def agent_line(+home: String, +i: Nat, s: Seen) -> String:
  match s:
    case Seen{M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}, recent}:
      idx("a", i) ++ ": " ++ kind ++ " agent in " ++ short(home, cwd) ++ " (" ++ M.Status.show(status) ++ ")" ++ title_part(title) ++ "\n" ++ indent(String.lines(last_lines(recent, 6n)))

def agents_text(xs: List<&2, Seen>, +home: String, +i: Nat) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{s, t}:
      agent_line(home, i, s) ++ agents_text(t, home, 1n+i)

def desc_part.if(empty: Bool, d: String) -> String:
  match empty:
    case True{}:
      ""
    case False{}:
      ". " ++ clip(d, 160n)

def desc_part(+d: String) -> String:
  desc_part.if(String.is_empty(d), d)

def recent_part.if(empty: Bool, r: String) -> String:
  match empty:
    case True{}:
      ""
    case False{}:
      ". Recent commits: " ++ clip(r, 160n)

def recent_part(+r: String) -> String:
  recent_part.if(String.is_empty(r), r)

# When the folder was last worked on (its last commit), and how often the user
# has started sessions there: when a request names no project, the folder the
# user has been in lately is the likelier one.
def ago.pick(lt1: Bool, lt48: Bool, +h: U32) -> String:
  match lt1 lt48:
    case True{} _:
      "within the hour"
    case False{} True{}:
      U32.show(h) ++ " hours ago"
    case False{} False{}:
      U32.show(U32.div(h, 24)) ++ " days ago"

def age_part(+age: U32) -> String:
  " Last worked on " ++ ago.pick(U32.is_lt(age, 1), U32.is_lt(age, 48), age) ++ "."

def uses_part.if(none: Bool, +n: U32) -> String:
  match none:
    case True{}:
      ""
    case False{}:
      " The user started " ++ U32.show(n) ++ " sessions here before."

def uses_part(+n: U32) -> String:
  uses_part.if(U32.is_eq(n, 0), n)

def folder_line(+home: String, +i: Nat, f: M.Folder) -> String:
  match f:
    case M.Folder{path, name, desc, recent, branch, +age, +uses}:
      idx("f", i) ++ ": " ++ name ++ " — " ++ short(home, path) ++ desc_part(desc) ++ recent_part(recent) ++ age_part(age) ++ uses_part(uses) ++ "\n"

def folders_text(xs: List<&2, M.Folder>, +home: String, +i: Nat) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{f, t}:
      folder_line(home, i, f) ++ folders_text(t, home, 1n+i)

def section_pick(empty: Bool, title: String, body: String) -> String:
  match empty:
    case True{}:
      ""
    case False{}:
      "\n" ++ title ++ "\n" ++ body

def section_of(+title: String, +body: String) -> String:
  section_pick(String.is_empty(body), title, body)

# An earlier conversation, as Jev reads it.
def past_line(+home: String, +i: Nat, p: P.Past) -> String:
  match p:
    case P.Past{agent, id, cwd, title, last, +age, state}:
      idx("p", i) ++ ": " ++ agent ++ " conversation " ++ Js.str(title) ++ " in " ++ short(home, cwd) ++ "," ++ age_part(age) ++ " Last asked: " ++ Js.str(clip(last, 160n)) ++ "\n"

def pasts_text(xs: List<&2, P.Past>, +home: String, +i: Nat) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{p, t}:
      past_line(home, i, p) ++ pasts_text(t, home, 1n+i)

# `memory`: what the user sent where lately, and where they corrected a
# pick for a similar request (written by the app; may be empty).
def state_text(text: String, +home: String, seen: List<&2, Seen>, folders: List<&2, M.Folder>, pasts: List<&2, P.Past>, +memory: String) -> String:
  "The user said: " ++ Js.str(text) ++ "\n" ++ section_of("Live coding-agent sessions (terminal panes):", agents_text(seen, home, 0n)) ++ section_of("Folders where a new session could be started:", folders_text(folders, home, 0n)) ++ section_of("Earlier conversations, not running, that could be resumed:", pasts_text(pasts, home, 0n)) ++ section_of("What the user did before (use it for follow-ups and to follow their corrections):", memory)

# Questions
# ---------

def agent_choice(+home: String, +i: Nat, s: Seen) -> String:
  match s:
    case Seen{M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}, recent}:
      Js.kv(idx("a", i), Js.str(kind ++ " in " ++ short(home, cwd) ++ title_part(title)))

def agent_choices(xs: List<&2, Seen>, +home: String, +i: Nat) -> List<&2, String>:
  match xs:
    case Nil{}:
      [Js.kv("new", Js.str("none of these sessions: start a new session in a folder"))]
    case Con{s, t}:
      agent_choice(home, i, s) <> agent_choices(t, home, 1n+i)

def folder_choice(+home: String, +i: Nat, f: M.Folder) -> String:
  match f:
    case M.Folder{path, name, desc, recent, branch, age, uses}:
      Js.kv(idx("f", i), Js.str(name ++ " (" ++ short(home, path) ++ ")"))

def folder_choices(xs: List<&2, M.Folder>, +home: String, +i: Nat) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{f, t}:
      folder_choice(home, i, f) <> folder_choices(t, home, 1n+i)

def target_q(+home: String, seen: List<&2, Seen>) -> String:
  Js.kv("target", Js.obj([
    Js.kv("type", Js.str("choice")),
    Js.kv("instructions", Js.str("Which live session is the user's request meant for? Match the project, files and topic the user mentions against each session's folder, title and recent output. Choose new when the request is about a different project or no session fits. If the request follows on from something the user just sent (also, that, there, again, the same, or the same topic), choose the session it went to. Where the user corrected an earlier pick for a similar request, choose what they chose.")),
    Js.kv("criteria", Js.obj(agent_choices(seen, home, 0n))),
  ]))

def folder_q(+home: String, folders: List<&2, M.Folder>) -> String:
  Js.kv("folder", Js.obj([
    Js.kv("type", Js.str("choice")),
    Js.kv("instructions", Js.str("If a new session is started for this request, which folder is the request about? Prefer a folder the user names; otherwise the folder whose name, description or recent commits match the request. When several fit about equally, or the request names no project, prefer the one worked on most recently. Where the user corrected an earlier pick for a similar request, choose what they chose.")),
    Js.kv("criteria", Js.obj(folder_choices(folders, home, 0n))),
  ]))

def side_q() -> String:
  Js.kv("side", Js.obj([
    Js.kv("type", Js.str("noul")),
    Js.kv("instructions", Js.str("Is this a quick side question about what an agent is doing or has done (like 'btw, why did you...?', 'what does X mean?'), to be answered without interrupting or redirecting the agent's work? Answer no for new instructions or tasks.")),
  ]))

def past_choice(+home: String, +i: Nat, p: P.Past) -> String:
  match p:
    case P.Past{agent, id, cwd, title, last, age, state}:
      Js.kv(idx("p", i), Js.str(agent ++ " conversation " ++ title ++ " (" ++ short(home, cwd) ++ ")"))

def past_choices(xs: List<&2, P.Past>, +home: String, +i: Nat) -> List<&2, String>:
  match xs:
    case Nil{}:
      [Js.kv("none", Js.str("none: this is new work, even if it is in the same project"))]
    case Con{p, t}:
      past_choice(home, i, p) <> past_choices(t, home, 1n+i)

def resume_q(+home: String, pasts: List<&2, P.Past>) -> String:
  Js.kv("resume", Js.obj([
    Js.kv("type", Js.str("choice")),
    Js.kv("instructions", Js.str("Does the user want to go back to one of these earlier conversations? Choose one only when the request clearly continues that specific earlier work — it says continue, resume, back to, finish, or names the same task and topic. A new task, even in the same project, is none. When unsure, choose none.")),
    Js.kv("criteria", Js.obj(past_choices(pasts, home, 0n))),
  ]))

def questions.pasts(+home: String, pasts: List<&2, P.Past>) -> List<&2, String>:
  match pasts:
    case Nil{}:
      []
    case Con{p, t}:
      [resume_q(home, p <> t)]

def questions.agents(+home: String, seen: List<&2, Seen>) -> List<&2, String>:
  match seen:
    case Nil{}:
      []
    case Con{s, t}:
      [target_q(home, s <> t), side_q()]

def questions.folders(+home: String, folders: List<&2, M.Folder>) -> List<&2, String>:
  match folders:
    case Nil{}:
      []
    case Con{f, t}:
      [folder_q(home, f <> t)]

def questions(+home: String, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +pasts: List<&2, P.Past>) -> List<&2, String>:
  List.append(&2, String, List.append(&2, String, questions.agents(home, seen), questions.folders(home, folders)), questions.pasts(home, pasts))

# One `jev` request line for `jev-fabric -- serve`.
def request(+text: String, +home: String, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +pasts: List<&2, P.Past>, +memory: String) -> String:
  Js.obj([
    Js.kv("id", "1"),
    Js.kv("op", Js.str("jev")),
    Js.kv("request", Js.obj([
      Js.kv("state", Js.str(state_text(text, home, seen, folders, pasts, memory))),
      Js.kv("questions", Js.obj(questions(home, seen, folders, pasts))),
    ])),
  ]) ++ "\n"

def digit.if(ok: Bool, +code: U32) -> Maybe<&2, U32>:
  match ok:
    case True{}:
      Some{(code - 48 : U32)}
    case False{}:
      None{}

# Reading Jev's answer
# --------------------

# Basis points (0..10000) of a JSON probability lexeme such as "0.97", "1.0",
# "1" or "3e-05" (any negative exponent reads as 0).
def digit(c: Char) -> Maybe<&2, U32>:
  match c:
    case Chr{+code}:
      digit.if(U32.is_le(48, code) && U32.is_le(code, 57), code)

def frac.add(d: Maybe<&2, U32>, +scale: U32, rest: U32) -> U32:
  match d:
    case None{}:
      0
    case Some{+v}:
      (v * scale + rest : U32)

def frac(s: String, +scale: U32) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{c, t}:
      frac.add(digit(c), scale, frac(t, U32.div(scale, 10)))

def bp.dot.if(dot: Bool, rest: String) -> U32:
  match dot:
    case True{}:
      frac(rest, 1000)
    case False{}:
      0

def bp.dot(t: String) -> U32:
  match t:
    case SCon{Chr{+c}, rest}:
      bp.dot.if(U32.is_eq(c, 46), rest)
    case SNil{}:
      0

def bp.lead(one: Bool, zero: Bool, t: String) -> U32:
  match one zero:
    case True{} _:
      10000
    case False{} True{}:
      bp.dot(t)
    case False{} False{}:
      0

def bp.int(lex: String) -> U32:
  match lex:
    case SCon{Chr{+c}, t}:
      bp.lead(U32.is_eq(c, 49), U32.is_eq(c, 48), t)
    case SNil{}:
      0

def bp.exp(tiny: Bool, lex: String) -> U32:
  match tiny:
    case True{}:
      0
    case False{}:
      bp.int(lex)

def bp_of(+lex: String) -> U32:
  bp.exp(String.contains(lex, "e-") || String.contains(lex, "E-"), lex)

# A choice answer: the picked key, its probability (bp), and every key's bp.
type Prob is Data:
  Prob{key: String, bp: U32}

type Pick is Data:
  Pick{key: String, bp: U32, all: List<&2, Prob>}

def probs(fields: List<&2, J.JSON>) -> List<&2, Prob>:
  match fields:
    case Nil{}:
      []
    case Con{J.Member{name, value}, t}:
      Prob{name, bp_of(Js.text_of(value))} <> probs(t)
    case Con{other, t}:
      probs(t)

def fields_of(m: Maybe<&2, J.JSON>) -> List<&2, J.JSON>:
  match m:
    case Some{J.Obj{fields}}:
      fields
    case other:
      []

def lookup_bp.pick(hit: Bool, +v: U32, rest: U32) -> U32:
  match hit:
    case True{}:
      v
    case False{}:
      rest

def lookup_bp(xs: List<&2, Prob>, +key: String) -> U32:
  match xs:
    case Nil{}:
      0
    case Con{Prob{k, +v}, t}:
      lookup_bp.pick(String.eq(k, key), v, lookup_bp(t, key))

def pick_of.with(+key: String, +all: List<&2, Prob>) -> Pick:
  Pick{key, lookup_bp(all, key), all}

def pick_of(+ans: J.JSON) -> Pick:
  pick_of.with(Js.text_at(ans, "choice"), probs(fields_of(Js.get(ans, "probabilities"))))

def pick.of(m: Maybe<&2, J.JSON>) -> Maybe<&2, Pick>:
  match m:
    case Some{+a}:
      Some{pick_of(a)}
    case None{}:
      None{}

def pick(+answers: J.JSON, name: String) -> Maybe<&2, Pick>:
  pick.of(Js.get(answers, name))

def noul_bp(+answers: J.JSON) -> U32:
  bp_of(Js.as_text(Js.path(["side", "noul"], Some{answers})))

def answers_of.pick(ok: Bool, a: Maybe<&2, J.JSON>, e1: String, e2: String) -> Result<&1, &1, U32 & String, J.JSON>:
  match ok a:
    case True{} Some{x}:
      Done{x}
    case _ _:
      Fail{(1, "jev: " ++ Js.or_else(e2, Js.or_else(e1, "no answers")))}

# The answers object of a serve response line, or the error it reports.
def answers_of(+v: J.JSON) -> Result<&1, &1, U32 & String, J.JSON>:
  answers_of.pick(Js.as_bool(Js.get(v, "ok")), Js.path(["result", "answers"], Some{v}), Js.text_at(v, "error"), Js.as_text(Js.path(["error", "message"], Some{v})))

def response.parsed(r: Result<&1, &1, U32 & String, J.JSON>) -> Result<&1, &1, U32 & String, J.JSON>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{+v}:
      answers_of(v)

def response.lines(ls: List<&2, String>) -> Result<&1, &1, U32 & String, J.JSON>:
  match ls:
    case Con{banner, Con{line, rest}}:
      response.parsed(Js.read(line))
    case other:
      Fail{(1, "jev-fabric: no response")}

# The serve output: a banner line, then one response line.
def response(out: String) -> Result<&1, &1, U32 & String, J.JSON>:
  response.lines(nonblank(String.lines(out)))

# Deciding
# --------

def harnesses() -> List<&2, String>:
  ["claude", "codex", "pi", "grok", "opencode", "amp", "gemini", "cursor", "droid", "copilot", "omp", "kimi"]

def mentioned.pick(hit: Bool, t: String, rest: Maybe<&2, String>) -> Maybe<&2, String>:
  match hit:
    case True{}:
      Some{t}
    case False{}:
      rest

def mentioned(toks: List<&2, String>, +hs: List<&2, String>) -> Maybe<&2, String>:
  match toks:
    case Nil{}:
      None{}
    case Con{+t, rest}:
      mentioned.pick(List.contains(~String, ~String.eq, hs, t), t, mentioned(rest, hs))

def words(text: String) -> List<&2, String>:
  String.split(String.to_lower(text), ' ')

def harness.pick(m: Maybe<&2, String>, default: String) -> String:
  match m:
    case Some{h}:
      h
    case None{}:
      default

# The harness for a new session: one the user names, else the default.
def harness(+text: String, +default: String) -> String:
  harness.pick(mentioned(words(text), harnesses()), default)

def forced_side(+text: String) -> Bool:
  String.starts_with(String.to_lower(String.trim(text)), "btw") || String.starts_with(String.trim(text), "/btw")

def drop_slash.if(slash: Bool, +c: U32, t: String) -> String:
  match slash:
    case True{}:
      t
    case False{}:
      SCon{Chr{c}, t}

def drop_slash(s: String) -> String:
  match s:
    case SCon{Chr{+c}, t}:
      drop_slash.if(U32.is_eq(c, 47), c, t)
    case SNil{}:
      SNil{}

def drop_punct.if(p: Bool, +c: U32, t: String) -> String:
  match p:
    case True{}:
      t
    case False{}:
      SCon{Chr{c}, t}

def drop_punct(s: String) -> String:
  match s:
    case SCon{Chr{+c}, t}:
      drop_punct.if(U32.is_eq(c, 44) || U32.is_eq(c, 58), c, t)
    case SNil{}:
      SNil{}

def side_text.if(forced: Bool, t: String) -> String:
  match forced:
    case True{}:
      String.trim_start(drop_punct(String.drop(drop_slash(t), 3n)))
    case False{}:
      t

# "btw, why x" -> "why x"; other text unchanged
def side_text(+text: String) -> String:
  side_text.if(forced_side(text), String.trim(text))

# How a side question reaches an agent without interrupting it.
#   claude: its native /btw (no tools, shares the prompt cache) while it can
#           take input; when blocked on a dialog, a headless forked session
#   pi:     a headless fork of its session (`pi --fork`), same cached prefix
#   others: no safe side channel: ask the user instead
type Side is Data:
  Native{}
  Forked{}
  NoSide{}

def side_blocked(s: M.Status) -> Bool:
  match s:
    case M.Blocked{}:
      True{}
    case other:
      False{}

def side_for.of(claude: Bool, pi: Bool, blocked: Bool) -> Side:
  match claude pi blocked:
    case True{} _ False{}:
      Native{}
    case True{} _ True{}:
      Forked{}
    case False{} True{} _:
      Forked{}
    case False{} False{} _:
      NoSide{}

def side_for(+kind: String, +status: M.Status) -> Side:
  side_for.of(String.eq(kind, "claude"), String.eq(kind, "pi"), side_blocked(status))

def leaf.pick(empty: Bool, h: String, last: String) -> String:
  match empty:
    case True{}:
      last
    case False{}:
      h

def leaf.go(cs: List<&2, String>, last: String) -> String:
  match cs:
    case Nil{}:
      last
    case Con{+h, t}:
      leaf.go(t, leaf.pick(String.is_empty(h), h, last))

# The last path component: /a/b/herdr -> herdr
def leaf(+path: String) -> String:
  leaf.go(String.split(path, '/'), path)

def label_agent(+home: String, +kind: String, +cwd: String) -> String:
  kind ++ " · " ++ leaf(cwd)

def side_decision(side: Side, a: M.Agent, +text: String, +home: String, +default: String) -> Decision:
  match side a:
    case Native{} M.Agent{+pane, name, +kind, status, +cwd, title, seq, session, screen}:
      Go{M.SideNative{pane, text}, "btw → " ++ label_agent(home, kind, cwd), "side question; native /btw"}
    case Forked{} M.Agent{+pane, name, +kind, status, +cwd, title, seq, session, screen}:
      Go{M.SideFork{pane, kind, cwd, session, text}, "btw → fork of " ++ label_agent(home, kind, cwd), "side question; forked session"}
    case NoSide{} M.Agent{+pane, name, +kind, status, +cwd, title, seq, session, screen}:
      Choose{"No side channel for " ++ kind ++ ": how should this go?", [
        M.Opt{"1", "send to " ++ label_agent(home, kind, cwd) ++ " as a prompt", M.Prompt{pane, text}},
        M.Opt{"2", "ask a new " ++ default ++ " session in " ++ leaf(cwd), M.Spawn{cwd, default, text}},
      ], "side question for a harness without /btw or fork"}

def agent_decision(side: Bool, a: M.Agent, +text: String, +home: String, +default: String) -> Decision:
  match side a:
    case True{} M.Agent{+pane, name, +kind, +status, +cwd, title, seq, session, screen}:
      side_decision(side_for(kind, status), M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}, side_text(text), home, default)
    case False{} M.Agent{+pane, name, +kind, status, +cwd, title, seq, session, screen}:
      Go{M.Prompt{pane, text}, "→ " ++ label_agent(home, kind, cwd), "routed to a live session"}

def spawn_decision(f: M.Folder, +text: String, +home: String, +default: String) -> Decision:
  match f:
    case M.Folder{+path, name, desc, recent, branch, age, uses}:
      Go{M.Spawn{path, harness(text, default), text}, "new " ++ harness(text, default) ++ " in " ++ leaf(path), "new session in a folder"}

def nth_seen.pick(hit: Bool, a: M.Agent, rest: Maybe<&2, M.Agent>) -> Maybe<&2, M.Agent>:
  match hit:
    case True{}:
      Some{a}
    case False{}:
      rest

def nth_seen(xs: List<&2, Seen>, +key: String, +prefix: String, +i: Nat) -> Maybe<&2, M.Agent>:
  match xs:
    case Nil{}:
      None{}
    case Con{Seen{a, r}, t}:
      nth_seen.pick(String.eq(key, idx(prefix, i)), a, nth_seen(t, key, prefix, 1n+i))

def nth_folder.pick(hit: Bool, f: M.Folder, rest: Maybe<&2, M.Folder>) -> Maybe<&2, M.Folder>:
  match hit:
    case True{}:
      Some{f}
    case False{}:
      rest

def nth_folder(xs: List<&2, M.Folder>, +key: String, +i: Nat) -> Maybe<&2, M.Folder>:
  match xs:
    case Nil{}:
      None{}
    case Con{f, t}:
      nth_folder.pick(String.eq(key, idx("f", i)), f, nth_folder(t, key, 1n+i))

# Options for an unsure route: every candidate Jev gave weight to, best first.
type Ranked is Data:
  Ranked{bp: U32, label: String, action: M.Action}

def ranked_le(a: Ranked, b: Ranked) -> Bool:
  match a b:
    case Ranked{+x, la, aa} Ranked{+y, lb, ab}:
      U32.is_ge(x, y)

def seen_ranked(xs: List<&2, Seen>, +all: List<&2, Prob>, +text: String, +home: String, +i: Nat) -> List<&2, Ranked>:
  match xs:
    case Nil{}:
      []
    case Con{Seen{M.Agent{+pane, name, +kind, status, +cwd, title, seq, session, screen}, r}, t}:
      Ranked{lookup_bp(all, idx("a", i)), "→ " ++ label_agent(home, kind, cwd), M.Prompt{pane, text}} <> seen_ranked(t, all, text, home, 1n+i)

def folder_ranked(xs: List<&2, M.Folder>, +all: List<&2, Prob>, +new_bp: U32, +text: String, +home: String, +default: String, +i: Nat) -> List<&2, Ranked>:
  match xs:
    case Nil{}:
      []
    case Con{M.Folder{+path, name, desc, recent, branch, age, uses}, t}:
      Ranked{U32.div((lookup_bp(all, idx("f", i)) * U32.max(new_bp, 1) : U32), 10000), "new " ++ harness(text, default) ++ " in " ++ leaf(path), M.Spawn{path, harness(text, default), text}} <> folder_ranked(t, all, new_bp, text, home, default, 1n+i)

def opts_of(xs: List<&2, Ranked>, +i: U32, n: Nat) -> List<&2, M.Opt>:
  match xs n:
    case Nil{} _:
      []
    case Con{h, t} 0n:
      []
    case Con{Ranked{+bp, label, action}, t} 1n+p:
      M.Opt{U32.show(i), label ++ " (" ++ U32.show(U32.div(bp, 100)) ++ "%)", action} <> opts_of(t, (i + 1 : U32), p)

def all_of(m: Maybe<&2, Pick>) -> List<&2, Prob>:
  match m:
    case Some{Pick{k, b, all}}:
      all
    case None{}:
      []

# How much Jev leans to "new session" (all of it when there are no agents).
def new_weight(m: Maybe<&2, Pick>) -> U32:
  match m:
    case None{}:
      10000
    case Some{Pick{k, b, +all}}:
      lookup_bp(all, "new")

def worth.put(keep: Bool, r: Ranked, rest: List<&2, Ranked>) -> List<&2, Ranked>:
  match keep:
    case True{}:
      r <> rest
    case False{}:
      rest

def Ranked.bp(r: Ranked) -> U32:
  match r:
    case Ranked{bp, label, action}:
      bp

# Keep the two best options, then only those Jev gave at least 3%.
def worth(xs: List<&2, Ranked>, +kept: Nat) -> List<&2, Ranked>:
  match xs:
    case Nil{}:
      []
    case Con{+r, t}:
      worth.put(Nat.is_lt(kept, 2n) || U32.is_ge(Ranked.bp(r), 300), r, worth(t, 1n+kept))

def choose(+target: Maybe<&2, Pick>, +folder: Maybe<&2, Pick>, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +text: String, +home: String, +default: String, why: String) -> Decision:
  Choose{"Where should this go?", opts_of(worth(List.sort(~Ranked, ~ranked_le, List.append(&2, Ranked, seen_ranked(seen, all_of(target), text, home, 0n), folder_ranked(folders, all_of(folder), new_weight(target), text, home, default, 0n))), 0n), 1, 4n), why}

def confident(+bp: U32, +threshold: U32) -> Bool:
  U32.is_ge(bp, threshold)

def Pick.key(p: Pick) -> String:
  match p:
    case Pick{key, bp, all}:
      key

def Pick.bp(p: Pick) -> U32:
  match p:
    case Pick{key, bp, all}:
      bp

def decide.folder.pick(sure: Bool, m: Maybe<&2, M.Folder>, +text: String, +home: String, +default: String, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +target: Maybe<&2, Pick>, +folder: Maybe<&2, Pick>) -> Decision:
  match sure m:
    case True{} Some{f}:
      spawn_decision(f, text, home, default)
    case _ _:
      choose(target, folder, seen, folders, text, home, default, "folder choice below the confidence threshold")

def decide.folder(m: Maybe<&2, Pick>, +text: String, +home: String, +default: String, +threshold: U32, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +target: Maybe<&2, Pick>, +folder: Maybe<&2, Pick>) -> Decision:
  match m:
    case None{}:
      Broke{"nothing to route to: no live sessions and no indexed folders"}
    case Some{+f}:
      decide.folder.pick(confident(Pick.bp(f), threshold), nth_folder(folders, Pick.key(f), 0n), text, home, default, seen, folders, target, folder)

def decide.target(sure: Bool, is_new: Bool, agent: Maybe<&2, M.Agent>, +text: String, +home: String, +default: String, +threshold: U32, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +target: Maybe<&2, Pick>, +folder: Maybe<&2, Pick>, +side: U32) -> Decision:
  match sure is_new agent:
    case True{} False{} Some{a}:
      agent_decision(U32.is_ge(side, 5000) || forced_side(text), a, text, home, default)
    case True{} True{} _:
      decide.folder(folder, text, home, default, threshold, seen, folders, target, folder)
    case _ _ _:
      choose(target, folder, seen, folders, text, home, default, "session choice below the confidence threshold")

# The decision for a request.
#   side   - Jev's noul that this is a side question (bp), or forced by "btw"
#   target - Jev's choice among live sessions (absent when there are none)
#   folder - Jev's choice among folders (absent when there are none)
def decide(+text: String, +home: String, +default: String, +threshold: U32, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +target: Maybe<&2, Pick>, +folder: Maybe<&2, Pick>, +side: U32) -> Decision:
  match target:
    case Some{+t}:
      decide.target(confident(Pick.bp(t), threshold), String.eq(Pick.key(t), "new"), nth_seen(seen, Pick.key(t), "a", 0n), text, home, default, threshold, seen, folders, target, folder, side)
    case None{}:
      decide.folder(folder, text, home, default, threshold, seen, folders, target, folder)

# Resuming an earlier conversation
# --------------------------------

def claude_args.pick(attach: Bool, fork: Bool, +id: String) -> List<&2, String>:
  match attach fork:
    case True{} _:
      ["attach", id]
    case False{} True{}:
      ["--resume", id, "--fork-session"]
    case False{} False{}:
      ["--resume", id]

def claude_args(+mode: String, +id: String) -> List<&2, String>:
  claude_args.pick(String.eq(mode, "attach"), String.eq(mode, "fork"), id)

def pi_args.pick(fork: Bool, +id: String) -> List<&2, String>:
  match fork:
    case True{}:
      ["--fork", id]
    case False{}:
      ["--session", id]

def resume_args.pick(claude: Bool, pi: Bool, codex: Bool, +mode: String, +id: String) -> List<&2, String>:
  match claude pi codex:
    case True{} _ _:
      claude_args(mode, id)
    case False{} True{} _:
      pi_args.pick(String.eq(mode, "fork"), id)
    case False{} False{} True{}:
      ["resume", id]
    case False{} False{} False{}:
      ["--resume", id]

# The agent's own arguments to bring a session back.
def resume_args(+kind: String, +mode: String, +id: String) -> List<&2, String>:
  resume_args.pick(String.eq(kind, "claude"), String.eq(kind, "pi"), String.eq(kind, "codex"), mode, id)

# A separate question, defaulting to "none", and a step after the decision:
# it may turn the decision into a resume only when Jev is sure, and never
# when a live session already won (sending there is the stronger reading).

def mode_of.pick(running: Bool, elsewhere: Bool) -> String:
  match running elsewhere:
    case True{} _:
      "attach"
    case False{} True{}:
      "fork"
    case False{} False{}:
      "resume"

def mode_of(+state: String) -> String:
  mode_of.pick(String.eq(state, "running"), String.eq(state, "elsewhere"))

def resume_action(p: P.Past, +text: String) -> M.Action:
  match p:
    case P.Past{+agent, +id, +cwd, title, last, age, +state}:
      M.Resume{cwd, agent, id, mode_of(state), text}

def resume_label(p: P.Past) -> String:
  match p:
    case P.Past{+agent, id, cwd, +title, last, age, state}:
      "resume " ++ agent ++ " · " ++ clip(title, 48n)

def nth_past.pick(hit: Bool, p: P.Past, rest: Maybe<&2, P.Past>) -> Maybe<&2, P.Past>:
  match hit:
    case True{}:
      Some{p}
    case False{}:
      rest

def nth_past(xs: List<&2, P.Past>, +key: String, +i: Nat) -> Maybe<&2, P.Past>:
  match xs:
    case Nil{}:
      None{}
    case Con{p, t}:
      nth_past.pick(String.eq(key, idx("p", i)), p, nth_past(t, key, 1n+i))

# A decision that already sends to a live session.
def live_go(d: Decision) -> Bool:
  match d:
    case Go{M.Prompt{pane, t}, label, why}:
      True{}
    case Go{M.SideNative{pane, t}, label, why}:
      True{}
    case Go{M.SideFork{pane, kind, cwd, session, t}, label, why}:
      True{}
    case other:
      False{}

def promote.pick(live: Bool, m: Maybe<&2, P.Past>, d: Decision, +text: String) -> Decision:
  match live m:
    case True{} _:
      d
    case False{} None{}:
      d
    case False{} Some{+p}:
      Go{resume_action(p, text), resume_label(p), "continues an earlier conversation"}

def with_past(sure: Bool, +key: String, +pasts: List<&2, P.Past>, +d: Decision, +text: String) -> Decision:
  match sure:
    case False{}:
      d
    case True{}:
      promote.pick(live_go(d), nth_past(pasts, key, 0n), d, text)

def resume_key(m: Maybe<&2, Pick>) -> String:
  match m:
    case Some{Pick{key, bp, all}}:
      key
    case None{}:
      "none"

def resume_bp(m: Maybe<&2, Pick>) -> U32:
  match m:
    case Some{Pick{key, bp, all}}:
      bp
    case None{}:
      0

def decide_with_past(+resume: Maybe<&2, Pick>, +text: String, +home: String, +default: String, +threshold: U32, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +pasts: List<&2, P.Past>, +target: Maybe<&2, Pick>, +folder: Maybe<&2, Pick>, +side: U32) -> Decision:
  with_past(confident(resume_bp(resume), threshold), resume_key(resume), pasts, decide(text, home, default, threshold, seen, folders, target, folder, side), text)

# The decision for a raw `jev-fabric -- serve` output.
def decide_answers(r: Result<&1, &1, U32 & String, J.JSON>, +text: String, +home: String, +default: String, +threshold: U32, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +pasts: List<&2, P.Past>) -> Decision:
  match r:
    case Fail{(code, msg)}:
      Broke{msg}
    case Done{+answers}:
      decide_with_past(pick(answers, "resume"), text, home, default, threshold, seen, folders, pasts, pick(answers, "target"), pick(answers, "folder"), noul_bp(answers))

def decide_output(+out: String, +text: String, +home: String, +default: String, +threshold: U32, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +pasts: List<&2, P.Past>) -> Decision:
  decide_answers(response(out), text, home, default, threshold, seen, folders, pasts)

# JSON of a decision, for the route response.
def Decision.json(d: Decision) -> String:
  match d:
    case Go{action, label, why}:
      Js.obj([Js.kv("decision", Js.str("go")), Js.kv("label", Js.str(label)), Js.kv("why", Js.str(why)), Js.kv("action", M.Action.json(action))])
    case Choose{title, opts, why}:
      Js.obj([Js.kv("decision", Js.str("choose")), Js.kv("title", Js.str(title)), Js.kv("why", Js.str(why)), Js.kv("options", Js.arr(M.Opt.jsons(opts)))])
    case Broke{message}:
      Js.obj([Js.kv("decision", Js.str("error")), Js.kv("error", Js.str(message))])

# Jev's transport failed (network, interruption): worth one retry.
def transient(+d: Decision) -> Bool:
  match d:
    case Broke{+message}:
      String.contains(message, "transport")
    case other:
      False{}

# Observations used by LAWS.bend
def is_go(d: Decision) -> Bool:
  match d:
    case Go{action, label, why}:
      True{}
    case other:
      False{}

# Live candidates, for a search list
# ----------------------------------
# Every session and folder Jev weighed, best first, with Jev's own decision
# and its side-question score: the Ask bar shows these as you type and lets
# you pick another row. Nothing is sent.

def ranked_json(r: Ranked) -> String:
  match r:
    case Ranked{bp, label, action}:
      Js.obj([Js.kv("bp", Js.num(bp)), Js.kv("label", Js.str(label)), Js.kv("action", M.Action.json(action))])

def ranked_jsons(xs: List<&2, Ranked>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{r, t}:
      ranked_json(r) <> ranked_jsons(t)

def past_ranked(xs: List<&2, P.Past>, +all: List<&2, Prob>, +text: String, +i: Nat) -> List<&2, Ranked>:
  match xs:
    case Nil{}:
      []
    case Con{+p, t}:
      Ranked{lookup_bp(all, idx("p", i)), resume_label(p), resume_action(p, text)} <> past_ranked(t, all, text, 1n+i)

def ranked_all(+target: Maybe<&2, Pick>, +folder: Maybe<&2, Pick>, +resume: Maybe<&2, Pick>, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +pasts: List<&2, P.Past>, +text: String, +home: String, +default: String) -> List<&2, Ranked>:
  List.sort(~Ranked, ~ranked_le, List.append(&2, Ranked, List.append(&2, Ranked, seen_ranked(seen, all_of(target), text, home, 0n), folder_ranked(folders, all_of(folder), new_weight(target), text, home, default, 0n)), past_ranked(pasts, all_of(resume), text, 0n)))

def candidates.with(+target: Maybe<&2, Pick>, +folder: Maybe<&2, Pick>, +resume: Maybe<&2, Pick>, +side: U32, +text: String, +home: String, +default: String, +threshold: U32, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +pasts: List<&2, P.Past>, +ms: U32) -> String:
  Js.obj([
    Js.kv("ok", "true"),
    Js.kv("ms", Js.num(ms)),
    Js.kv("side", Js.num(side)),
    Js.kv("threshold", Js.num(threshold)),
    Js.kv("harness", Js.str(default)),
    Js.kv("decision", Decision.json(decide_with_past(resume, text, home, default, threshold, seen, folders, pasts, target, folder, side))),
    Js.kv("ranked", Js.arr(ranked_jsons(ranked_all(target, folder, resume, seen, folders, pasts, text, home, default)))),
  ])

def candidates_answers(r: Result<&1, &1, U32 & String, J.JSON>, +text: String, +home: String, +default: String, +threshold: U32, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +pasts: List<&2, P.Past>, +ms: U32) -> String:
  match r:
    case Fail{(code, msg)}:
      Js.obj([Js.kv("ok", "false"), Js.kv("error", Js.str(msg)), Js.kv("ms", Js.num(ms))])
    case Done{+answers}:
      candidates.with(pick(answers, "target"), pick(answers, "folder"), pick(answers, "resume"), noul_bp(answers), text, home, default, threshold, seen, folders, pasts, ms)

def candidates_output(+out: String, +text: String, +home: String, +default: String, +threshold: U32, +seen: List<&2, Seen>, +folders: List<&2, M.Folder>, +pasts: List<&2, P.Past>, +ms: U32) -> String:
  candidates_answers(response(out), text, home, default, threshold, seen, folders, pasts, ms)
