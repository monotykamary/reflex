// JSON: a strict reader that keeps what reflexd reads (a number's own text,
// every member in order, the first of two same-named members), helpers to
// read fields out of it, and builders for JSON text.

import {readU32, showU32} from './str.ts'

export type J =
  | {t: 'null'}
  | {t: 'bool'; v: boolean}
  | {t: 'num'; lex: string}
  | {t: 'str'; v: string}
  | {t: 'arr'; items: J[]}
  | {t: 'obj'; fields: [string, J][]}

export type Res<T> = {ok: true; v: T} | {ok: false; code: number; msg: string}
export const done = <T>(v: T): Res<T> => ({ok: true, v})
export const fail = <T = never>(code: number, msg: string): Res<T> => ({ok: false, code, msg})

export const NULL: J = {t: 'null'}
export const EMPTY_OBJ: J = {t: 'obj', fields: []}

// Reading
// -------
// One character at a time, as the strict-json reader reflexd always used:
// the same values, the same refusals, in the same words.

type Frame = {k: 'arr'; items: J[]} | {k: 'obj'; fields: [string, J][]} | {k: 'key'; fields: [string, J][]; key: string}
type NSt = 'minus' | 'zero' | 'int' | 'dot' | 'frac' | 'e' | 'esign' | 'exp'

const isWs = (c: number) => c === 32 || c === 9 || c === 10 || c === 13
const isDigit = (c: number) => c >= 48 && c <= 57
const isE = (c: number) => c === 101 || c === 69

function canEnd(st: NSt): boolean {
  return st === 'zero' || st === 'int' || st === 'frac' || st === 'exp'
}

function cont(st: NSt, c: number): boolean {
  switch (st) {
    case 'minus':
    case 'dot':
    case 'esign':
    case 'exp':
      return isDigit(c)
    case 'zero':
      return c === 46 || isE(c)
    case 'int':
      return isDigit(c) || c === 46 || isE(c)
    case 'frac':
      return isDigit(c) || isE(c)
    case 'e':
      return isDigit(c) || c === 45 || c === 43
  }
}

function next(st: NSt, c: number): NSt {
  switch (st) {
    case 'minus':
      return c === 48 ? 'zero' : 'int'
    case 'zero':
      return c === 46 ? 'dot' : 'e'
    case 'int':
      return isDigit(c) ? 'int' : c === 46 ? 'dot' : 'e'
    case 'dot':
      return 'frac'
    case 'frac':
      return isDigit(c) ? 'frac' : 'e'
    case 'e':
      return isDigit(c) ? 'exp' : 'esign'
    case 'esign':
    case 'exp':
      return 'exp'
  }
}

function hexVal(c: number): number | null {
  if (c >= 97 && c <= 102) return c - 87
  if (c >= 65 && c <= 70) return c - 55
  if (c >= 48 && c <= 57) return c - 48
  return null
}

const isHigh = (c: number) => c >= 0xd800 && c <= 0xdbff
const isLow = (c: number) => c >= 0xdc00 && c <= 0xdfff

class Bad {
  constructor(
    readonly pos: number,
    readonly msg: string,
  ) {}
}

export function read(s: string): Res<J> {
  type Need = 'val' | 'key' | 'colon' | 'after' | 'end'
  let mode = 'need' as 'need' | 'str' | 'num' | 'lit'
  let need = 'val' as Need
  let done_: J | undefined
  const stk: Frame[] = []
  // a string
  let esc = false
  let hex = 0
  let hexv = 0
  let buf: string[] = []
  let asKey = false
  let high = 0
  // a number
  let lex = ''
  let st: NSt = 'int'
  // a literal
  let want = ''
  let lit: J = NULL
  let pos = 0

  const put = (v: J) => {
    const h = stk[stk.length - 1]
    if (!h) {
      mode = 'need'
      need = 'end'
      done_ = v
      return
    }
    if (h.k === 'arr') h.items.push(v)
    else if (h.k === 'key') {
      h.fields.push([h.key, v])
      stk[stk.length - 1] = {k: 'obj', fields: h.fields}
    } else throw new Bad(pos, 'unexpected value')
    mode = 'need'
    need = 'after'
  }
  const top = () => stk[stk.length - 1]
  const stepNeed = (c: number, ch: string) => {
    switch (need) {
      case 'val':
        if (isWs(c)) return
        if (c === 93) {
          const h = top()
          if (!h || h.k !== 'arr') throw new Bad(pos, 'unexpected ]')
          if (h.items.length > 0) throw new Bad(pos, 'trailing comma')
          stk.pop()
          return put({t: 'arr', items: []})
        }
        if (c === 91) {
          stk.push({k: 'arr', items: []})
          need = 'val'
          return
        }
        if (c === 123) {
          stk.push({k: 'obj', fields: []})
          need = 'key'
          return
        }
        if (c === 34) {
          mode = 'str'
          esc = false
          hex = 0
          hexv = 0
          buf = []
          asKey = false
          high = 0
          return
        }
        if (c === 45 || isDigit(c)) {
          mode = 'num'
          lex = ch
          st = c === 45 ? 'minus' : c === 48 ? 'zero' : 'int'
          return
        }
        if (c === 116) {
          mode = 'lit'
          want = 'rue'
          lit = {t: 'bool', v: true}
          return
        }
        if (c === 102) {
          mode = 'lit'
          want = 'alse'
          lit = {t: 'bool', v: false}
          return
        }
        if (c === 110) {
          mode = 'lit'
          want = 'ull'
          lit = NULL
          return
        }
        throw new Bad(pos, 'unexpected char')
      case 'key':
        if (isWs(c)) return
        if (c === 125) {
          const h = top()
          if (!h || h.k !== 'obj') throw new Bad(pos, 'unexpected }')
          if (h.fields.length > 0) throw new Bad(pos, 'trailing comma')
          stk.pop()
          return put({t: 'obj', fields: []})
        }
        if (c === 34) {
          mode = 'str'
          esc = false
          hex = 0
          hexv = 0
          buf = []
          asKey = true
          high = 0
          return
        }
        throw new Bad(pos, 'expected key')
      case 'colon':
        if (isWs(c)) return
        if (c === 58) {
          need = 'val'
          return
        }
        throw new Bad(pos, 'expected colon')
      case 'after': {
        if (isWs(c)) return
        const h = top()
        if (c === 44) {
          if (!h || h.k === 'key') throw new Bad(pos, 'unexpected comma')
          need = h.k === 'arr' ? 'val' : 'key'
          return
        }
        if (c === 93) {
          if (!h || h.k !== 'arr') throw new Bad(pos, 'unexpected ]')
          stk.pop()
          return put({t: 'arr', items: h.items})
        }
        if (c === 125) {
          if (!h || h.k !== 'obj') throw new Bad(pos, 'unexpected }')
          stk.pop()
          return put({t: 'obj', fields: h.fields})
        }
        throw new Bad(pos, 'expected comma')
      }
      case 'end':
        if (isWs(c)) return
        throw new Bad(pos, 'trailing junk')
    }
  }
  const endString = () => {
    const text = buf.join('')
    if (!asKey) return put({t: 'str', v: text})
    const h = top()
    if (!h || h.k !== 'obj') throw new Bad(pos, 'bad key')
    stk[stk.length - 1] = {k: 'key', fields: h.fields, key: text}
    mode = 'need'
    need = 'colon'
  }
  const stepStr = (c: number, ch: string) => {
    if (esc) {
      esc = false
      if (c === 117) {
        hex = 4
        hexv = 0
        return
      }
      if (high !== 0) throw new Bad(pos, 'unpaired high surrogate')
      const m: Record<number, string> = {34: '"', 92: '\\', 47: '/', 110: '\n', 114: '\r', 116: '\t', 98: '\b', 102: '\f'}
      const got = m[c]
      if (got === undefined) throw new Bad(pos, 'bad escape')
      buf.push(got)
      return
    }
    if (hex !== 0) {
      const d = hexVal(c)
      if (d === null) throw new Bad(pos, 'bad unicode escape')
      const v = hexv * 16 + d
      if (hex > 1) {
        hex -= 1
        hexv = v
        return
      }
      hex = 0
      hexv = 0
      if (high === 0) {
        if (isLow(v)) throw new Bad(pos, 'unpaired low surrogate')
        if (isHigh(v)) high = v
        else buf.push(String.fromCharCode(v))
        return
      }
      if (!isLow(v)) throw new Bad(pos, 'unpaired high surrogate')
      buf.push(String.fromCharCode(high, v))
      high = 0
      return
    }
    if (high !== 0) {
      if (c === 92) {
        esc = true
        return
      }
      throw new Bad(pos, 'unpaired high surrogate')
    }
    if (c === 34) return endString()
    if (c === 92) {
      esc = true
      return
    }
    if (c < 32) throw new Bad(pos, 'unescaped control')
    if (c >= 0xd800 && c <= 0xdfff) throw new Bad(pos, 'invalid unicode scalar')
    buf.push(ch)
  }
  const step = (ch: string) => {
    const c = ch.codePointAt(0)!
    switch (mode) {
      case 'need':
        return stepNeed(c, ch)
      case 'str':
        return stepStr(c, ch)
      case 'num':
        if (cont(st, c)) {
          lex += ch
          st = next(st, c)
          return
        }
        if (!canEnd(st)) throw new Bad(pos, 'incomplete number')
        put({t: 'num', lex})
        return stepNeed(c, ch)
      case 'lit':
        if (want.length === 0 || want[0] !== ch) throw new Bad(pos, 'bad literal')
        want = want.slice(1)
        if (want.length === 0) put(lit)
        return
    }
  }
  try {
    for (const ch of s) {
      step(ch)
      pos++
    }
    switch (mode) {
      case 'num':
        if (!canEnd(st)) return fail(pos, 'bad number')
        put({t: 'num', lex})
        break
      case 'str':
        return fail(pos, 'unterminated string')
      case 'lit':
        return fail(pos, 'unexpected end')
    }
    if (mode === 'need' && need === 'end' && done_ !== undefined) return done(done_)
    return fail(pos, 'unexpected end')
  } catch (e) {
    if (e instanceof Bad) return fail(e.pos, e.msg)
    return fail(pos, String(e))
  }
}

export function get(v: J, key: string): J | undefined {
  if (v.t !== 'obj') return undefined
  for (const [k, x] of v.fields) if (k === key) return x
  return undefined
}

// A string's text, a number's own text, "true"/"false"; anything else "".
export function textOf(x: J | undefined): string {
  if (!x) return ''
  switch (x.t) {
    case 'str':
      return x.v
    case 'num':
      return x.lex
    case 'bool':
      return x.v ? 'true' : 'false'
    default:
      return ''
  }
}

export const textAt = (v: J, key: string): string => textOf(get(v, key))

export function asU32(x: J | undefined, fallback: number): number {
  if (!x) return fallback
  if (x.t === 'num') return readU32(x.lex) ?? fallback
  if (x.t === 'str') return readU32(x.v) ?? fallback
  return fallback
}

export const asBool = (x: J | undefined): boolean => x?.t === 'bool' && x.v

export const asList = (x: J | undefined): J[] => (x?.t === 'arr' ? x.items : [])

export function path(keys: string[], v: J | undefined): J | undefined {
  let m = v
  for (const k of keys) {
    if (m === undefined) return undefined
    m = get(m, k)
  }
  return m
}

// Building
// --------

export function str(s: string): string {
  let out = '"'
  let from = 0
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c >= 32 && c !== 34 && c !== 92) continue
    out += s.slice(from, i)
    from = i + 1
    if (c === 34) out += '\\"'
    else if (c === 92) out += '\\\\'
    else if (c === 10) out += '\\n'
    else if (c === 13) out += '\\r'
    else if (c === 9) out += '\\t'
    else if (c === 8) out += '\\b'
    else if (c === 12) out += '\\f'
    else out += '\\u00' + c.toString(16).padStart(2, '0')
  }
  return out + s.slice(from) + '"'
}

export const num = (n: number): string => showU32(n)
export const nat = (n: number): string => String(n)
export const bool = (b: boolean): string => (b ? 'true' : 'false')
export const kv = (k: string, v: string): string => '"' + k + '":' + v
export const obj = (parts: string[]): string => '{' + parts.join(',') + '}'
export const arr = (parts: string[]): string => '[' + parts.join(',') + ']'
export const strs = (xs: string[]): string => arr(xs.map(str))
