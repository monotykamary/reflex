// Herdr socket client. Requests are built and responses read by pure code;
// `call` is the only effect: one JSONL request per Unix-socket connection.

import {unixCall} from './host.ts'
import * as Js from './js.ts'
import type {J, Res} from './js.ts'
import type {Agent} from './model.ts'
import {readStatus} from './model.ts'
import {orElse} from './str.ts'

export const request = (method: string, params: string): string =>
  Js.obj([Js.kv('id', Js.str('reflex')), Js.kv('method', Js.str(method)), Js.kv('params', params)]) + '\n'

// A response line: its result, or its error as text.
export function answer(v: J): Res<J> {
  const res = Js.get(v, 'result')
  if (res !== undefined) return Js.done(res)
  const e = Js.get(v, 'error')
  return Js.fail(1, e === undefined ? 'herdr: no result' : Js.textAt(e, 'code') + ': ' + Js.textAt(e, 'message'))
}

export async function call(sock: string, method: string, params: string, timeoutMs: number): Promise<Res<J>> {
  const r = await unixCall(sock, request(method, params), 8388608, timeoutMs)
  if (!r.ok) return r
  const v = Js.read(r.v)
  return v.ok ? answer(v.v) : v
}

// Machines
// --------
// An agent on another Mac (a herdr saved machine whose sockets the app
// forwards here) has the pane "<machine>/<pane>"; one on this Mac has herdr's
// own id. Herdr's ids never hold a '/', so everything above the socket treats
// both alike.

// The machine a pane is on ("" for this Mac).
export function machine(pane: string): string {
  const parts = pane.split('/')
  return parts.length >= 2 ? parts[0]! : ''
}

// The pane's id in its own machine's herdr.
export function bare(pane: string): string {
  const parts = pane.split('/')
  return parts.length >= 2 ? parts[1]! : parts[0]!
}

// Where a machine's herdr socket is forwarded to, in `dir`.
export const machineSock = (dir: string, m: string): string => dir + '/' + m + '.sock'

export const atOf = (sock: string, dir: string, m: string): string => (m.length === 0 ? sock : machineSock(dir, m))

// The socket of the herdr a pane lives in: this Mac's `sock`, or its machine's.
export const at = (sock: string, dir: string, pane: string): string => atOf(sock, dir, machine(pane))

// A pane of machine m's herdr, as reflexd knows it ("work/w1:p2").
export const paneOn = (m: string, pane: string): string => (m.length === 0 ? pane : m + '/' + pane)

// A machine's agents, as seen from here.
export const tags = (m: string, xs: Agent[]): Agent[] => xs.map((a) => ({...a, pane: m + '/' + a.pane}))

// The agents in `xs` on machine `m`.
export const on = (m: string, xs: readonly Agent[]): Agent[] => xs.filter((a) => machine(a.pane) === m)

// Reading agents
// --------------

export function agentOf(a: J): Agent {
  return {
    pane: Js.textAt(a, 'pane_id'),
    name: Js.textAt(a, 'name'),
    kind: Js.textAt(a, 'agent'),
    status: readStatus(Js.textAt(a, 'agent_status')),
    cwd: orElse(Js.textAt(a, 'foreground_cwd'), Js.textAt(a, 'cwd')),
    title: Js.textAt(a, 'terminal_title_stripped'),
    seq: Js.asU32(Js.get(a, 'state_change_seq'), 0),
    session: Js.textOf(Js.path(['agent_session', 'value'], a)),
    screen: '',
    parent: '',
  }
}

const readText = (r: Res<J>): Res<string> => (r.ok ? Js.done(Js.textOf(Js.path(['read', 'text'], r.v))) : r)

// "one", or several separated by spaces ("down down enter").
export const words = (ws: string[]): string[] => ws.filter((w) => w.length > 0)

// IO wrappers
// -----------

export async function listAgents(sock: string): Promise<Res<Agent[]>> {
  const r = await call(sock, 'agent.list', '{}', 3000)
  return r.ok ? Js.done(Js.asList(Js.get(r.v, 'agents')).map(agentOf)) : r
}

// The pane with its colors (SGR escapes), for a terminal-like view.
export async function readPaneAnsi(sock: string, pane: string, source: string, lines: number): Promise<Res<string>> {
  const p = Js.obj([
    Js.kv('pane_id', Js.str(pane)),
    Js.kv('source', Js.str(source)),
    Js.kv('lines', Js.num(lines)),
    Js.kv('format', Js.str('ansi')),
    Js.kv('strip_ansi', 'false'),
  ])
  return readText(await call(sock, 'pane.read', p, 3000))
}

export async function readPane(sock: string, pane: string, source: string, lines: number): Promise<Res<string>> {
  const p = Js.obj([Js.kv('pane_id', Js.str(pane)), Js.kv('source', Js.str(source)), Js.kv('lines', Js.num(lines)), Js.kv('strip_ansi', 'true')])
  return readText(await call(sock, 'pane.read', p, 3000))
}

export const prompt = (sock: string, target: string, text: string): Promise<Res<J>> =>
  call(sock, 'agent.prompt', Js.obj([Js.kv('target', Js.str(target)), Js.kv('text', Js.str(text))]), 10000)

export const press = (sock: string, pane: string, key: string): Promise<Res<J>> =>
  call(sock, 'pane.send_keys', Js.obj([Js.kv('pane_id', Js.str(pane)), Js.kv('keys', Js.strs(words(key.split(' '))))]), 5000)

export async function newWorkspace(sock: string, cwd: string, label: string): Promise<Res<string>> {
  const r = await call(sock, 'workspace.create', Js.obj([Js.kv('cwd', Js.str(cwd)), Js.kv('label', Js.str(label)), Js.kv('focus', 'false')]), 10000)
  return r.ok ? Js.done(Js.textOf(Js.path(['root_pane', 'pane_id'], r.v))) : r
}

// agent.start with arguments for the agent (e.g. --resume <id>).
export const startAgentArgs = (sock: string, name: string, kind: string, pane: string, args: string[]): Promise<Res<J>> =>
  call(
    sock,
    'agent.start',
    Js.obj([
      Js.kv('name', Js.str(name)),
      Js.kv('kind', Js.str(kind)),
      Js.kv('pane_id', Js.str(pane)),
      Js.kv('args', Js.arr(args.map(Js.str))),
      Js.kv('timeout_ms', '45000'),
    ]),
    50000,
  )

export const startAgent = (sock: string, name: string, kind: string, pane: string): Promise<Res<J>> =>
  call(sock, 'agent.start', Js.obj([Js.kv('name', Js.str(name)), Js.kv('kind', Js.str(kind)), Js.kv('pane_id', Js.str(pane)), Js.kv('timeout_ms', '45000')]), 50000)

// Close a pane: ends the agent running in it (the user asked, twice).
export const closePane = (sock: string, pane: string): Promise<Res<J>> => call(sock, 'pane.close', Js.obj([Js.kv('pane_id', Js.str(pane))]), 5000)

// The agent status Herdr has for a pane ("idle", "working", "blocked", …).
// Poll agent.get, not pane.get: it also advances a named agent's pending
// launch to interactive readiness. Merely reading its pane can leave a
// background pi idle but agent.prompt rejected until a terminal attaches.
export async function paneStatus(sock: string, pane: string): Promise<string> {
  const r = await call(sock, 'agent.get', Js.obj([Js.kv('target', Js.str(pane))]), 3000)
  return r.ok ? Js.textOf(Js.path(['agent', 'agent_status'], r.v)) : ''
}

// Literal text into a pane, no Enter (the phone's keyboard, typed live).
export const sendText = (sock: string, pane: string, text: string): Promise<Res<J>> =>
  call(sock, 'pane.send_text', Js.obj([Js.kv('pane_id', Js.str(pane)), Js.kv('text', Js.str(text))]), 5000)

export const focus = (sock: string, target: string): Promise<Res<J>> => call(sock, 'agent.focus', Js.obj([Js.kv('target', Js.str(target))]), 5000)
