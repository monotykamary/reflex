// The laws of reflexd's pure core. First every gdp-wired proof (laws/: each
// law proven, each broken variant refused, each rule held to the real code),
// then each law as LAWS.bend stated it, checked on the real functions over
// many random inputs: the claims about whole lists and whole states that the
// rules model element by element.

import {expect, test} from 'bun:test'
import * as Core from '../src/core.ts'
import * as Ix from '../src/folders.ts'
import type {Action, Agent, Dispatch, Folder, Item, State, Status} from '../src/model.ts'
import {emptyState} from '../src/model.ts'
import type {Past} from '../src/past.ts'
import * as R from '../src/route.ts'
import {rand} from '../laws/kit.ts'
import {allRows} from '../laws/run.ts'

test('every law proven with gdp-wired, every broken variant refused, every rule held to the code', () => {
  const rows = allRows()
  const bad = rows.filter((r) => !r.ok)
  for (const r of bad) console.log(`FAIL ${r.area}: ${r.law}: ${r.verdict}`)
  console.log(`${rows.length} rows: ${bad.length === 0 ? 'ALL LAWS PROVEN' : `${bad.length} FAILED`}`)
  expect(bad).toEqual([])
})

const N = 3000
const r = rand(7)
const pick = <T>(xs: readonly T[]): T => xs[r(xs.length)]!
const STATUS: Status[] = ['idle', 'working', 'blocked', 'finished', 'unknown']
const TEXT = ['', 'fix it', 'btw why', '/btw what', 'resume the theme work', 'pi-fabric again', 'Ünïcode', 'claude: go']
const action = (): Action => pick<Action>([{type: 'prompt', pane: 't1', text: 'x'}, {type: 'press', pane: 'w1:p2', key: '1'}, {type: 'spawn', cwd: '/a', kind: 'pi', text: ''}])
const dispatches = (): Dispatch[] => Array.from({length: r(8)}, () => ({id: r(10), action: action(), label: pick(['', 'l']), due: r(100), item: r(4)}))
const agent = (status: Status = pick(STATUS)): Agent => ({
  pane: pick(['t1', 'box/t2', 'w1:p1']),
  name: pick(['a', '']),
  kind: pick(['claude', 'pi', 'codex', '']),
  status,
  cwd: pick(['/a', '/Users/me/VCS/app']),
  title: pick(['', 't']),
  seq: r(4),
  session: pick(['', 's']),
  screen: pick(['', 'Proceed?\n❯ 1. Yes\n  2. No', 'Pick\n   A\n ❯ B']),
  parent: '',
})
const item = (): Item => ({id: r(6), kind: pick(['ask', 'ready', 'reply', 'route', 'note'] as const), pane: 't1', agent: 'a', title: '', body: '', opts: r(2) ? [{key: '1', label: 'x', action: action()}] : [], at: 0})
const state = (): State => ({
  ...emptyState(r(50)),
  now: r(100),
  next: 1 + r(20),
  herdr: r(2) === 0,
  agents: Array.from({length: r(3)}, () => agent()),
  inbox: Array.from({length: r(4)}, item),
  pending: dispatches(),
  receipts: [],
  folders: [],
})

test('fired_are_ripe, kept_are_unripe, fire_partitions: on any pending list', () => {
  for (let t = 0; t < N; t++) {
    const ps = dispatches()
    const now = r(100)
    const sp = Core.fire(ps, now)
    expect(Core.allRipe(now, sp.due)).toBe(true)
    expect(Core.noneRipe(now, sp.rest)).toBe(true)
    expect(sp.due.length + sp.rest.length).toBe(ps.length)
  }
})

test('cancel_removes: on any pending list and id', () => {
  for (let t = 0; t < N; t++) {
    const id = r(12)
    expect(Core.hasDispatch(Core.cancel(dispatches(), id), id)).toBe(false)
  }
})

test('tick_runs_ripe, tick_keeps_unripe: a tick runs exactly fire’s due and keeps exactly its rest', () => {
  for (let t = 0; t < N; t++) {
    const s = state()
    const now = r(100)
    const out = Core.step(s, {m: 'tick', now})
    const sp = Core.fire(s.pending, now)
    expect(out.run).toEqual(sp.due)
    expect(out.state.pending).toEqual(sp.rest)
  }
})

test('enqueue_runs_nothing, answer_runs_nothing: only ticks run anything', () => {
  for (let t = 0; t < N; t++) {
    const s = state()
    expect(Core.step(s, {m: 'enqueue', action: action(), label: pick(['', 'x']), item: r(5)}).run).toEqual([])
    const i = s.inbox[0]
    expect(Core.step(s, {m: 'answer', item: i ? i.id : r(9), key: pick(['1', '2', ''])}).run).toEqual([])
  }
})

test('new_blocked_agent_asks, finished_turn_reports, answered_question_clears: on any agent', () => {
  for (let t = 0; t < N; t++) {
    const a = agent('blocked')
    expect(Core.change(undefined, a)).toBe('blocked')
    const w = agent('working')
    expect(Core.change(agent(), {...w, status: 'idle'})).not.toBe('blocked')
    expect(Core.change(w, {...w, status: 'idle'})).toBe('finished')
    expect(Core.itemLiveOf('ask', w)).toBe(false)
  }
})

const folder = (): Folder => ({path: pick(['/Users/me/a', '/x/b', 'work:/c']), name: pick(['a', 'b', 'pi-fabric']), desc: '', recent: '', branch: '', age: r(900), uses: r(5)})
const pickOf = (prefix: string, n: number): R.Pick | undefined =>
  r(4) === 0 ? undefined : {key: r(5) === 0 ? 'new' : prefix + r(n + 1), bp: r(10001), all: Array.from({length: n}, (_, i) => ({key: prefix + i, bp: r(10001)}))}
const seen = (): R.Seen[] => Array.from({length: r(3)}, () => ({agent: agent(), recent: ''}))
const past = (): Past => ({agent: pick(['claude', 'pi', 'codex']), id: 'i' + r(3), cwd: '/a', title: 't', last: 'l', age: r(50), state: pick(['past', 'running', 'elsewhere'])})
const decision = (): R.Decision => R.decide(pick(TEXT), '/Users/me', 'claude', 6000, seen(), [folder(), folder()], pickOf('a', 2), pickOf('f', 2), r(10001))

test('unsure_target_never_acts, unsure_folder_never_acts: on any request', () => {
  for (let t = 0; t < N; t++) {
    const sn = seen()
    const fs = [folder(), folder()]
    const d = R.decideTarget(false, r(2) === 0, r(2) ? agent() : undefined, pick(TEXT), '/Users/me', 'claude', r(10001), sn, fs, pickOf('a', 2), pickOf('f', 2), r(10001))
    expect(R.isGo(d)).toBe(false)
    const f = R.decideFolderPick(false, r(2) ? folder() : undefined, pick(TEXT), '/Users/me', 'claude', sn, fs, pickOf('a', 2), pickOf('f', 2))
    expect(R.isGo(f)).toBe(false)
  }
})

test('unsure_resume_changes_nothing, live_session_beats_resume: on any decision', () => {
  for (let t = 0; t < N; t++) {
    const d = decision()
    const ps = Array.from({length: r(4)}, past)
    expect(R.withPast(false, 'p' + r(4), ps, d, pick(TEXT))).toBe(d)
    expect(R.promotePick(true, r(2) ? past() : undefined, d, pick(TEXT))).toBe(d)
    if (R.liveGo(d)) expect(R.withPast(true, 'p0', ps, d, pick(TEXT))).toBe(d)
  }
})

test('blocked_agent_gets_no_native_btw: for any kind', () => {
  for (let t = 0; t < N; t++) {
    const kind = Array.from({length: r(7)}, () => pick(['c', 'l', 'a', 'u', 'd', 'e', 'p', 'i'])).join('')
    expect(R.sideFor(kind, 'blocked')).not.toBe('native')
    expect(R.sideFor('claude', 'blocked')).not.toBe('native')
  }
})

test('rank_is_bounded: for any request, folders and k', () => {
  for (let t = 0; t < N; t++) {
    const k = r(10)
    expect(Ix.rank(pick(TEXT) + ' ' + pick(TEXT), Array.from({length: r(15)}, folder), k).length).toBeLessThanOrEqual(k)
  }
})
