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

class Bad extends Error {
  constructor(
    readonly pos: number,
    msg: string,
  ) {
    super(msg)
  }
}

const isWs = (c: number) => c === 32 || c === 9 || c === 10 || c === 13
const isDigit = (c: number) => c >= 48 && c <= 57

export function read(s: string): Res<J> {
  let i = 0
  const n = s.length
  const ws = () => {
    while (i < n && isWs(s.charCodeAt(i))) i++
  }
  const value = (depth: number): J => {
    if (depth > 10000) throw new Bad(i, 'too deep')
    ws()
    if (i >= n) throw new Bad(0, 'unexpected end')
    const c = s.charCodeAt(i)
    if (c === 123) {
      i++
      const fields: [string, J][] = []
      ws()
      if (s.charCodeAt(i) === 125) {
        i++
        return {t: 'obj', fields}
      }
      for (;;) {
        ws()
        if (i >= n) throw new Bad(0, 'unexpected end')
        if (s.charCodeAt(i) !== 34) throw new Bad(i, 'expected a key')
        const k = string()
        ws()
        if (i >= n) throw new Bad(0, 'unexpected end')
        if (s.charCodeAt(i) !== 58) throw new Bad(i, 'expected a colon')
        i++
        fields.push([k, value(depth + 1)])
        ws()
        if (i >= n) throw new Bad(0, 'unexpected end')
        const d = s.charCodeAt(i++)
        if (d === 44) continue
        if (d === 125) return {t: 'obj', fields}
        throw new Bad(i - 1, 'unexpected character')
      }
    }
    if (c === 91) {
      i++
      const items: J[] = []
      ws()
      if (s.charCodeAt(i) === 93) {
        i++
        return {t: 'arr', items}
      }
      for (;;) {
        items.push(value(depth + 1))
        ws()
        if (i >= n) throw new Bad(0, 'unexpected end')
        const d = s.charCodeAt(i++)
        if (d === 44) continue
        if (d === 93) return {t: 'arr', items}
        throw new Bad(i - 1, 'unexpected character')
      }
    }
    if (c === 34) return {t: 'str', v: string()}
    if (c === 45 || isDigit(c)) return number()
    for (const [word, v] of [
      ['true', {t: 'bool', v: true}],
      ['false', {t: 'bool', v: false}],
      ['null', NULL],
    ] as const) {
      if (s.startsWith(word, i)) {
        i += word.length
        return v
      }
    }
    throw new Bad(i, 'unexpected character')
  }
  const number = (): J => {
    const start = i
    if (s.charCodeAt(i) === 45) i++
    if (s.charCodeAt(i) === 48) i++
    else if (isDigit(s.charCodeAt(i))) while (isDigit(s.charCodeAt(i))) i++
    else throw new Bad(i, 'bad number')
    if (s.charCodeAt(i) === 46) {
      i++
      if (!isDigit(s.charCodeAt(i))) throw new Bad(i, 'bad number')
      while (isDigit(s.charCodeAt(i))) i++
    }
    if (s.charCodeAt(i) === 101 || s.charCodeAt(i) === 69) {
      i++
      if (s.charCodeAt(i) === 43 || s.charCodeAt(i) === 45) i++
      if (!isDigit(s.charCodeAt(i))) throw new Bad(i, 'bad number')
      while (isDigit(s.charCodeAt(i))) i++
    }
    return {t: 'num', lex: s.slice(start, i)}
  }
  const hex4 = (): number => {
    if (i + 4 > n) throw new Bad(0, 'unterminated string')
    const h = s.slice(i, i + 4)
    if (!/^[0-9a-fA-F]{4}$/.test(h)) throw new Bad(i, 'bad escape')
    i += 4
    return parseInt(h, 16)
  }
  const string = (): string => {
    i++
    let out = ''
    for (;;) {
      if (i >= n) throw new Bad(0, 'unterminated string')
      const c = s.charCodeAt(i)
      if (c === 34) {
        i++
        return out
      }
      if (c < 32) throw new Bad(i, 'control character in string')
      if (c !== 92) {
        let j = i
        while (j < n) {
          const d = s.charCodeAt(j)
          if (d === 34 || d === 92 || d < 32) break
          j++
        }
        out += s.slice(i, j)
        i = j
        continue
      }
      i++
      if (i >= n) throw new Bad(0, 'unterminated string')
      const e = s[i++]
      switch (e) {
        case '"':
          out += '"'
          break
        case '\\':
          out += '\\'
          break
        case '/':
          out += '/'
          break
        case 'b':
          out += '\b'
          break
        case 'f':
          out += '\f'
          break
        case 'n':
          out += '\n'
          break
        case 'r':
          out += '\r'
          break
        case 't':
          out += '\t'
          break
        case 'u': {
          const a = hex4()
          if (a >= 0xd800 && a <= 0xdbff) {
            if (s.charCodeAt(i) !== 92 || s[i + 1] !== 'u') throw new Bad(i, 'lone surrogate')
            i += 2
            const b = hex4()
            if (b < 0xdc00 || b > 0xdfff) throw new Bad(i, 'lone surrogate')
            out += String.fromCharCode(a, b)
          } else if (a >= 0xdc00 && a <= 0xdfff) throw new Bad(i, 'lone surrogate')
          else out += String.fromCharCode(a)
          break
        }
        default:
          throw new Bad(i - 1, 'bad escape')
      }
    }
  }
  try {
    const v = value(0)
    ws()
    if (i < n) return fail(i, 'unexpected character')
    return done(v)
  } catch (e) {
    if (e instanceof Bad) return fail(e.pos, e.message)
    return fail(0, String(e))
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
