import Base
import ./Model.bend as M

# Index: the folder candidates routing offers Jev when a request should start a
# new session. Parsing and ranking are pure; the facts come from
# scripts/reflex-scan.sh (one tab-separated line per folder).
#
# Ranking is deterministic and cheap, so Jev only ever chooses among a short,
# relevant list: folders named in the request first (pinned), then the best
# lexical matches, then recently active folders to fill the list.

# Parsing
# -------

def u32_or(m: Maybe<&2, U32>) -> U32:
  match m:
    case Some{n}:
      n
    case None{}:
      0

def folder_of(fields: List<&2, String>) -> Maybe<&2, M.Folder>:
  match fields:
    case Con{path, Con{name, Con{age, Con{branch, Con{uses, Con{desc, Con{recent, rest}}}}}}}:
      Some{M.Folder{path, name, desc, recent, branch, u32_or(U32.read(age)), u32_or(U32.read(uses))}}
    case other:
      None{}

def add_folder(m: Maybe<&2, M.Folder>, rest: List<&2, M.Folder>) -> List<&2, M.Folder>:
  match m:
    case Some{f}:
      f <> rest
    case None{}:
      rest

def parse_lines(lines: List<&2, String>) -> List<&2, M.Folder>:
  match lines:
    case Nil{}:
      []
    case Con{l, t}:
      add_folder(folder_of(String.split(l, '\t')), parse_lines(t))

def parse(tsv: String) -> List<&2, M.Folder>:
  parse_lines(String.lines(tsv))

# Tokens
# ------

def word_char(+c: U32) -> Bool:
  (U32.is_le(97, c) && U32.is_le(c, 122)) || (U32.is_le(48, c) && U32.is_le(c, 57)) || U32.is_le(128, c)

def blank_of.if(keep: Bool, +c: U32) -> Char:
  match keep:
    case True{}:
      Chr{c}
    case False{}:
      ' '

def blank_of(c: Char) -> Char:
  match c:
    case Chr{+code}:
      blank_of.if(word_char(code), code)

def blank(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{c, t}:
      SCon{blank_of(c), blank(t)}

def stopwords() -> List<&2, String>:
  ["the", "an", "and", "or", "to", "in", "on", "of", "for", "with", "at", "by", "from", "it", "is", "this", "that", "be", "can", "you", "we", "me", "my", "our", "please", "fix", "add", "make", "run", "check", "update", "let", "lets", "us", "do", "does", "what", "how", "why", "where", "when", "into", "about", "some", "any", "all", "new", "use", "using", "also", "then", "now", "just", "get", "set", "see", "look", "there", "here", "btw", "hey", "so", "are", "was", "were", "start", "session", "repo", "project", "folder", "work", "working", "agent", "help", "should", "would", "could", "its", "not", "have", "has", "will", "need", "want", "like", "one", "two", "up", "out", "if", "as", "but", "too"]

def is_stop(+w: String, ws: List<&2, String>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case Con{h, t}:
      String.eq(h, w) || is_stop(w, t)

def Core_not(b: Bool) -> Bool:
  match b:
    case True{}:
      False{}
    case False{}:
      True{}

def long_enough(n: Nat) -> Bool:
  match n:
    case 0n:
      False{}
    case 1n+0n:
      False{}
    case 1n+1n+p:
      True{}

def keep_token(+w: String) -> Bool:
  long_enough(String.length(w)) && Core_not(is_stop(w, stopwords()))

def put_token(keep: Bool, w: String, rest: List<&2, String>) -> List<&2, String>:
  match keep:
    case True{}:
      w <> rest
    case False{}:
      rest

def filter_tokens(ws: List<&2, String>) -> List<&2, String>:
  match ws:
    case Nil{}:
      []
    case Con{+w, t}:
      put_token(keep_token(w), w, filter_tokens(t))

# The words of a request worth matching against folders.
def tokens(text: String) -> List<&2, String>:
  filter_tokens(String.split(blank(String.to_lower(text)), ' '))

# Scoring
# -------

def bonus(hit: Bool, +n: U32) -> U32:
  match hit:
    case True{}:
      n
    case False{}:
      0

def tok_score(+tok: String, +name: String, +path: String, +desc: String, +recent: String) -> U32:
  (bonus(String.eq(name, tok), 12) + bonus(String.contains(name, tok), 6) + bonus(String.contains(path, tok), 2) + bonus(String.contains(desc, tok), 2) + bonus(String.contains(recent, tok), 1) : U32)

def toks_score(toks: List<&2, String>, +name: String, +path: String, +desc: String, +recent: String) -> U32:
  match toks:
    case Nil{}:
      0
    case Con{t, rest}:
      (tok_score(t, name, path, desc, recent) + toks_score(rest, name, path, desc, recent) : U32)

def recency(+age: U32) -> U32:
  (bonus(U32.is_lt(age, 24), 2) + bonus(U32.is_lt(age, 168), 1) + bonus(U32.is_lt(age, 720), 1) : U32)

type Scored is Data:
  Scored{lexical: U32, total: U32, age: U32, folder: M.Folder}

def score.of(+lex: U32, +age: U32, +uses: U32, f: M.Folder) -> Scored:
  Scored{lex, (lex * 4 + recency(age) + U32.min(uses, 6) : U32), age, f}

def score(+toks: List<&2, String>, f: M.Folder) -> Scored:
  match f:
    case M.Folder{+path, +name, +desc, +recent, branch, +age, +uses}:
      score.of(toks_score(toks, String.to_lower(name), String.to_lower(path), String.to_lower(desc), String.to_lower(recent)), age, uses, M.Folder{path, name, desc, recent, branch, age, uses})

def scored_le(a: Scored, b: Scored) -> Bool:
  match a b:
    case Scored{+la, +ta, +aa, fa} Scored{+lb, +tb, +ab, fb}:
      U32.is_gt(ta, tb) || (U32.is_eq(ta, tb) && U32.is_le(aa, ab))

def by_age_le(a: Scored, b: Scored) -> Bool:
  match a b:
    case Scored{la, ta, +aa, fa} Scored{lb, tb, +ab, fb}:
      U32.is_le(aa, ab)

def scored_all(+toks: List<&2, String>, fs: List<&2, M.Folder>) -> List<&2, Scored>:
  match fs:
    case Nil{}:
      []
    case Con{f, t}:
      score(toks, f) <> scored_all(toks, t)

# A folder is named when a word of the request is its name, or the first
# part of it ("talkyform" names talkyform-private, "inloop" inloop.studio).
def names(+name: String, +t: String) -> Bool:
  String.eq(name, t) || String.starts_with(name, t ++ "-") || String.starts_with(name, t ++ "_") || String.starts_with(name, t ++ ".")

def name_in(+name: String, toks: List<&2, String>) -> Bool:
  match toks:
    case Nil{}:
      False{}
    case Con{t, rest}:
      names(name, t) || name_in(name, rest)

def is_pinned(+toks: List<&2, String>, +s: Scored) -> Bool:
  match s:
    case Scored{l, t, a, M.Folder{path, +name, desc, recent, branch, age, uses}}:
      name_in(String.to_lower(name), toks)

def has_lexical(+s: Scored) -> Bool:
  match s:
    case Scored{+l, t, a, f}:
      U32.is_lt(0, l)

type Parts is Data:
  Parts{pinned: List<&2, Scored>, matched: List<&2, Scored>, others: List<&2, Scored>}

def parts_put(pin: Bool, lex: Bool, s: Scored, p: Parts) -> Parts:
  match pin lex p:
    case True{} _ Parts{a, b, c}:
      Parts{s <> a, b, c}
    case False{} True{} Parts{a, b, c}:
      Parts{a, s <> b, c}
    case False{} False{} Parts{a, b, c}:
      Parts{a, b, s <> c}

def partition(+toks: List<&2, String>, xs: List<&2, Scored>) -> Parts:
  match xs:
    case Nil{}:
      Parts{[], [], []}
    case Con{+s, t}:
      parts_put(is_pinned(toks, s), has_lexical(s), s, partition(toks, t))

def folders_of(xs: List<&2, Scored>) -> List<&2, M.Folder>:
  match xs:
    case Nil{}:
      []
    case Con{Scored{l, t, a, f}, rest}:
      f <> folders_of(rest)

def take(xs: List<&2, M.Folder>, n: Nat) -> List<&2, M.Folder>:
  match xs n:
    case Nil{} _:
      []
    case Con{h, t} 0n:
      []
    case Con{h, t} 1n+p:
      h <> take(t, p)

def rank.parts(p: Parts, +k: Nat) -> List<&2, M.Folder>:
  match p:
    case Parts{pinned, matched, others}:
      take(List.append(&2, M.Folder, folders_of(pinned), List.append(&2, M.Folder, folders_of(List.sort(~Scored, ~scored_le, matched)), folders_of(List.sort(~Scored, ~by_age_le, others)))), k)

def rank.toks(+toks: List<&2, String>, fs: List<&2, M.Folder>, +k: Nat) -> List<&2, M.Folder>:
  rank.parts(partition(toks, scored_all(toks, fs)), k)

# The k best folders for a request: pinned names, lexical matches, then the
# most recently active folders.
def rank(text: String, fs: List<&2, M.Folder>, +k: Nat) -> List<&2, M.Folder>:
  rank.toks(tokens(text), fs, k)
