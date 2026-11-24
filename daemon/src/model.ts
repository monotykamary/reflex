// Domain model of reflexd. Everything here is plain data: the daemon's state,
// the events that change it and the actions it may perform. core.step is the
// only function that changes a State. Pure: no IO.

import * as Js from './js.ts'
import {sub32} from './str.ts'

// An agent's lifecycle state, as herdr reports it, or as the agent reports
// itself to herdr-core (OSC 7501) — "done" is finished here, and an agent
// that never said is unknown.
export type Status = 'idle' | 'working' | 'blocked' | 'finished' | 'unknown'

// A coding agent living in a herdr-core terminal ("t7", "box/t7") or a herdr
// pane ("w1:p2", "work/w1:p2"); see term.ts.
export type Agent = {
  pane: string
  name: string
  kind: string
  status: Status
  cwd: string
  title: string
  seq: number
  session: string
  screen: string
  // The terminal that started it (`hc run` in it), "" for none.
  parent: string
}

// A folder where a new session may start (built by folders.ts from the scan).
export type Folder = {
  path: string
  name: string
  desc: string
  recent: string
  branch: string
  age: number
  uses: number
}

// What reflexd can do to the world. Every action goes through the undo window.
export type Action =
  // submit a prompt to an existing agent
  | {type: 'prompt'; pane: string; text: string}
  // open a workspace in cwd, start a harness there, then prompt it
  | {type: 'spawn'; cwd: string; kind: string; text: string}
  // bring an earlier session back in cwd — mode "resume" (continue it), "fork"
  // (a copy: it is open elsewhere) or "attach" (a running background session)
  // — then prompt it if text is set
  | {type: 'resume'; cwd: string; kind: string; session: string; mode: string; text: string}
  // press one key in an agent's pane, e.g. "1" to answer a numbered question
  | {type: 'press'; pane: string; key: string}
  // the harness's own side-question command, typed into its TUI (/btw)
  | {type: 'btw'; pane: string; text: string}
  // fork the agent's session headlessly and ask there; the reply comes back
  // as an inbox item and the original agent is never touched
  | {type: 'fork'; pane: string; kind: string; cwd: string; session: string; text: string}

// One answer an inbox item offers (pressed as 1, 2, 3...).
export type Opt = {key: string; label: string; action: Action}

export type Sort = 'ask' | 'ready' | 'reply' | 'route' | 'note'

export type Item = {
  id: number
  kind: Sort
  pane: string
  agent: string
  title: string
  body: string
  opts: Opt[]
  at: number
}

// An action waiting out its undo window.
export type Dispatch = {id: number; action: Action; label: string; due: number; item: number}

// What happened to a dispatch once it ran.
export type Receipt = {id: number; label: string; ok: boolean; detail: string; at: number}

export type State = {
  now: number
  next: number
  undo: number
  herdr: boolean
  agents: Agent[]
  inbox: Item[]
  pending: Dispatch[]
  receipts: Receipt[]
  folders: Folder[]
}

export type Msg =
  // the clock moved (ms since the daemon started)
  | {m: 'tick'; now: number}
  // a fresh view of the agents (ok = the backend answered)
  | {m: 'polled'; ok: boolean; agents: Agent[]}
  // the folder index was (re)built
  | {m: 'indexed'; folders: Folder[]}
  // schedule an action after the undo window; `item` is resolved when it runs
  | {m: 'enqueue'; action: Action; label: string; item: number}
  // undo a pending action
  | {m: 'cancel'; id: number}
  // answer an inbox item with one of its options
  | {m: 'answer'; item: number; key: string}
  // clear an inbox item
  | {m: 'dismiss'; item: number}
  // add an inbox item
  | {m: 'post'; kind: Sort; pane: string; agent: string; title: string; body: string; opts: Opt[]}
  // a dispatch finished running
  | {m: 'receipted'; id: number; label: string; ok: boolean; detail: string}
  // read the state as JSON
  | {m: 'query'}
  // read what routing needs
  | {m: 'context'}

export type Reply = {r: 'text'; json: string} | {r: 'context'; agents: Agent[]; folders: Folder[]}

export type Out = {state: State; run: Dispatch[]; reply: Reply}

export const emptyState = (undo: number): State => ({
  now: 0,
  next: 1,
  undo,
  herdr: false,
  agents: [],
  inbox: [],
  pending: [],
  receipts: [],
  folders: [],
})

// Status text
// -----------

export function readStatus(s: string): Status {
  if (s === 'idle') return 'idle'
  if (s === 'working') return 'working'
  if (s === 'blocked') return 'blocked'
  if (s === 'done') return 'finished'
  return 'unknown'
}

export const showStatus = (s: Status): string => (s === 'finished' ? 'done' : s)

// JSON rendering
// --------------

export function actionJson(a: Action): string {
  const {str, kv, obj} = Js
  switch (a.type) {
    case 'prompt':
      return obj([kv('type', str('prompt')), kv('pane', str(a.pane)), kv('text', str(a.text))])
    case 'spawn':
      return obj([kv('type', str('spawn')), kv('cwd', str(a.cwd)), kv('kind', str(a.kind)), kv('text', str(a.text))])
    case 'resume':
      return obj([
        kv('type', str('resume')),
        kv('cwd', str(a.cwd)),
        kv('kind', str(a.kind)),
        kv('session', str(a.session)),
        kv('mode', str(a.mode)),
        kv('text', str(a.text)),
      ])
    case 'press':
      return obj([kv('type', str('press')), kv('pane', str(a.pane)), kv('key', str(a.key))])
    case 'btw':
      return obj([kv('type', str('btw')), kv('pane', str(a.pane)), kv('text', str(a.text))])
    case 'fork':
      return obj([
        kv('type', str('fork')),
        kv('pane', str(a.pane)),
        kv('kind', str(a.kind)),
        kv('cwd', str(a.cwd)),
        kv('text', str(a.text)),
      ])
  }
}

export function agentJson(a: Agent): string {
  const {str, kv, obj, num} = Js
  return obj([
    kv('pane', str(a.pane)),
    kv('name', str(a.name)),
    kv('kind', str(a.kind)),
    kv('status', str(showStatus(a.status))),
    kv('cwd', str(a.cwd)),
    kv('title', str(a.title)),
    kv('seq', num(a.seq)),
    kv('session', str(a.session)),
    kv('parent', str(a.parent)),
  ])
}

export const optJson = (o: Opt): string =>
  Js.obj([Js.kv('key', Js.str(o.key)), Js.kv('label', Js.str(o.label)), Js.kv('action', actionJson(o.action))])

export const optJsons = (os: Opt[]): string[] => os.map(optJson)

export function itemJson(i: Item): string {
  const {str, kv, obj, num, arr} = Js
  return obj([
    kv('id', num(i.id)),
    kv('kind', str(i.kind)),
    kv('pane', str(i.pane)),
    kv('agent', str(i.agent)),
    kv('title', str(i.title)),
    kv('body', str(i.body)),
    kv('options', arr(optJsons(i.opts))),
    kv('at', num(i.at)),
  ])
}

export function dispatchJson(now: number, d: Dispatch): string {
  const {str, kv, obj, num} = Js
  return obj([
    kv('id', num(d.id)),
    kv('label', str(d.label)),
    kv('action', actionJson(d.action)),
    kv('due', num(d.due)),
    kv('left', num(sub32(d.due, Math.min(d.due, now)))),
    kv('item', num(d.item)),
  ])
}

export const receiptJson = (r: Receipt): string =>
  Js.obj([
    Js.kv('id', Js.num(r.id)),
    Js.kv('label', Js.str(r.label)),
    Js.kv('ok', Js.bool(r.ok)),
    Js.kv('detail', Js.str(r.detail)),
    Js.kv('at', Js.num(r.at)),
  ])

export function stateJson(s: State): string {
  const {kv, obj, num, arr, bool, nat} = Js
  return obj([
    kv('now', num(s.now)),
    kv('undo', num(s.undo)),
    kv('herdr', bool(s.herdr)),
    kv('folders', nat(s.folders.length)),
    kv('agents', arr(s.agents.map(agentJson))),
    kv('inbox', arr(s.inbox.map(itemJson))),
    kv('pending', arr(s.pending.map((d) => dispatchJson(s.now, d)))),
    kv('receipts', arr(s.receipts.map(receiptJson))),
  ])
}
