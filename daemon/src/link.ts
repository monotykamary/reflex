// The app's socket (REFLEX_LINK_SOCKET, else <data>/link.sock): what only the
// app has, for reflexd. herdr-core streams a terminal to whoever attaches; the
// app attaches for the phone and keeps its screen, so the phone's colored
// screens, its typing and its size for a herdr-core agent come through here.
// One JSON line asked, one answered, per connection (see the app's PhoneLink).

import {unixCall} from './host.ts'
import * as Js from './js.ts'
import type {J, Res} from './js.ts'

const request = (method: string, params: string) => Js.obj([Js.kv('method', Js.str(method)), Js.kv('params', params)]) + '\n'

async function call(sock: string, method: string, params: string, timeoutMs: number): Promise<Res<J>> {
  const r = await unixCall(sock, request(method, params), 8388608, timeoutMs)
  return r.ok ? Js.read(r.v) : r
}

// The terminal's screen with its colors, as the app's viewer has it.
export async function screen(sock: string, pane: string): Promise<Res<string>> {
  const r = await call(sock, 'screen', Js.obj([Js.kv('terminal', Js.str(pane))]), 8000)
  if (!r.ok) return r
  return Js.asBool(Js.get(r.v, 'ok')) ? Js.done(Js.textAt(r.v, 'text')) : Js.fail(1, Js.textAt(r.v, 'error'))
}

// Literal keys, no Enter (the phone's keyboard, typed live).
export async function typed(sock: string, pane: string, text: string): Promise<Res<J>> {
  const r = await call(sock, 'type', Js.obj([Js.kv('terminal', Js.str(pane)), Js.kv('text', Js.str(text))]), 8000)
  if (!r.ok) return r
  return Js.asBool(Js.get(r.v, 'ok')) ? r : Js.fail(1, Js.textAt(r.v, 'error'))
}

// The phone's size (and a scroll): {"ok", "held", "error"} as the phone reads it.
export async function control(sock: string, pane: string, cols: number, rows: number, take: boolean, scroll: string, n: number): Promise<string> {
  const scrolls = scroll === 'up' || scroll === 'down' ? [Js.kv('scroll', Js.str(scroll)), Js.kv('n', Js.num(n))] : []
  const r = await call(
    sock,
    'control',
    Js.obj([Js.kv('terminal', Js.str(pane)), Js.kv('cols', Js.num(cols)), Js.kv('rows', Js.num(rows)), Js.kv('take', Js.bool(take)), ...scrolls]),
    8000,
  )
  if (!r.ok) return Js.obj([Js.kv('ok', 'false'), Js.kv('error', Js.str(r.msg))])
  return Js.obj([
    Js.kv('ok', Js.bool(Js.asBool(Js.get(r.v, 'ok')))),
    Js.kv('held', Js.bool(Js.asBool(Js.get(r.v, 'held')))),
    Js.kv('error', Js.str(Js.textAt(r.v, 'error'))),
  ])
}
