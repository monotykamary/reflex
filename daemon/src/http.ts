// Pure HTTP/1.1: parse one request as read off the socket, and build one
// response. Every response closes its connection.

import {drop, isEmpty, lines, toLower, trim, trimEnd} from './str.ts'

export type Header = {name: string; value: string}
export type Req = {method: string; path: string; query: Header[]; headers: Header[]; body: string}

// Split at the first `sep`: (before, after); after is "" when absent.
function cut(s: string, sep: string): [string, string] {
  const i = s.indexOf(sep)
  return i < 0 ? [s, ''] : [s.slice(0, i), s.slice(i + sep.length)]
}

function hexVal(c: number): number {
  if (c >= 48 && c <= 57) return c - 48
  if (c >= 97 && c <= 102) return c - 87
  if (c >= 65 && c <= 70) return c - 55
  return 0
}

const scalar = (code: number) => (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff) ? '�' : String.fromCodePoint(code))

// Decode %XX escapes (UTF-8) and '+' in a query component.
export function urlDecode(s: string): string {
  const cs = Array.from(s)
  let need = 0
  let code = 0
  let out = ''
  const byte = (b: number) => {
    if (b < 128) {
      out += String.fromCharCode(b)
      need = 0
      code = 0
    } else if (need === 0) {
      if (b < 224) {
        need = 1
        code = b & 31
      } else if (b < 240) {
        need = 2
        code = b & 15
      } else {
        need = 3
        code = b & 7
      }
    } else {
      code = code * 64 + (b & 63)
      need -= 1
      if (need === 0) {
        out += scalar(code)
        code = 0
      }
    }
  }
  for (let i = 0; i < cs.length; ) {
    const c = cs[i]!
    if (c === '%' && i + 2 < cs.length + 0 && cs.length - i >= 3) {
      byte(hexVal(cs[i + 1]!.codePointAt(0)!) * 16 + hexVal(cs[i + 2]!.codePointAt(0)!))
      i += 3
    } else if (c === '+') {
      byte(32)
      i += 1
    } else {
      out += c
      need = 0
      code = 0
      i += 1
    }
  }
  return out
}

const queryOf = (q: string): Header[] =>
  q.split('&').map((p) => {
    const [k, v] = cut(p, '=')
    return {name: urlDecode(k), value: urlDecode(v)}
  })

function headerOf(line: string): Header {
  const [k, v] = cut(line, ':')
  return {name: toLower(trim(k)), value: trim(v)}
}

export function parse(raw: string): Req {
  const at = raw.indexOf('\r\n\r\n')
  const head = at < 0 ? raw : raw.slice(0, at)
  const body = at < 0 ? '' : raw.slice(at + 4)
  const ls = lines(head)
  const [method, rest] = cut(trimEnd(ls[0]!), ' ')
  const [path, q] = cut(trim(cut(rest, ' ')[0]), '?')
  const headers = ls
    .slice(1)
    .filter((h) => !isEmpty(trim(h)))
    .map((l) => headerOf(trimEnd(l)))
  return {method, path, query: queryOf(q), headers, body}
}

const lookup = (hs: Header[], name: string): string => hs.find((h) => h.name === name)?.value ?? ''

export const query = (r: Req, name: string): string => lookup(r.query, name)
export const header = (r: Req, name: string): string => lookup(r.headers, name)

const bearer = (v: string) => (toLower(v).startsWith('bearer ') ? trim(drop(v, 7)) : '')

// The token a request presents: Authorization: Bearer, X-Reflex-Token, or ?t=
export const token = (r: Req): string => [bearer(header(r, 'authorization')), header(r, 'x-reflex-token'), query(r, 't')].find((x) => !isEmpty(x)) ?? ''

// Responses
// ---------

function reason(code: number): string {
  if (code === 200) return 'OK'
  if (code === 401) return 'Unauthorized'
  if (code === 404) return 'Not Found'
  if (code === 400) return 'Bad Request'
  return 'Error'
}

export const responseWith = (code: number, ctype: string, cache: string, body: string): string =>
  'HTTP/1.1 ' +
  String(code) +
  ' ' +
  reason(code) +
  '\r\nContent-Type: ' +
  ctype +
  '\r\nContent-Length: ' +
  String(Buffer.byteLength(body, 'utf8')) +
  '\r\nCache-Control: ' +
  cache +
  '\r\nConnection: close\r\n\r\n' +
  body

export const response = (code: number, ctype: string, body: string): string => responseWith(code, ctype, 'no-store', body)

export const json = (code: number, body: string): string => response(code, 'application/json; charset=utf-8', body)

export function contentType(path: string): string {
  if (path.endsWith('.html')) return 'text/html; charset=utf-8'
  if (path.endsWith('.js')) return 'text/javascript; charset=utf-8'
  if (path.endsWith('.css')) return 'text/css; charset=utf-8'
  if (path.endsWith('.svg')) return 'image/svg+xml'
  if (path.endsWith('.json')) return 'application/json; charset=utf-8'
  return 'text/plain; charset=utf-8'
}
