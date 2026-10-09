# SPDX-License-Identifier: Apache-2.0
# Modified for jev-fabric: reject incomplete numbers at delimiters;
# use a structurally decreasing, fuel-bounded encoder (no unsafe definitions).
# JSON
# Adapted from H4ad/bend-stdlib/packages/bend-json/json.bend (Apache-2.0;
# see LICENSE). Packaged separately, without byte wrappers; Unicode decoding,
# checked encoding, and linear output accumulation replace the originals.

import Base

type JSON is Data:
  Null{}
  Boolean{ok: Bool}
  Num{lex: String}
  Str{text: String}
  Arr{items: List<&2, JSON>}
  Obj{fields: List<&2, JSON>}
  Member{name: String, value: JSON}

# Char classes

def JSON.is_ws(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      Bool.or(U32.is_eq(code, 32), Bool.or(U32.is_eq(code, 9),
        Bool.or(U32.is_eq(code, 10), U32.is_eq(code, 13))))

def JSON.is_digit(+c: Char) -> Bool:
  Char.is_digit(c)

def JSON.is_zero(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 48)

def JSON.is_minus(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 45)

def JSON.is_plus(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 43)

def JSON.is_dot(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 46)

def JSON.is_e(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      Bool.or(U32.is_eq(code, 101), U32.is_eq(code, 69))

def JSON.is_quote(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 34)

def JSON.is_slash(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 92)

def JSON.is_lbrk(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 91)

def JSON.is_rbrk(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 93)

def JSON.is_lbra(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 123)

def JSON.is_rbra(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 125)

def JSON.is_comma(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 44)

def JSON.is_colon(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 58)

def JSON.is_ctl(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_lt(code, 32)

def JSON.hex.lo(+code: U32, d: Bool) -> Maybe<&2, U32>:
  match d:
    case True{}:
      Some{U32.sub(code, 48)}
    case False{}:
      None{}

def JSON.hex.up(+code: U32, a: Bool) -> Maybe<&2, U32>:
  match a:
    case True{}:
      Some{U32.add(10, U32.sub(code, 65))}
    case False{}:
      JSON.hex.lo(code, Bool.and(U32.is_ge(code, 48), U32.is_le(code, 57)))

def JSON.hex.low(+code: U32, a: Bool) -> Maybe<&2, U32>:
  match a:
    case True{}:
      Some{U32.add(10, U32.sub(code, 97))}
    case False{}:
      JSON.hex.up(code, Bool.and(U32.is_ge(code, 65), U32.is_le(code, 70)))

def JSON.hex.val(c: Char) -> Maybe<&2, U32>:
  match c:
    case Chr{+code}:
      JSON.hex.low(code, Bool.and(U32.is_ge(code, 97), U32.is_le(code, 102)))

# Constructors

def JSON.null() -> JSON:
  Null{}

def JSON.boolean(ok: Bool) -> JSON:
  Boolean{ok}

def JSON.num(+n: U32) -> JSON:
  Num{U32.show(n)}

def JSON.str(s: String) -> JSON:
  Str{s}

def JSON.array(xs: List<&2, JSON>) -> JSON:
  Arr{xs}

def JSON.object(fs: List<&2, JSON>) -> JSON:
  Obj{fs}

# Show

def JSON.hex.nib.if(+d: U32, small: Bool) -> Char:
  match small:
    case True{}:
      Chr{U32.add(48, d)}
    case False{}:
      Chr{U32.add(87, d)}

def JSON.hex.nib(+d: U32) -> Char:
  JSON.hex.nib.if(d, U32.is_lt(d, 10))

def JSON.hex.pair(+n: U32) -> String:
  SCon{JSON.hex.nib(U32.div(n, 16)), SCon{JSON.hex.nib(U32.mod(n, 16)), SNil{}}}

def JSON.esc.one(+c: Char, q: Bool, sl: Bool, n: Bool, r: Bool, t: Bool,
  b: Bool, f: Bool, ctl: Bool) -> String:
  match q:
    case True{}:
      "\\\""
    case False{}:
      match sl:
        case True{}:
          "\\\\"
        case False{}:
          match n:
            case True{}:
              "\\n"
            case False{}:
              match r:
                case True{}:
                  "\\r"
                case False{}:
                  match t:
                    case True{}:
                      "\\t"
                    case False{}:
                      match b:
                        case True{}:
                          "\\b"
                        case False{}:
                          match f:
                            case True{}:
                              "\\f"
                            case False{}:
                              match ctl:
                                case True{}:
                                  "\\u00" ++ JSON.hex.pair(Char.to_u32(c))
                                case False{}:
                                  SCon{c, SNil{}}

def JSON.esc.chr(+c: Char) -> String:
  match c:
    case Chr{+code}:
      JSON.esc.one(c, U32.is_eq(code, 34), U32.is_eq(code, 92),
        U32.is_eq(code, 10), U32.is_eq(code, 13), U32.is_eq(code, 9),
        U32.is_eq(code, 8), U32.is_eq(code, 12), U32.is_lt(code, 32))

def JSON.esc.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{h, rest}:
      JSON.esc.go(rest, String.append(String.reverse(JSON.esc.chr(h)), acc))

def JSON.esc(s: String) -> String:
  "\"" ++ JSON.esc.go(s, SNil{}) ++ "\""

type JSON.Job is Data:
  JLit{s: String}
  JVal{v: JSON}
  JArr0{xs: List<&2, JSON>}
  JArr1{xs: List<&2, JSON>}
  JObj0{fs: List<&2, JSON>}
  JObj1{fs: List<&2, JSON>}

# Parse

type JSON.NSt is Data:
  NMinus{}
  NZero{}
  NInt{}
  NDot{}
  NFrac{}
  NE{}
  NESign{}
  NExp{}

type JSON.Need is Data:
  NVal{}
  NKey{}
  NColon{}
  NAfter{}
  NEnd{v: JSON}

type JSON.Frame is Data:
  FArr{rev: List<&2, JSON>}
  FObj{rev: List<&2, JSON>}
  FKey{rev: List<&2, JSON>, key: String}

type JSON.Mode is Data:
  MNeed{need: JSON.Need}
  MStr{esc: Bool, hex: U32, hexv: U32, rev: String, as_key: Bool, hi: U32}
  MNum{rev: String, st: JSON.NSt}
  MLit{want: String, v: JSON}
  MFail{pos: U32, msg: String}
  MDone{v: JSON}

type JSON.Walk is Data:
  Walk{mode: JSON.Mode, stk: List<&2, JSON.Frame>}

def JSON.fail(+pos: U32, msg: String) -> JSON.Walk:
  Walk{MFail{pos, msg}, []}

def JSON.nst.start(minus: Bool, zero: Bool) -> JSON.NSt:
  match minus:
    case True{}:
      NMinus{}
    case False{}:
      match zero:
        case True{}:
          NZero{}
        case False{}:
          NInt{}

def JSON.nst.can_end(st: JSON.NSt) -> Bool:
  match st:
    case NZero{}:
      True{}
    case NInt{}:
      True{}
    case NFrac{}:
      True{}
    case NExp{}:
      True{}
    case NMinus{}:
      False{}
    case NDot{}:
      False{}
    case NE{}:
      False{}
    case NESign{}:
      False{}

def JSON.nst.cont(st: JSON.NSt, +c: Char) -> Bool:
  match st:
    case NMinus{}:
      JSON.is_digit(c)
    case NZero{}:
      Bool.or(JSON.is_dot(c), JSON.is_e(c))
    case NInt{}:
      Bool.or(JSON.is_digit(c), Bool.or(JSON.is_dot(c), JSON.is_e(c)))
    case NDot{}:
      JSON.is_digit(c)
    case NFrac{}:
      Bool.or(JSON.is_digit(c), JSON.is_e(c))
    case NE{}:
      Bool.or(JSON.is_digit(c), Bool.or(JSON.is_minus(c), JSON.is_plus(c)))
    case NESign{}:
      JSON.is_digit(c)
    case NExp{}:
      JSON.is_digit(c)

def JSON.nst.after_minus(+c: Char, zero: Bool) -> JSON.NSt:
  match zero:
    case True{}:
      NZero{}
    case False{}:
      NInt{}

def JSON.nst.after_zero(+c: Char, dot: Bool) -> JSON.NSt:
  match dot:
    case True{}:
      NDot{}
    case False{}:
      NE{}

def JSON.nst.after_int(+c: Char, digit: Bool, dot: Bool) -> JSON.NSt:
  match digit:
    case True{}:
      NInt{}
    case False{}:
      match dot:
        case True{}:
          NDot{}
        case False{}:
          NE{}

def JSON.nst.after_frac(+c: Char, digit: Bool) -> JSON.NSt:
  match digit:
    case True{}:
      NFrac{}
    case False{}:
      NE{}

def JSON.nst.after_e(+c: Char, digit: Bool) -> JSON.NSt:
  match digit:
    case True{}:
      NExp{}
    case False{}:
      NESign{}

def JSON.nst.next(st: JSON.NSt, +c: Char) -> JSON.NSt:
  match st:
    case NMinus{}:
      JSON.nst.after_minus(c, JSON.is_zero(c))
    case NZero{}:
      JSON.nst.after_zero(c, JSON.is_dot(c))
    case NInt{}:
      JSON.nst.after_int(c, JSON.is_digit(c), JSON.is_dot(c))
    case NDot{}:
      NFrac{}
    case NFrac{}:
      JSON.nst.after_frac(c, JSON.is_digit(c))
    case NE{}:
      JSON.nst.after_e(c, JSON.is_digit(c))
    case NESign{}:
      NExp{}
    case NExp{}:
      NExp{}

def JSON.put.frame(+pos: U32, h: JSON.Frame, rest: List<&2, JSON.Frame>, v: JSON) -> JSON.Walk:
  match h:
    case FArr{rev}:
      Walk{MNeed{NAfter{}}, FArr{v <> rev} <> rest}
    case FKey{rev, key}:
      Walk{MNeed{NAfter{}}, FObj{Member{key, v} <> rev} <> rest}
    case FObj{rev}:
      JSON.fail(pos, "unexpected value")

def JSON.put(+pos: U32, stk: List<&2, JSON.Frame>, v: JSON) -> JSON.Walk:
  match stk:
    case Nil{}:
      Walk{MNeed{NEnd{v}}, []}
    case h <> rest:
      JSON.put.frame(pos, h, rest, v)

def JSON.close.arr.frame(+pos: U32, h: JSON.Frame, rest: List<&2, JSON.Frame>) -> JSON.Walk:
  match h:
    case FArr{rev}:
      JSON.put(pos, rest, Arr{List.reverse(&2, JSON, rev)})
    case FObj{rev}:
      JSON.fail(pos, "unexpected ]")
    case FKey{rev, key}:
      JSON.fail(pos, "unexpected ]")

def JSON.close.arr(+pos: U32, stk: List<&2, JSON.Frame>) -> JSON.Walk:
  match stk:
    case Nil{}:
      JSON.fail(pos, "unexpected ]")
    case h <> rest:
      JSON.close.arr.frame(pos, h, rest)

def JSON.close.obj.frame(+pos: U32, h: JSON.Frame, rest: List<&2, JSON.Frame>) -> JSON.Walk:
  match h:
    case FObj{rev}:
      JSON.put(pos, rest, Obj{List.reverse(&2, JSON, rev)})
    case FArr{rev}:
      JSON.fail(pos, "unexpected }")
    case FKey{rev, key}:
      JSON.fail(pos, "unexpected }")

def JSON.close.obj(+pos: U32, stk: List<&2, JSON.Frame>) -> JSON.Walk:
  match stk:
    case Nil{}:
      JSON.fail(pos, "unexpected }")
    case h <> rest:
      JSON.close.obj.frame(pos, h, rest)

def JSON.arr.empty.rev(+pos: U32, rev: List<&2, JSON>, rest: List<&2, JSON.Frame>) ->
  JSON.Walk:
  match rev:
    case Nil{}:
      JSON.put(pos, rest, Arr{[]})
    case h <> t:
      JSON.fail(pos, "trailing comma")

def JSON.arr.empty.frame(+pos: U32, h: JSON.Frame, rest: List<&2, JSON.Frame>) -> JSON.Walk:
  match h:
    case FArr{rev}:
      JSON.arr.empty.rev(pos, rev, rest)
    case FObj{rev}:
      JSON.fail(pos, "unexpected ]")
    case FKey{rev, key}:
      JSON.fail(pos, "unexpected ]")

def JSON.arr.empty(+pos: U32, stk: List<&2, JSON.Frame>) -> JSON.Walk:
  match stk:
    case Nil{}:
      JSON.fail(pos, "unexpected ]")
    case h <> rest:
      JSON.arr.empty.frame(pos, h, rest)

def JSON.obj.empty.rev(+pos: U32, rev: List<&2, JSON>, rest: List<&2, JSON.Frame>) ->
  JSON.Walk:
  match rev:
    case Nil{}:
      JSON.put(pos, rest, Obj{[]})
    case h <> t:
      JSON.fail(pos, "trailing comma")

def JSON.obj.empty.frame(+pos: U32, h: JSON.Frame, rest: List<&2, JSON.Frame>) -> JSON.Walk:
  match h:
    case FObj{rev}:
      JSON.obj.empty.rev(pos, rev, rest)
    case FArr{rev}:
      JSON.fail(pos, "unexpected }")
    case FKey{rev, key}:
      JSON.fail(pos, "unexpected }")

def JSON.obj.empty(+pos: U32, stk: List<&2, JSON.Frame>) -> JSON.Walk:
  match stk:
    case Nil{}:
      JSON.fail(pos, "unexpected }")
    case h <> rest:
      JSON.obj.empty.frame(pos, h, rest)

def JSON.after.comma.frame(+pos: U32, h: JSON.Frame, rest: List<&2, JSON.Frame>) -> JSON.Walk:
  match h:
    case FArr{rev}:
      Walk{MNeed{NVal{}}, FArr{rev} <> rest}
    case FObj{rev}:
      Walk{MNeed{NKey{}}, FObj{rev} <> rest}
    case FKey{rev, key}:
      JSON.fail(pos, "unexpected comma")

def JSON.after.comma(+pos: U32, stk: List<&2, JSON.Frame>) -> JSON.Walk:
  match stk:
    case Nil{}:
      JSON.fail(pos, "unexpected comma")
    case h <> rest:
      JSON.after.comma.frame(pos, h, rest)

def JSON.str.end_key.frame(+pos: U32, h: JSON.Frame, rest: List<&2, JSON.Frame>,
  key: String) -> JSON.Walk:
  match h:
    case FObj{rev}:
      Walk{MNeed{NColon{}}, FKey{rev, key} <> rest}
    case FArr{rev}:
      JSON.fail(pos, "bad key")
    case FKey{rev, k}:
      JSON.fail(pos, "bad key")

def JSON.str.end_key(+pos: U32, stk: List<&2, JSON.Frame>, key: String) -> JSON.Walk:
  match stk:
    case Nil{}:
      JSON.fail(pos, "bad key")
    case h <> rest:
      JSON.str.end_key.frame(pos, h, rest, key)

def JSON.str.end(+pos: U32, stk: List<&2, JSON.Frame>, text: String, as_key: Bool) ->
  JSON.Walk:
  match as_key:
    case True{}:
      JSON.str.end_key(pos, stk, text)
    case False{}:
      JSON.put(pos, stk, Str{text})

def JSON.esc.char(+c: Char, q: Bool, sl: Bool, sls: Bool, n: Bool, r: Bool, t: Bool,
  b: Bool, f: Bool, u: Bool) -> Maybe<&2, Char>:
  match q:
    case True{}:
      Some{Chr{34}}
    case False{}:
      match sl:
        case True{}:
          Some{Chr{92}}
        case False{}:
          match sls:
            case True{}:
              Some{Chr{47}}
            case False{}:
              match n:
                case True{}:
                  Some{Chr{10}}
                case False{}:
                  match r:
                    case True{}:
                      Some{Chr{13}}
                    case False{}:
                      match t:
                        case True{}:
                          Some{Chr{9}}
                        case False{}:
                          match b:
                            case True{}:
                              Some{Chr{8}}
                            case False{}:
                              match f:
                                case True{}:
                                  Some{Chr{12}}
                                case False{}:
                                  match u:
                                    case True{}:
                                      None{}
                                    case False{}:
                                      None{}

def JSON.esc.read(+c: Char) -> Maybe<&2, Char>:
  match c:
    case Chr{+code}:
      JSON.esc.char(c, U32.is_eq(code, 34), U32.is_eq(code, 92),
        U32.is_eq(code, 47), U32.is_eq(code, 110), U32.is_eq(code, 114),
        U32.is_eq(code, 116), U32.is_eq(code, 98), U32.is_eq(code, 102),
        U32.is_eq(code, 117))

def JSON.esc.is_u(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 117)

def JSON.is_high(+code: U32) -> Bool:
  Bool.and(U32.is_ge(code, 55296), U32.is_le(code, 56319))

def JSON.is_low(+code: U32) -> Bool:
  Bool.and(U32.is_ge(code, 56320), U32.is_le(code, 57343))

def JSON.is_scalar(+code: U32) -> Bool:
  Bool.and(U32.is_le(code, 1114111),
    Bool.not(Bool.and(U32.is_ge(code, 55296), U32.is_le(code, 57343))))

def JSON.hex.combine(+pos: U32, stk: List<&2, JSON.Frame>, rev: String,
  as_key: Bool, high: U32, low: U32, valid: Bool) -> JSON.Walk:
  match valid:
    case False{}:
      JSON.fail(pos, "unpaired high surrogate")
    case True{}:
      code = U32.add(65536, U32.add(U32.mul(U32.sub(high, 55296), 1024),
        U32.sub(low, 56320)))
      Walk{MStr{False{}, 0, 0, SCon{Chr{code}, rev}, as_key, 0}, stk}

def JSON.hex.first(+pos: U32, stk: List<&2, JSON.Frame>, rev: String,
  as_key: Bool, code: U32, low: Bool, high: Bool) -> JSON.Walk:
  match low:
    case True{}:
      JSON.fail(pos, "unpaired low surrogate")
    case False{}:
      match high:
        case True{}:
          Walk{MStr{False{}, 0, 0, rev, as_key, code}, stk}
        case False{}:
          Walk{MStr{False{}, 0, 0, SCon{Chr{code}, rev}, as_key, 0}, stk}

def JSON.hex.scalar.branch(+pos: U32, stk: List<&2, JSON.Frame>, rev: String,
  as_key: Bool, high: U32, +code: U32, zero: Bool) -> JSON.Walk:
  match zero:
    case True{}:
      JSON.hex.first(pos, stk, rev, as_key, code, JSON.is_low(code),
        JSON.is_high(code))
    case False{}:
      JSON.hex.combine(pos, stk, rev, as_key, high, code, JSON.is_low(code))

def JSON.hex.scalar(+pos: U32, stk: List<&2, JSON.Frame>, rev: String,
  as_key: Bool, +high: U32, code: U32) -> JSON.Walk:
  JSON.hex.scalar.branch(pos, stk, rev, as_key, high, code, U32.is_zero(high))

def JSON.hex.push(+pos: U32, stk: List<&2, JSON.Frame>, +esc: Bool,
  +hex: U32, +hexv: U32, rev: String, as_key: Bool, high: U32,
  d: U32, last: Bool) -> JSON.Walk:
  match last:
    case True{}:
      JSON.hex.scalar(pos, stk, rev, as_key, high, U32.add(U32.mul(hexv, 16), d))
    case False{}:
      Walk{MStr{False{}, U32.sub(hex, 1), U32.add(U32.mul(hexv, 16), d), rev,
        as_key, high}, stk}

def JSON.hex.got(+pos: U32, stk: List<&2, JSON.Frame>, esc: Bool,
  +hex: U32, +hexv: U32, rev: String, as_key: Bool, high: U32,
  mb: Maybe<&2, U32>) -> JSON.Walk:
  match mb:
    case None{}:
      JSON.fail(pos, "bad unicode escape")
    case Some{d}:
      JSON.hex.push(pos, stk, esc, hex, hexv, rev, as_key, high, d,
        U32.is_eq(hex, 1))

def JSON.str.esc.other(+pos: U32, stk: List<&2, JSON.Frame>, rev: String,
  as_key: Bool, high: U32, zero: Bool, mb: Maybe<&2, Char>) -> JSON.Walk:
  match zero:
    case False{}:
      JSON.fail(pos, "unpaired high surrogate")
    case True{}:
      match mb:
        case None{}:
          JSON.fail(pos, "bad escape")
        case Some{ch}:
          Walk{MStr{False{}, 0, 0, SCon{ch, rev}, as_key, 0}, stk}

def JSON.str.esc(+pos: U32, stk: List<&2, JSON.Frame>, rev: String,
  as_key: Bool, +high: U32, +c: Char, u: Bool,
  mb: Maybe<&2, Char>) -> JSON.Walk:
  match u:
    case True{}:
      Walk{MStr{False{}, 4, 0, rev, as_key, high}, stk}
    case False{}:
      JSON.str.esc.other(pos, stk, rev, as_key, high, U32.is_zero(high), mb)

def JSON.str.body.scalar(+pos: U32, stk: List<&2, JSON.Frame>, rev: String,
  as_key: Bool, c: Char, valid: Bool) -> JSON.Walk:
  match valid:
    case False{}:
      JSON.fail(pos, "invalid unicode scalar")
    case True{}:
      Walk{MStr{False{}, 0, 0, SCon{c, rev}, as_key, 0}, stk}

def JSON.str.body.normal(+pos: U32, stk: List<&2, JSON.Frame>, rev: String,
  as_key: Bool, +c: Char, quote: Bool, slash: Bool, ctl: Bool) -> JSON.Walk:
  match quote:
    case True{}:
      JSON.str.end(pos, stk, String.reverse(rev), as_key)
    case False{}:
      match slash:
        case True{}:
          Walk{MStr{True{}, 0, 0, rev, as_key, 0}, stk}
        case False{}:
          match ctl:
            case True{}:
              JSON.fail(pos, "unescaped control")
            case False{}:
              JSON.str.body.scalar(pos, stk, rev, as_key, c,
                JSON.is_scalar(Char.to_u32(c)))

def JSON.str.body.pending(+pos: U32, stk: List<&2, JSON.Frame>, rev: String,
  as_key: Bool, high: U32, zero: Bool, c: Char, quote: Bool, slash: Bool,
  ctl: Bool) -> JSON.Walk:
  match zero:
    case False{}:
      match slash:
        case True{}:
          Walk{MStr{True{}, 0, 0, rev, as_key, high}, stk}
        case False{}:
          JSON.fail(pos, "unpaired high surrogate")
    case True{}:
      JSON.str.body.normal(pos, stk, rev, as_key, c, quote, slash, ctl)

def JSON.str.body(+pos: U32, stk: List<&2, JSON.Frame>, rev: String,
  as_key: Bool, +high: U32, c: Char, quote: Bool, slash: Bool, ctl: Bool) ->
  JSON.Walk:
  JSON.str.body.pending(pos, stk, rev, as_key, high, U32.is_zero(high),
    c, quote, slash, ctl)

def JSON.step.str.hex(+pos: U32, stk: List<&2, JSON.Frame>,
  +hex: U32, +hexv: U32, rev: String, as_key: Bool, high: U32,
  +c: Char, in_hex: Bool) -> JSON.Walk:
  match in_hex:
    case True{}:
      JSON.hex.got(pos, stk, False{}, hex, hexv, rev, as_key, high,
        JSON.hex.val(c))
    case False{}:
      JSON.str.body(pos, stk, rev, as_key, high, c, JSON.is_quote(c),
        JSON.is_slash(c), JSON.is_ctl(c))

def JSON.step.str(+pos: U32, stk: List<&2, JSON.Frame>, esc: Bool,
  +hex: U32, +hexv: U32, rev: String, as_key: Bool, high: U32,
  +c: Char, in_hex: Bool) -> JSON.Walk:
  match esc:
    case True{}:
      JSON.str.esc(pos, stk, rev, as_key, high, c, JSON.esc.is_u(c),
        JSON.esc.read(c))
    case False{}:
      JSON.step.str.hex(pos, stk, hex, hexv, rev, as_key, high, c, in_hex)

def JSON.step.lit.last(+pos: U32, stk: List<&2, JSON.Frame>, rest: String, v: JSON,
  last: Bool) -> JSON.Walk:
  match last:
    case True{}:
      JSON.put(pos, stk, v)
    case False{}:
      Walk{MLit{rest, v}, stk}

def JSON.step.lit.ok(+pos: U32, stk: List<&2, JSON.Frame>, +rest: String, v: JSON,
  ok: Bool) -> JSON.Walk:
  match ok:
    case False{}:
      JSON.fail(pos, "bad literal")
    case True{}:
      JSON.step.lit.last(pos, stk, rest, v, String.is_empty(rest))

def JSON.step.lit(+pos: U32, stk: List<&2, JSON.Frame>, want: String, v: JSON, +c: Char) ->
  JSON.Walk:
  match want:
    case SNil{}:
      JSON.fail(pos, "bad literal")
    case SCon{h, rest}:
      JSON.step.lit.ok(pos, stk, rest, v, Char.is_eq(h, c))

def JSON.is_t(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 116)

def JSON.is_f(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 102)

def JSON.is_n(c: Char) -> Bool:
  match c:
    case Chr{+code}:
      U32.is_eq(code, 110)

def JSON.is_num.hd(+c: Char) -> Bool:
  Bool.or(JSON.is_minus(c), JSON.is_digit(c))

def JSON.val.start_num(+pos: U32, stk: List<&2, JSON.Frame>, +c: Char) -> JSON.Walk:
  Walk{MNum{SCon{c, SNil{}}, JSON.nst.start(JSON.is_minus(c), JSON.is_zero(c))}, stk}

def JSON.val.start_str(+pos: U32, stk: List<&2, JSON.Frame>, as_key: Bool) -> JSON.Walk:
  Walk{MStr{False{}, 0, 0, SNil{}, as_key, 0}, stk}

def JSON.val.lit(+pos: U32, stk: List<&2, JSON.Frame>, +c: Char, t: Bool, f: Bool,
  n: Bool) -> JSON.Walk:
  match t:
    case True{}:
      Walk{MLit{"rue", Boolean{True{}}}, stk}
    case False{}:
      match f:
        case True{}:
          Walk{MLit{"alse", Boolean{False{}}}, stk}
        case False{}:
          match n:
            case True{}:
              Walk{MLit{"ull", Null{}}, stk}
            case False{}:
              JSON.fail(pos, "unexpected char")

def JSON.val.open(+pos: U32, stk: List<&2, JSON.Frame>, +c: Char, arr: Bool, obj: Bool,
  quote: Bool, num: Bool) -> JSON.Walk:
  match arr:
    case True{}:
      Walk{MNeed{NVal{}}, FArr{[]} <> stk}
    case False{}:
      match obj:
        case True{}:
          Walk{MNeed{NKey{}}, FObj{[]} <> stk}
        case False{}:
          match quote:
            case True{}:
              JSON.val.start_str(pos, stk, False{})
            case False{}:
              match num:
                case True{}:
                  JSON.val.start_num(pos, stk, c)
                case False{}:
                  JSON.val.lit(pos, stk, c, JSON.is_t(c), JSON.is_f(c), JSON.is_n(c))

def JSON.step.val(+pos: U32, stk: List<&2, JSON.Frame>, +c: Char, ws: Bool, rbrk: Bool) ->
  JSON.Walk:
  match ws:
    case True{}:
      Walk{MNeed{NVal{}}, stk}
    case False{}:
      match rbrk:
        case True{}:
          JSON.arr.empty(pos, stk)
        case False{}:
          JSON.val.open(pos, stk, c, JSON.is_lbrk(c), JSON.is_lbra(c), JSON.is_quote(c),
            JSON.is_num.hd(c))

def JSON.step.key(+pos: U32, stk: List<&2, JSON.Frame>, +c: Char, ws: Bool, rbra: Bool,
  quote: Bool) -> JSON.Walk:
  match ws:
    case True{}:
      Walk{MNeed{NKey{}}, stk}
    case False{}:
      match rbra:
        case True{}:
          JSON.obj.empty(pos, stk)
        case False{}:
          match quote:
            case True{}:
              JSON.val.start_str(pos, stk, True{})
            case False{}:
              JSON.fail(pos, "expected key")

def JSON.step.colon(+pos: U32, stk: List<&2, JSON.Frame>, +c: Char, ws: Bool,
  col: Bool) -> JSON.Walk:
  match ws:
    case True{}:
      Walk{MNeed{NColon{}}, stk}
    case False{}:
      match col:
        case True{}:
          Walk{MNeed{NVal{}}, stk}
        case False{}:
          JSON.fail(pos, "expected colon")

def JSON.step.after(+pos: U32, stk: List<&2, JSON.Frame>, +c: Char, ws: Bool, comma: Bool,
  rbrk: Bool, rbra: Bool) -> JSON.Walk:
  match ws:
    case True{}:
      Walk{MNeed{NAfter{}}, stk}
    case False{}:
      match comma:
        case True{}:
          JSON.after.comma(pos, stk)
        case False{}:
          match rbrk:
            case True{}:
              JSON.close.arr(pos, stk)
            case False{}:
              match rbra:
                case True{}:
                  JSON.close.obj(pos, stk)
                case False{}:
                  JSON.fail(pos, "expected comma")

def JSON.step.end(+pos: U32, stk: List<&2, JSON.Frame>, v: JSON, +c: Char, ws: Bool) ->
  JSON.Walk:
  match ws:
    case True{}:
      Walk{MNeed{NEnd{v}}, stk}
    case False{}:
      JSON.fail(pos, "trailing junk")

def JSON.step.need(+pos: U32, stk: List<&2, JSON.Frame>, need: JSON.Need, +c: Char) -> JSON.Walk:
  match need:
    case NVal{}:
      JSON.step.val(pos, stk, c, JSON.is_ws(c), JSON.is_rbrk(c))
    case NKey{}:
      JSON.step.key(pos, stk, c, JSON.is_ws(c), JSON.is_rbra(c), JSON.is_quote(c))
    case NColon{}:
      JSON.step.colon(pos, stk, c, JSON.is_ws(c), JSON.is_colon(c))
    case NAfter{}:
      JSON.step.after(pos, stk, c, JSON.is_ws(c), JSON.is_comma(c), JSON.is_rbrk(c), JSON.is_rbra(c))
    case NEnd{v}:
      JSON.step.end(pos, stk, v, c, JSON.is_ws(c))

def JSON.step.num.end.mode(+pos: U32, stk: List<&2, JSON.Frame>, mode: JSON.Mode, c: Char) ->
  JSON.Walk:
  match mode:
    case MNeed{need}:
      JSON.step.need(pos, stk, need, c)
    case MFail{p, msg}:
      Walk{MFail{p, msg}, stk}
    case MDone{v}:
      Walk{MDone{v}, stk}
    case MStr{e0, hex, hexv, rev, as_key, hi}:
      JSON.fail(pos, "bad number")
    case MNum{rev, st}:
      JSON.fail(pos, "bad number")
    case MLit{want, v}:
      JSON.fail(pos, "bad number")

def JSON.step.num.end(+pos: U32, w: JSON.Walk, c: Char) -> JSON.Walk:
  match w:
    case Walk{mode, stk}:
      JSON.step.num.end.mode(pos, stk, mode, c)

def JSON.step.num.checked(+pos: U32, stk: List<&2, JSON.Frame>, rev: String, c: Char, ok: Bool) -> JSON.Walk:
  match ok:
    case True{}:
      JSON.step.num.end(pos, JSON.put(pos, stk, Num{String.reverse(rev)}), c)
    case False{}:
      JSON.fail(pos, "incomplete number")

def JSON.step.num(+pos: U32, stk: List<&2, JSON.Frame>, +rev: String, st: JSON.NSt, +c: Char,
  cont: Bool) -> JSON.Walk:
  match cont:
    case True{}:
      Walk{MNum{SCon{c, rev}, JSON.nst.next(st, c)}, stk}
    case False{}:
      JSON.step.num.checked(pos, stk, rev, c, JSON.nst.can_end(st))

def JSON.step.mode(+pos: U32, stk: List<&2, JSON.Frame>, mode: JSON.Mode, +c: Char) -> JSON.Walk:
  match mode:
    case MNeed{need}:
      JSON.step.need(pos, stk, need, c)
    case MStr{e0, +hex, hexv, rev, as_key, hi}:
      JSON.step.str(pos, stk, e0, hex, hexv, rev, as_key, hi, c, Bool.not(U32.is_zero(hex)))
    case MNum{rev, +st}:
      JSON.step.num(pos, stk, rev, st, c, JSON.nst.cont(st, c))
    case MLit{want, v}:
      JSON.step.lit(pos, stk, want, v, c)
    case MFail{p, msg}:
      Walk{MFail{p, msg}, stk}
    case MDone{v}:
      Walk{MDone{v}, stk}

def JSON.step(w: JSON.Walk, c: Char, pos: U32) -> JSON.Walk:
  match w:
    case Walk{mode, stk}:
      JSON.step.mode(pos, stk, mode, c)

def JSON.mode.stop(mode: JSON.Mode) -> Bool:
  match mode:
    case MFail{p, msg}:
      True{}
    case MDone{v}:
      True{}
    case MNeed{need}:
      False{}
    case MStr{e0, hex, hexv, rev, as_key, hi}:
      False{}
    case MNum{rev, st}:
      False{}
    case MLit{want, v}:
      False{}

def JSON.walk.stop(w: JSON.Walk) -> Bool:
  match w:
    case Walk{mode, stk}:
      JSON.mode.stop(mode)

def JSON.eof.need(+pos: U32, stk: List<&2, JSON.Frame>, need: JSON.Need) -> JSON.Mode:
  match need:
    case NEnd{v}:
      MDone{v}
    case NVal{}:
      MFail{pos, "unexpected end"}
    case NKey{}:
      MFail{pos, "unexpected end"}
    case NColon{}:
      MFail{pos, "unexpected end"}
    case NAfter{}:
      MFail{pos, "unexpected end"}

def JSON.eof.put(+pos: U32, w: JSON.Walk) -> JSON.Mode:
  match w:
    case Walk{mode, stk}:
      match mode:
        case MNeed{need}:
          JSON.eof.need(pos, stk, need)
        case MFail{p, msg}:
          MFail{p, msg}
        case MDone{v}:
          MDone{v}
        case MStr{e0, hex, hexv, rev, as_key, hi}:
          MFail{pos, "unterminated string"}
        case MNum{rev, st}:
          MFail{pos, "unexpected end"}
        case MLit{want, v}:
          MFail{pos, "unexpected end"}

def JSON.eof.num(+pos: U32, stk: List<&2, JSON.Frame>, rev: String, ok: Bool) -> JSON.Mode:
  match ok:
    case True{}:
      JSON.eof.put(pos, JSON.put(pos, stk, Num{String.reverse(rev)}))
    case False{}:
      MFail{pos, "bad number"}

def JSON.parse.eof(+pos: U32, w: JSON.Walk) -> JSON.Mode:
  match w:
    case Walk{mode, stk}:
      match mode:
        case MNum{rev, st}:
          JSON.eof.num(pos, stk, rev, JSON.nst.can_end(st))
        case MNeed{need}:
          JSON.eof.need(pos, stk, need)
        case MStr{e0, hex, hexv, rev, as_key, hi}:
          MFail{pos, "unterminated string"}
        case MLit{want, v}:
          MFail{pos, "unexpected end"}
        case MFail{p, msg}:
          MFail{p, msg}
        case MDone{v}:
          MDone{v}

def JSON.parse.go(s: String, +pos: U32, w: JSON.Walk, halt: Bool) -> JSON.Mode:
  match s:
    case SNil{}:
      JSON.parse.eof(pos, w)
    case SCon{h, rest}:
      match halt:
        case True{}:
          JSON.parse.eof(pos, w)
        case False{}:
          +n = JSON.step(w, h, pos)
          JSON.parse.go(rest, U32.inc(pos), n, JSON.walk.stop(n))

def JSON.parse.fin(mode: JSON.Mode) -> Result<&1, &1, U32 & String, JSON>:
  match mode:
    case MDone{v}:
      Done{v}
    case MFail{p, msg}:
      Fail{(p, msg)}
    case MNeed{need}:
      Fail{(0, "unexpected end")}
    case MStr{e0, hex, hexv, rev, as_key, hi}:
      Fail{(0, "unterminated string")}
    case MNum{rev, st}:
      Fail{(0, "bad number")}
    case MLit{want, v}:
      Fail{(0, "unexpected end")}

def JSON.read(s: String) -> Result<&1, &1, U32 & String, JSON>:
  JSON.parse.fin(JSON.parse.go(s, 0, Walk{MNeed{NVal{}}, []}, False{}))

# Each job expansion is nonrecursive; only the fuel-first driver repeats.
type JSON.Encoding is Data:
  Encoding{jobs: List<&2, JSON.Job>, acc: List<&2, String>}

def JSON.encode.number(parsed: Result<&1, &1, U32 & String, JSON>,
  rest: List<&2, JSON.Job>, lex: String, acc: List<&2, String>) ->
  Result<&1, &1, U32 & String, JSON.Encoding>:
  match parsed:
    case Fail{error}:
      Fail{(22, "invalid number lexeme")}
    case Done{value}:
      match value:
        case Num{n}:
          Done{Encoding{rest, lex <> acc}}
        case Null{}:
          Fail{(22, "invalid number lexeme")}
        case Boolean{ok}:
          Fail{(22, "invalid number lexeme")}
        case Str{text}:
          Fail{(22, "invalid number lexeme")}
        case Arr{items}:
          Fail{(22, "invalid number lexeme")}
        case Obj{fields}:
          Fail{(22, "invalid number lexeme")}
        case Member{name, val}:
          Fail{(22, "invalid number lexeme")}

def JSON.encode.step(jobs: List<&2, JSON.Job>, acc: List<&2, String>) -> Result<&1, &1, U32 & String, JSON.Encoding>:
  match jobs:
    case Nil{}:
      Done{Encoding{Nil{}, acc}}
    case h <> rest:
      match h:
        case JLit{s}:
          Done{Encoding{rest, s <> acc}}
        case JVal{v}:
          match v:
            case Null{}:
              Done{Encoding{rest, "null" <> acc}}
            case Boolean{ok}:
              Done{Encoding{rest, Bool.pick(String, ok, "true", "false") <> acc}}
            case Num{+lex}:
              JSON.encode.number(JSON.read(lex), rest, lex, acc)
            case Str{text}:
              Done{Encoding{rest, JSON.esc(text) <> acc}}
            case Arr{xs}:
              Done{Encoding{JArr0{xs} <> JLit{"]"} <> rest, "[" <> acc}}
            case Obj{fields}:
              Done{Encoding{JObj0{fields} <> JLit{"}"} <> rest, "{" <> acc}}
            case Member{name, val}:
              Fail{(22, "member outside an object")}
        case JArr0{xs}:
          match xs:
            case Nil{}:
              Done{Encoding{rest, acc}}
            case x <> xt:
              Done{Encoding{JVal{x} <> JArr1{xt} <> rest, acc}}
        case JArr1{xs}:
          match xs:
            case Nil{}:
              Done{Encoding{rest, acc}}
            case x <> xt:
              Done{Encoding{JVal{x} <> JArr1{xt} <> rest, "," <> acc}}
        case JObj0{fs}:
          match fs:
            case Nil{}:
              Done{Encoding{rest, acc}}
            case m <> ft:
              match m:
                case Member{name, val}:
                  Done{Encoding{JLit{JSON.esc(name) ++ ":"} <> JVal{val} <> JObj1{ft} <> rest, acc}}
                case Null{}:
                  Fail{(22, "object field is not a member")}
                case Boolean{ok}:
                  Fail{(22, "object field is not a member")}
                case Num{lex}:
                  Fail{(22, "object field is not a member")}
                case Str{text}:
                  Fail{(22, "object field is not a member")}
                case Arr{xs}:
                  Fail{(22, "object field is not a member")}
                case Obj{fields}:
                  Fail{(22, "object field is not a member")}
        case JObj1{fs}:
          match fs:
            case Nil{}:
              Done{Encoding{rest, acc}}
            case m <> ft:
              match m:
                case Member{name, val}:
                  Done{Encoding{JLit{JSON.esc(name) ++ ":"} <> JVal{val} <> JObj1{ft} <> rest, "," <> acc}}
                case Null{}:
                  Fail{(22, "object field is not a member")}
                case Boolean{ok}:
                  Fail{(22, "object field is not a member")}
                case Num{lex}:
                  Fail{(22, "object field is not a member")}
                case Str{text}:
                  Fail{(22, "object field is not a member")}
                case Arr{xs}:
                  Fail{(22, "object field is not a member")}
                case Obj{fields}:
                  Fail{(22, "object field is not a member")}

def JSON.encoding.jobs(state: JSON.Encoding) -> List<&2, JSON.Job>:
  match state:
    case Encoding{jobs, acc}:
      jobs

def JSON.encoding.acc(state: JSON.Encoding) -> List<&2, String>:
  match state:
    case Encoding{jobs, acc}:
      acc

def JSON.encode.go(fuel: Nat, jobs: List<&2, JSON.Job>, acc: List<&2, String>) -> Result<&1, &1, U32 & String, String>:
  match fuel jobs:
    case _ Nil{}:
      Done{String.concat(List.reverse(&2, String, acc))}
    case 0n _:
      Fail{(22, "JSON encoding work limit")}
    case 1n+rest pending:
      do Result<&1, &1, U32 & String, String>:
        +next : JSON.Encoding <- JSON.encode.step(pending, acc)
        JSON.encode.go(rest, JSON.encoding.jobs(next), JSON.encoding.acc(next))

def JSON.write_with_fuel(fuel: Nat, v: JSON) -> Result<&1, &1, U32 & String, String>:
  JSON.encode.go(fuel, [JVal{v}], Nil{})

def JSON.write(v: JSON) -> Result<&1, &1, U32 & String, String>:
  JSON.write_with_fuel(131072n, v)
