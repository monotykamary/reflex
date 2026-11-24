// Core: the pure heart of reflexd. `step` folds one message into the state and
// says which dispatches must run now. It performs no IO, so every rule below
// (the undo window, exactly-once dispatch, inbox transitions) is a plain
// function that laws/ states facts about and proves.

import * as Js from './js.ts'
import type {Action, Agent, Dispatch, Item, Msg, Opt, Out, Receipt, Reply, Sort, State, Status} from './model.ts'
import {dispatchJson, stateJson} from './model.ts'
import {add32, isEmpty, lines, trim, trimStart} from './str.ts'


export const isBlocked = (s: Status): boolean => s === 'blocked'
export const isWorking = (s: Status): boolean => s === 'working'
export const isReady = (s: Status): boolean => s === 'idle' || s === 'finished'

// The undo window
// ---------------

export type Split = {due: Dispatch[]; rest: Dispatch[]}

// A dispatch is ripe once its undo window has passed.
export const ripe = (now: number, d: Dispatch): boolean => d.due <= now

// One element of `fire`: a dispatch put in front of the due or the rest.
export function splitPut(d: Dispatch, isRipe: boolean, s: Split): Split {
  return isRipe ? {due: [d, ...s.due], rest: s.rest} : {due: s.due, rest: [d, ...s.rest]}
}

// Dispatches whose undo window has passed, and the ones still waiting (each
// in the order it was pending).
export function fire(pending: readonly Dispatch[], now: number): Split {
  let sp: Split = {due: [], rest: []}
  for (let i = pending.length - 1; i >= 0; i--) sp = splitPut(pending[i]!, ripe(now, pending[i]!), sp)
  return sp
}

// Undo: the pending list without dispatch `id`.
export const cancel = (pending: readonly Dispatch[], id: number): Dispatch[] => pending.filter((d) => d.id !== id)

export const hasDispatch = (pending: readonly Dispatch[], id: number): boolean => pending.some((d) => d.id === id)

export const allRipe = (now: number, ds: readonly Dispatch[]): boolean => ds.every((d) => ripe(now, d))
export const noneRipe = (now: number, ds: readonly Dispatch[]): boolean => ds.every((d) => !ripe(now, d))

// Inbox items
// -----------

const dropItem = (items: readonly Item[], id: number): Item[] => items.filter((i) => i.id !== id)

// Items cleared by a list of dispatches that just ran.
function dropRan(ran: readonly Dispatch[], items: readonly Item[]): Item[] {
  let xs = items.slice()
  for (const d of ran) xs = dropItem(xs, d.item)
  return xs
}

export const findItem = (items: readonly Item[], id: number): Item | undefined => items.find((i) => i.id === id)
export const findOpt = (opts: readonly Opt[], key: string): Opt | undefined => opts.find((o) => o.key === key)

// Reading numbered options off a blocked agent's screen
// ----------------------------------------------------
// A line like "❯ 1. Yes" or "  2) No, and tell Claude" becomes {key: "2", ...}.

const isMarker = (c: number) => c === 10095 || c === 62 || c === 8250 || c === 9654 || c === 9679

function stripMarker(s: string): string {
  if (s.length === 0) return s
  const c = s.codePointAt(0)!
  return isMarker(c) ? trimStart(s.slice(c > 0xffff ? 2 : 1)) : s
}

function optOf(s: string, pane: string): Opt | undefined {
  const cs = Array.from(s)
  if (cs.length < 3) return undefined
  const d = cs[0]!.codePointAt(0)!
  const p = cs[1]!.codePointAt(0)!
  const sp = cs[2]!.codePointAt(0)!
  if (!(d >= 49 && d <= 57 && (p === 46 || p === 41) && sp === 32)) return undefined
  const key = cs[0]!
  return {key, label: trim(cs.slice(3).join('')), action: {type: 'press', pane, key}}
}

function optionsGo(ls: readonly string[], pane: string): Opt[] {
  const acc: Opt[] = []
  for (const l of ls) {
    const o = optOf(stripMarker(trimStart(l)), pane)
    if (o && !acc.some((x) => x.key === o.key)) acc.push(o)
  }
  return acc
}

// Checkbox lists (multi-select): a digit only ticks a box, so there is also
// a way on — Tab, to the next question or the review.
const isCheck = (label: string) =>
  label.startsWith('[ ]') || label.startsWith('[✔]') || label.startsWith('[✓]') || label.startsWith('[x]')

const withNext = (xs: Opt[], pane: string): Opt[] =>
  xs.some((o) => isCheck(o.label))
    ? [...xs, {key: '⇥', label: 'Next — keep these choices', action: {type: 'press', pane, key: 'tab'}}]
    : xs

// Menus without numbers ("❯ No, exit" over "  Yes, I trust this folder"):
// the run of lines at the selected line's indent are its items, answered by
// moving there with the arrows and pressing Enter.
type Line = {col: number; text: string; sel: boolean}

function lead(s: string): number {
  let n = 0
  while (n < s.length && s.charCodeAt(n) === 32) n++
  return n
}

function lineOf(s: string): Line {
  const n = lead(s)
  const t = trimStart(s)
  const cs = Array.from(t)
  if (cs.length >= 2 && cs[0]!.codePointAt(0) === 10095 && cs[1] === ' ')
    return {col: add32(n, 2), text: trim(cs.slice(2).join('')), sel: true}
  return {col: n, text: trim(t), sel: false}
}

const settle = (run: Line[], best: Line[]): Line[] => (run.some((l) => l.sel) && run.length >= 2 ? run : best)

// The last run on screen that holds the selected line and at least one other.
function menu(ls: readonly string[]): Line[] {
  let col = 100000
  let run: Line[] = []
  let best: Line[] = []
  for (const l of ls) {
    const x = lineOf(l)
    if (isEmpty(x.text)) {
      best = settle(run, best)
      col = 100000
      run = []
    } else if (x.col === col) {
      run = [...run, x]
    } else {
      best = settle(run, best)
      col = x.col
      run = [x]
    }
  }
  return settle(run, best)
}

// The keys from the selected item to item i, then Enter.
const moves = (i: number, sel: number): string =>
  i < sel ? 'up '.repeat(sel - i) + 'enter' : 'down '.repeat(i - sel) + 'enter'

function arrows(screen: string, pane: string): Opt[] {
  const m = menu(lines(screen))
  const found = m.findIndex((l) => l.sel)
  const sel = found < 0 ? 0 : found
  const out: Opt[] = []
  for (let i = 0; i < m.length; i++) {
    if (!(i < 9)) break
    out.push({key: String.fromCharCode(49 + i), label: m[i]!.text, action: {type: 'press', pane, key: moves(i, sel)}})
  }
  return out
}

// The answers on a blocked agent's screen: numbered options; failing those,
// an arrow menu; with checkboxes, a way on.
export function options(screen: string, pane: string): Opt[] {
  const nums = optionsGo(lines(screen), pane)
  return nums.length === 0 ? arrows(screen, pane) : withNext(nums, pane)
}

// What a question offers, as one string: when it changes while the agent
// stays blocked (the next question, a ticked box, the review), it is a new ask.
export const optsSig = (xs: readonly Opt[]): string => xs.map((o) => o.key + o.label + '|').join('')

// The last n non-empty lines of a screen, for an inbox card.
export function tailLines(screen: string, n: number): string {
  const xs = lines(screen).filter((h) => !isEmpty(trim(h)))
  return xs.slice(Math.max(0, xs.length - n)).join('\n')
}

// Agent transitions
// -----------------

export type Change = 'none' | 'blocked' | 'finished'

export function changeOf(wasBlocked: boolean, wasWorking: boolean, sameSeq: boolean, nowBlocked: boolean, nowReady: boolean): Change {
  if (nowBlocked) return wasBlocked && sameSeq ? 'none' : 'blocked'
  if (nowReady) return wasWorking ? 'finished' : 'none'
  return 'none'
}

export const findAgent = (agents: readonly Agent[], pane: string): Agent | undefined => agents.find((a) => a.pane === pane)

// The same question as before: same choices — or none readable right now
// (a redraw), which is not a new one either.
function sameAsk(p: Agent, cur: Agent): boolean {
  const was = optsSig(options(p.screen, ''))
  const now = optsSig(options(cur.screen, ''))
  return was === now || isEmpty(now)
}

export function change(prev: Agent | undefined, cur: Agent): Change {
  if (prev === undefined) return changeOf(false, false, false, isBlocked(cur.status), false)
  return changeOf(
    isBlocked(prev.status),
    isWorking(prev.status),
    prev.seq === cur.seq && sameAsk(prev, cur),
    isBlocked(cur.status),
    isReady(cur.status),
  )
}

// The last non-empty path component ("" for none).
export function baseName(path: string): string {
  let last = ''
  for (const h of path.split('/')) if (!isEmpty(h)) last = h
  return last
}

const agentLabel = (kind: string, cwd: string) => kind + ' · ' + baseName(cwd)

function itemFor(c: Change, id: number, now: number, a: Agent): Item | undefined {
  if (c === 'blocked')
    return {id, kind: 'ask', pane: a.pane, agent: agentLabel(a.kind, a.cwd), title: 'needs you', body: tailLines(a.screen, 14), opts: options(a.screen, a.pane), at: now}
  if (c === 'finished')
    return {id, kind: 'ready', pane: a.pane, agent: agentLabel(a.kind, a.cwd), title: 'finished', body: tailLines(a.screen, 10), opts: [], at: now}
  return undefined
}

// New inbox items for every agent whose state changed since `prev` (the last
// agent's first), and the next id.
function transitions(cur: readonly Agent[], prev: readonly Agent[], now: number, next: number): {next: number; items: Item[]} {
  let items: Item[] = []
  for (const a of cur) {
    const i = itemFor(change(findAgent(prev, a.pane), a), next, now, a)
    if (i) {
      next = add32(next, 1)
      items = [i, ...items]
    }
  }
  return {next, items}
}

// An ask card goes once its agent is no longer blocked; a ready card once its
// agent works again or disappears.
export function itemLiveOf(kind: Sort, here: Agent | undefined): boolean {
  if (kind === 'ask') return here !== undefined && isBlocked(here.status)
  if (kind === 'ready') return here !== undefined && !isWorking(here.status)
  return true
}

const itemLive = (agents: readonly Agent[], i: Item) => itemLiveOf(i.kind, findAgent(agents, i.pane))

const prune = (items: readonly Item[], agents: readonly Agent[]) => items.filter((i) => itemLive(agents, i))

// A pane's new question replaces the one it asked before.
const dropStale = (items: readonly Item[], fresh: readonly Item[]) =>
  items.filter((h) => !(h.kind === 'ask' && fresh.some((f) => f.kind === 'ask' && f.pane === h.pane)))

// step
// ----

const text = (json: string): Reply => ({r: 'text', json})
const okReply = (): Reply => text('{"ok":true}')
const errReply = (msg: string): Reply => text(Js.obj([Js.kv('ok', 'false'), Js.kv('error', Js.str(msg))]))

const INBOX = 60
const RECEIPTS = 30

function onPolled(s: State, ok: boolean, agents: Agent[]): Out {
  if (!ok) return {state: {...s, herdr: false}, run: [], reply: okReply()}
  const f = transitions(agents, s.agents, s.now, s.next)
  return {
    state: {...s, next: f.next, herdr: true, agents, inbox: [...f.items, ...prune(dropStale(s.inbox, f.items), agents)].slice(0, INBOX)},
    run: [],
    reply: okReply(),
  }
}

function onTick(s: State, now: number): Out {
  const sp = fire(s.pending, now)
  return {state: {...s, now, inbox: dropRan(sp.due, s.inbox), pending: sp.rest}, run: sp.due, reply: okReply()}
}

function enqueue(s: State, action: Action, label: string, item: number): Out {
  const d: Dispatch = {id: s.next, action, label, due: add32(s.now, s.undo), item}
  return {state: {...s, next: add32(s.next, 1), pending: [...s.pending, d]}, run: [], reply: text(dispatchJson(s.now, d))}
}

function onCancel(s: State, id: number): Out {
  return {
    state: {...s, pending: cancel(s.pending, id)},
    run: [],
    reply: text(Js.obj([Js.kv('ok', 'true'), Js.kv('cancelled', Js.bool(hasDispatch(s.pending, id)))])),
  }
}

const optLabel = (item: Item, o: Opt) => item.agent + ' ← ' + o.key + '. ' + o.label

function onAnswer(s: State, id: number, key: string): Out {
  const i = findItem(s.inbox, id)
  if (!i) return {state: s, run: [], reply: errReply('no such item')}
  const o = findOpt(i.opts, key)
  if (!o) return {state: s, run: [], reply: errReply('no such option')}
  return enqueue(s, o.action, optLabel(i, o), i.id)
}

function onPost(s: State, kind: Sort, pane: string, agent: string, title: string, body: string, opts: Opt[]): Out {
  const item: Item = {id: s.next, kind, pane, agent, title, body, opts, at: s.now}
  return {
    state: {...s, next: add32(s.next, 1), inbox: [item, ...s.inbox].slice(0, INBOX)},
    run: [],
    reply: text(Js.obj([Js.kv('ok', 'true'), Js.kv('item', Js.num(s.next))])),
  }
}

function onReceipt(s: State, id: number, label: string, ok: boolean, detail: string): Out {
  const failure: Item[] = ok ? [] : [{id: s.next, kind: 'note', pane: '', agent: 'reflex', title: 'failed: ' + label, body: detail, opts: [], at: s.now}]
  const r: Receipt = {id, label, ok, detail, at: s.now}
  return {
    state: {...s, next: add32(s.next, 1), inbox: [...failure, ...s.inbox].slice(0, INBOX), receipts: [r, ...s.receipts].slice(0, RECEIPTS)},
    run: [],
    reply: okReply(),
  }
}

// The only function that changes a State.
export function step(s: State, m: Msg): Out {
  switch (m.m) {
    case 'tick':
      return onTick(s, m.now)
    case 'polled':
      return onPolled(s, m.ok, m.agents)
    case 'indexed':
      return {state: {...s, folders: m.folders}, run: [], reply: okReply()}
    case 'enqueue':
      return enqueue(s, m.action, m.label, m.item)
    case 'cancel':
      return onCancel(s, m.id)
    case 'answer':
      return onAnswer(s, m.item, m.key)
    case 'dismiss':
      return {state: {...s, inbox: dropItem(s.inbox, m.item)}, run: [], reply: okReply()}
    case 'post':
      return onPost(s, m.kind, m.pane, m.agent, m.title, m.body, m.opts)
    case 'receipted':
      return onReceipt(s, m.id, m.label, m.ok, m.detail)
    case 'query':
      return {state: s, run: [], reply: text(stateJson(s))}
    case 'context':
      return {state: s, run: [], reply: {r: 'context', agents: s.agents, folders: s.folders}}
  }
}

// A sent prompt, on screen
// ------------------------
// Claude Code and pi draw their input between two rules. Split the screen
// there: the conversation above the box, and what is typed in it. Matched
// with spaces, line breaks and box sides squashed out, so wrapping in the
// box can't hide the words.

type Box = {above: string; inside: string; found: boolean}

const isRule = (l: string) => l.includes('──────────')

export const squash = (s: string): string => s.split(' ').join('').split('\n').join('').split('│').join('')

// Bottom up: past the footer to the box's foot, then up to its top; what is
// between is typed, what is above is the conversation.
function box(screen: string): Box {
  let foot = false
  let top = false
  const inside: string[] = []
  const above: string[] = []
  for (const h of lines(screen).reverse()) {
    const r = isRule(h)
    if (!foot) {
      if (r) foot = true
    } else if (!top) {
      if (r) top = true
      else inside.unshift(h)
    } else above.unshift(h)
  }
  return {above: above.join('\n'), inside: inside.join('\n'), found: top}
}

// The words to look for: the request's first line, squashed, 20 characters.
export function probe(t: string): string {
  return Array.from(squash(lines(t)[0]!)).slice(0, 20).join('')
}

// A long paste shows as "[Pasted text #1 +12 lines]" rather than its words.
const holds = (s: string, p: string) => squash(s).includes(p) || s.includes('[Pasted text')

const readyText = (status: string) => status === 'idle' || status === 'done'

// Still idle with the request in its input: typed, not sent (its Enter read
// as a new line). With no box to read, the words anywhere on screen will do.
export function promptTyped(status: string, screen: string, p: string): boolean {
  if (!(readyText(status) && !isEmpty(p))) return false
  const b = box(screen)
  return b.found ? holds(b.inside, p) : squash(screen).includes(p)
}

// Still idle, an input box on screen, and the request nowhere: not in the
// box, not in the conversation above it. It never arrived.
export function promptMissing(status: string, screen: string, p: string): boolean {
  if (!(readyText(status) && !isEmpty(p))) return false
  const b = box(screen)
  return b.found && !holds(b.inside, p) && !holds(b.above, p)
}

