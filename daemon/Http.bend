import Base

# Pure HTTP/1.1: parse one request read by Host.http_read, and build one
# response. Every response closes its connection.

type Header is Data:
  Header{name: String, value: String}

type Req is Data:
  Req{method: String, path: String, query: List<&2, Header>, headers: List<&2, Header>, body: String}

# Parsing
# -------

def hex_val.pick(d: Bool, lo: Bool, up: Bool, +c: U32) -> U32:
  match d lo up:
    case True{} _ _:
      (c - 48 : U32)
    case False{} True{} _:
      (c - 87 : U32)
    case False{} False{} True{}:
      (c - 55 : U32)
    case False{} False{} False{}:
      0

def before.pick(hit: Bool, c: Char, rest: String) -> String:
  match hit:
    case True{}:
      ""
    case False{}:
      SCon{c, rest}

def before(s: String, +sep: Char) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, t}:
      before.pick(Char.is_eq(c, sep), c, before(t, sep))

def after.pick(hit: Bool, t: String, rest: String) -> String:
  match hit:
    case True{}:
      t
    case False{}:
      rest

def after(s: String, +sep: Char) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{+c, +t}:
      after.pick(Char.is_eq(c, sep), t, after(t, sep))

# Split at the first `sep`: (before, after); after is "" when absent.
def cut(+s: String, +sep: Char) -> String & String:
  (before(s, sep), after(s, sep))

def hex_val(+c: U32) -> U32:
  hex_val.pick(U32.is_le(48, c) && U32.is_le(c, 57), U32.is_le(97, c) && U32.is_le(c, 102), U32.is_le(65, c) && U32.is_le(c, 70), c)

# UTF-8 bytes as they come out of %XX escapes, folded back into scalars.
type Dec is Data:
  Dec{need: U32, code: U32, out: String}

def dec_cont(last: Bool, +code: U32, +need: U32, out: String) -> Dec:
  match last:
    case True{}:
      Dec{0, 0, SCon{Chr{code}, out}}
    case False{}:
      Dec{need, code, out}

def dec_byte.of(ascii: Bool, fresh: Bool, two: Bool, three: Bool, +b: U32, +need: U32, +code: U32, out: String) -> Dec:
  match ascii fresh two three:
    case True{} _ _ _:
      Dec{0, 0, SCon{Chr{b}, out}}
    case False{} True{} True{} _:
      Dec{1, U32.and(b, 31), out}
    case False{} True{} False{} True{}:
      Dec{2, U32.and(b, 15), out}
    case False{} True{} False{} False{}:
      Dec{3, U32.and(b, 7), out}
    case False{} False{} _ _:
      dec_cont(U32.is_eq(need, 1), (code * 64 + U32.and(b, 63) : U32), (need - 1 : U32), out)

def dec_byte(+b: U32, d: Dec) -> Dec:
  match d:
    case Dec{+need, +code, out}:
      dec_byte.of(U32.is_lt(b, 128), U32.is_eq(need, 0), U32.is_lt(b, 224), U32.is_lt(b, 240), b, need, code, out)

def dec_char(+c: U32, d: Dec) -> Dec:
  match d:
    case Dec{need, code, out}:
      Dec{0, 0, SCon{Chr{c}, out}}

def url_done(d: Dec) -> String:
  match d:
    case Dec{need, code, out}:
      String.reverse(out)

def url_go(s: String, d: Dec) -> String:
  match s:
    case SNil{}:
      url_done(d)
    case SCon{Chr{37}, SCon{Chr{+a}, SCon{Chr{+b}, t}}}:
      url_go(t, dec_byte((hex_val(a) * 16 + hex_val(b) : U32), d))
    case SCon{Chr{43}, t}:
      url_go(t, dec_byte(32, d))
    case SCon{Chr{+c}, t}:
      url_go(t, dec_char(c, d))

# Decode %XX escapes (UTF-8) and '+' in a query component.
def url_decode(s: String) -> String:
  url_go(s, Dec{0, 0, ""})

def pair_of(kv: String & String) -> Header:
  (k, v) = kv
  Header{url_decode(k), url_decode(v)}

def query_of(parts: List<&2, String>) -> List<&2, Header>:
  match parts:
    case Nil{}:
      []
    case Con{p, t}:
      pair_of(cut(p, '=')) <> query_of(t)

def header_of.pair(kv: String & String) -> Header:
  (k, v) = kv
  Header{String.to_lower(String.trim(k)), String.trim(v)}

def header_of(+line: String) -> Header:
  header_of.pair(cut(line, ':'))

def headers_of(lines: List<&2, String>) -> List<&2, Header>:
  match lines:
    case Nil{}:
      []
    case Con{+l, t}:
      header_of(String.trim_end(l)) <> headers_of(t)

def target_of(t: String & String, method: String, headers: List<&2, Header>, body: String) -> Req:
  (path, q) = t
  Req{method, path, query_of(String.split(q, '&')), headers, body}

def first_of(p: String & String) -> String:
  (a, b) = p
  a

def request_line(l: String & String, headers: List<&2, Header>, body: String) -> Req:
  (method, rest) = l
  target_of(cut(String.trim(first_of(cut(rest, ' '))), '?'), method, headers, body)

def nonblank.put(blank: Bool, h: String, rest: List<&2, String>) -> List<&2, String>:
  match blank:
    case True{}:
      rest
    case False{}:
      h <> rest

def nonblank(lines: List<&2, String>) -> List<&2, String>:
  match lines:
    case Nil{}:
      []
    case Con{+h, t}:
      nonblank.put(String.is_empty(String.trim(h)), h, nonblank(t))

def head_parts(lines: List<&2, String>, body: String) -> Req:
  match lines:
    case Nil{}:
      Req{"", "", [], [], body}
    case Con{first, rest}:
      request_line(cut(String.trim_end(first), ' '), headers_of(nonblank(rest)), body)

def split_head.go(s: String, acc: String) -> String & String:
  match s:
    case SNil{}:
      (String.reverse(acc), "")
    case SCon{Chr{13}, SCon{Chr{10}, SCon{Chr{13}, SCon{Chr{10}, body}}}}:
      (String.reverse(acc), body)
    case SCon{c, t}:
      split_head.go(t, SCon{c, acc})

def parse.split(hb: String & String) -> Req:
  (head, body) = hb
  head_parts(String.lines(head), body)

def parse(raw: String) -> Req:
  parse.split(split_head.go(raw, ""))

def lookup.pick(hit: Bool, v: String, rest: String) -> String:
  match hit:
    case True{}:
      v
    case False{}:
      rest

def lookup(hs: List<&2, Header>, +name: String) -> String:
  match hs:
    case Nil{}:
      ""
    case Con{Header{+k, +v}, t}:
      lookup.pick(String.eq(k, name), v, lookup(t, name))

def Req.query(r: Req, name: String) -> String:
  match r:
    case Req{method, path, query, headers, body}:
      lookup(query, name)

def Req.header(r: Req, name: String) -> String:
  match r:
    case Req{method, path, query, headers, body}:
      lookup(headers, name)

def bearer.pick(yes: Bool, v: String) -> String:
  match yes:
    case True{}:
      String.trim(String.drop(v, 7n))
    case False{}:
      ""

def bearer(+v: String) -> String:
  bearer.pick(String.starts_with(String.to_lower(v), "bearer "), v)

def first_nonempty.pick(empty: Bool, h: String, rest: String) -> String:
  match empty:
    case True{}:
      rest
    case False{}:
      h

def first_nonempty(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{+h, t}:
      first_nonempty.pick(String.is_empty(h), h, first_nonempty(t))

# The token a request presents: Authorization: Bearer, X-Reflex-Token, or ?t=
def token(+r: Req) -> String:
  first_nonempty([bearer(Req.header(r, "authorization")), Req.header(r, "x-reflex-token"), Req.query(r, "t")])

def utf8_len.pick(one: Bool, two: Bool, three: Bool) -> U32:
  match one two three:
    case True{} _ _:
      1
    case False{} True{} _:
      2
    case False{} False{} True{}:
      3
    case False{} False{} False{}:
      4

# Responses
# ---------

def utf8_len(+c: U32) -> U32:
  utf8_len.pick(U32.is_lt(c, 128), U32.is_lt(c, 2048), U32.is_lt(c, 65536))

# Length in UTF-8 bytes (Content-Length counts bytes, not characters).
def byte_len(s: String, +acc: U32) -> U32:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{+c}, t}:
      byte_len(t, (acc + utf8_len(c) : U32))

def reason.pick(ok: Bool, unauth: Bool, missing: Bool, bad: Bool) -> String:
  match ok unauth missing bad:
    case True{} _ _ _:
      "OK"
    case False{} True{} _ _:
      "Unauthorized"
    case False{} False{} True{} _:
      "Not Found"
    case False{} False{} False{} True{}:
      "Bad Request"
    case False{} False{} False{} False{}:
      "Error"

def reason(+code: U32) -> String:
  reason.pick(U32.is_eq(code, 200), U32.is_eq(code, 401), U32.is_eq(code, 404), U32.is_eq(code, 400))

def response(+code: U32, ctype: String, +body: String) -> String:
  "HTTP/1.1 " ++ U32.show(code) ++ " " ++ reason(code) ++ "\r\nContent-Type: " ++ ctype ++ "\r\nContent-Length: " ++ U32.show(byte_len(body, 0)) ++ "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" ++ body

def json(+code: U32, body: String) -> String:
  response(code, "application/json; charset=utf-8", body)

def content_type.pick(html: Bool, js: Bool, css: Bool, svg: Bool, json: Bool) -> String:
  match html js css svg json:
    case True{} _ _ _ _:
      "text/html; charset=utf-8"
    case False{} True{} _ _ _:
      "text/javascript; charset=utf-8"
    case False{} False{} True{} _ _:
      "text/css; charset=utf-8"
    case False{} False{} False{} True{} _:
      "image/svg+xml"
    case False{} False{} False{} False{} True{}:
      "application/json; charset=utf-8"
    case False{} False{} False{} False{} False{}:
      "text/plain; charset=utf-8"

def content_type(+path: String) -> String:
  content_type.pick(String.ends_with(path, ".html"), String.ends_with(path, ".js"), String.ends_with(path, ".css"), String.ends_with(path, ".svg"), String.ends_with(path, ".json"))

def Req.path(r: Req) -> String:
  match r:
    case Req{method, path, query, headers, body}:
      path

def Req.body(r: Req) -> String:
  match r:
    case Req{method, path, query, headers, body}:
      body
