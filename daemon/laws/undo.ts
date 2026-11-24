// The undo window: what `fire`, `cancel` and core.step do with pending
// dispatches, as gdp-wired rules, with their laws, the bug each law rules
// out, and the real functions they are held to.

import {everyBelow, forall, nat, oneOf, record, rule, when} from 'gdp-wired'
import * as Core from '../src/core.ts'
import type {Dispatch, Msg, State} from '../src/model.ts'
import {emptyState} from '../src/model.ts'
import type {Entry} from './kit.ts'
import {mapsHold, rand} from './kit.ts'

const D = record({id: nat, due: nat})

const dispatch = (id: number, due: number): Dispatch => ({id, due, action: {type: 'press', pane: 't1', key: '1'}, label: '', item: 0})

// fire(pending, now) is a fold, last element first, of one step: the
// dispatch put in front of the due ones if ripe (due <= now), else in front
// of the rest. The rule takes the list that way, one dispatch a request.
const fireRule = (ripe: (due: ReturnType<typeof nat.from> | any, now: any) => any, dup = false) =>
  rule('fire')
    .params({now: nat})
    .inputs({id: nat, due: nat})
    .state({seen: 0})
    .items({Due: D, Rest: D})
    .flags(({due, now}) => ({ripe: ripe(due, now)}))
    .step(({id, due, ripe, Due, Rest, seen}) => ({
      ...Due.apply(Due.insertAt(0, {id, due}, ripe)),
      ...Rest.apply(Rest.insertAt(0, {id, due}, dup ? ripe.or(ripe.not()) : ripe.not())),
      seen: seen.plus(1),
    }))

export const fire = fireRule((due, now) => due.atMost(now))
const firedAreRipe = fire.law('fired_are_ripe: every dispatch fire releases is ripe', ({Due, Due_len, now}) =>
  everyBelow(Due_len, (i) => Due.at(i).due.atMost(now)),
)
const keptAreUnripe = fire.law('kept_are_unripe: every dispatch fire keeps is still unripe', ({Rest, Rest_len, now}) =>
  everyBelow(Rest_len, (i) => Rest.at(i).due.gt(now)),
)
const firePartitions = fire.law('fire_partitions: fire neither loses nor duplicates a dispatch', ({Due_len, Rest_len, seen}) =>
  Due_len.plus(Rest_len).eq(seen),
)

type Shape = {seen: number; Due_len: number; Rest_len: number; Due: {id: number; due: number}[]; Rest: {id: number; due: number}[]}
const shape = (sp: Core.Split, seen: number): Shape => ({
  seen,
  Due_len: sp.due.length,
  Rest_len: sp.rest.length,
  Due: sp.due.map((d) => ({id: d.id, due: d.due})),
  Rest: sp.rest.map((d) => ({id: d.id, due: d.due})),
})
const splitOf = (st: Shape): Core.Split => ({due: st.Due.map((d) => dispatch(d.id, d.due)), rest: st.Rest.map((d) => dispatch(d.id, d.due))})

// fire as the code runs it: Core.splitPut and Core.ripe, step by step...
const fireHeld = () =>
  fire.compare(
    {
      init: () => shape({due: [], rest: []}, 0),
      step: ({now}, st, {id, due}) => {
        const d = dispatch(id, due)
        return shape(Core.splitPut(d, Core.ripe(now, d), splitOf(st as Shape)), (st as Shape).seen + 1)
      },
    },
    {trials: 400, depth: 12, bound: 60},
  )

// ...and Core.fire itself is that fold, the last dispatch first.
function fireIsTheFold(): {checked: number; failure?: string} {
  const it = fire.compiled()
  const r = rand(11)
  for (let t = 0; t < 2000; t++) {
    const now = r(60)
    const ps = Array.from({length: r(9)}, (_, i) => dispatch(i + 1, r(90)))
    const params = fire.encodeParams({now})
    let st = it.init(params)
    for (const d of [...ps].reverse()) st = it.step(params, st, fire.encodeInput({id: d.id, due: d.due}))
    const got = fire.decode(st) as unknown as Shape
    const real = Core.fire(ps, now)
    const want = shape(real, ps.length)
    if (JSON.stringify(got) !== JSON.stringify(want)) return {checked: t, failure: `fire(${JSON.stringify(ps.map((d) => d.due))}, ${now}): ${JSON.stringify(want)} vs the rule's ${JSON.stringify(got)}`}
  }
  return {checked: 2000}
}

// cancel(pending, id) is a fold too: a dispatch kept unless it is `id`.
const cancelRule = (keep: (d: any, id: any) => any) =>
  rule('cancel')
    .params({id: nat})
    .inputs({d: nat})
    .items({Kept: nat})
    .step(({d, id, Kept}) => Kept.apply(Kept.insertAt(0, d, keep(d, id))))

export const cancel = cancelRule((d, id) => d.eq(id).not())
const cancelRemoves = cancel.law('cancel_removes: a cancelled dispatch is no longer pending', ({Kept, Kept_len, id}) =>
  everyBelow(Kept_len, (i) => Kept.at(i).eq(id).not()),
)

const cancelHeld = () =>
  cancel.compare(
    {
      init: () => ({Kept_len: 0, Kept: [] as number[]}),
      step: ({id}, st, {d}) => {
        const kept = Core.keepDispatch(d !== id, dispatch(d, 0), (st.Kept as number[]).map((k) => dispatch(k, 0)))
        return {Kept_len: kept.length, Kept: kept.map((x) => x.id)}
      },
    },
    {trials: 400, depth: 12, bound: 8},
  )

function cancelIsTheFold(): {checked: number; failure?: string} {
  const it = cancel.compiled()
  const r = rand(12)
  for (let t = 0; t < 2000; t++) {
    const id = r(6)
    const ps = Array.from({length: r(9)}, () => dispatch(r(6), 0))
    const params = cancel.encodeParams({id})
    let st = it.init(params)
    for (const d of [...ps].reverse()) st = it.step(params, st, cancel.encodeInput({d: d.id}))
    const got = (cancel.decode(st) as {Kept: number[]}).Kept
    const want = Core.cancel(ps, id).map((d) => d.id)
    if (JSON.stringify(got) !== JSON.stringify(want)) return {checked: t, failure: `cancel(${JSON.stringify(ps.map((d) => d.id))}, ${id})`}
  }
  return {checked: 2000}
}

// The undo window as core.step keeps it, every message of it: Due[k] is
// dispatch k's due time plus one while it is pending (0 when it isn't), Ran[k]
// how many times it was run. A tick runs every ripe pending dispatch and
// keeps the rest; an enqueue (or an answer that finds its option) makes
// dispatch `next`, due `undo` after the clock; a cancel drops dispatch `id`;
// a post (an inbox item, a receipt) takes an id; nothing else touches it.
const OPS = ['tick', 'enqueue', 'answer', 'cancel', 'post', 'other'] as const
const windowRule = (opts: {late?: boolean; keepRan?: boolean; runOnEnqueue?: boolean} = {}) =>
  rule('undo window')
    .params({undo: nat})
    .inputs({op: oneOf(...OPS), now: nat, id: nat})
    .state({clock: 0, next: 1})
    .maps({Due: 0, Ran: 0})
    .flags(({op, id}) => ({tick: op.is('tick'), make: op.is('enqueue').or(op.is('answer').and(id.gt(0))), drop: op.is('cancel'), takes: op.is('post')}))
    .step(({tick, make, drop, takes, now, id, undo, clock, next, Due, Ran}) => {
      const ripe = (k: any) => tick.and(Due.at(k).gt(0)).and(Due.at(k).minus(1).atMost(opts.late ? now.plus(1) : now))
      return {
        clock: when(tick, now, clock),
        next: when(make.or(takes), next.plus(1), next),
        Due: Due.each((k) => when(ripe(k), opts.keepRan ? Due.at(k) : 0, when(make.and(k.eq(next)), clock.plus(undo).plus(1), when(drop.and(k.eq(id)), 0, Due.at(k))))),
        Ran: Ran.each((k) => Ran.at(k).plus(when(ripe(k).or(opts.runOnEnqueue ? make.and(k.eq(next)) : ripe(k).and(ripe(k).not())), 1, 0))),
      }
    })

export const window = windowRule()
const windowLaws = (r: typeof window) => {
  const nextPos = r.law('next is at least 1', ({next}) => next.atLeast(1))
  const zero = r.law('id 0 is never a dispatch', ({Due, Ran}) => Due.at(0).eq(0).and(Ran.at(0).eq(0)))
  const fresh = r.law('ids from next on are unused', ({Due, Ran, next}) => forall((k) => k.atLeast(next).implies(Due.at(k).eq(0).and(Ran.at(k).eq(0)))))
  const ranGone = r.law('a dispatch that ran is no longer pending', ({Due, Ran}) => forall((k) => Ran.at(k).gt(0).implies(Due.at(k).eq(0))))
  const once = r.law('exactly once: a dispatch runs at most once', ({Ran}) => forall((k) => Ran.at(k).atMost(1)))
  const runsRipe = r.stepLaw('tick_runs_ripe, enqueue_runs_nothing, answer_runs_nothing: a step runs only ripe dispatches, and only on a tick', (b, a) =>
    forall((k) => a.Ran.at(k).gt(b.Ran.at(k)).implies(b.tick.and(b.Due.at(k).gt(0)).and(b.Due.at(k).minus(1).atMost(b.now)))),
  )
  const keepsUnripe = r.stepLaw(
    'tick_keeps_unripe: a tick keeps exactly the unripe dispatches pending, as they were',
    (b, a) => forall((k) => a.Due.at(k).gt(0).iff(b.Due.at(k).gt(0).and(b.Due.at(k).minus(1).gt(b.now))).and(a.Due.at(k).gt(0).implies(a.Due.at(k).eq(b.Due.at(k))))),
    (b) => b.tick,
  )
  const tickPartitions = r.stepLaw('a tick runs or keeps every pending dispatch, never both', (b, a) =>
    forall((k) => b.Due.at(k).gt(0).implies(a.Due.at(k).gt(0).iff(a.Ran.at(k).eq(b.Ran.at(k))))),
    (b) => b.tick,
  )
  const cancelled = r.stepLaw('cancel_removes: a cancelled dispatch is no longer pending', (b, a) => a.Due.at(b.id).eq(0), (b) => b.drop)
  return {laws: [nextPos, zero, fresh, ranGone, once], steps: [runsRipe, keepsUnripe, tickPartitions, cancelled]}
}

// core.step, message by message, beside the rule: the same pending
// dispatches with the same due times, the same ones run, the same clock and
// ids. (compare reads a rule's scalars and lists; this reads its maps too.)
function windowHeld(): {checked: number; failure?: string} {
  const r = rand(13)
  return mapsHold(window, 600, 14, (step) => {
    const undo = r(4) === 0 ? 0 : r(50)
    const optKey = '1'
    let s: State = {...emptyState(undo), inbox: [{id: 999999, kind: 'ask', pane: 't1', agent: 'a', title: '', body: '', opts: [{key: optKey, label: 'x', action: {type: 'press', pane: 't1', key: '1'}}], at: 0}]}
    const ran = new Map<number, number>()
    step.init({undo})
    let now = 0
    for (let i = 0; i < 14; i++) {
      const op = OPS[r(OPS.length)]!
      now = r(3) === 0 ? now : now + r(40)
      const pend = s.pending.map((d) => d.id)
      const id = op === 'cancel' ? (pend.length > 0 && r(3) > 0 ? pend[r(pend.length)]! : r(s.next + 2)) : 0
      // An answer finds its option while the item is in the inbox (a run
      // dispatch takes its item away).
      const found = op === 'answer' && r(2) === 0 && s.inbox.some((it) => it.id === 999999)
      const others: Msg[] = [{m: 'query'}, {m: 'context'}, {m: 'dismiss', item: 5}, {m: 'indexed', folders: []}, {m: 'polled', ok: false, agents: []}]
      const msg: Msg =
        op === 'tick'
          ? {m: 'tick', now}
          : op === 'enqueue'
            ? {m: 'enqueue', action: {type: 'prompt', pane: 't1', text: 'x'}, label: 'l', item: 0}
            : op === 'answer'
              ? {m: 'answer', item: found ? 999999 : 424242, key: optKey}
              : op === 'cancel'
                ? {m: 'cancel', id}
                : op === 'post'
                  ? r(2) === 0
                    ? {m: 'post', kind: 'note', pane: '', agent: '', title: '', body: '', opts: []}
                    : {m: 'receipted', id: 1, label: 'l', ok: r(2) === 0, detail: ''}
                  : others[r(others.length)]!
      const out = Core.step(s, msg)
      s = out.state
      for (const d of out.run) ran.set(d.id, (ran.get(d.id) ?? 0) + 1)
      const failure = step.step(
        {op, now: op === 'tick' ? now : 0, id: op === 'answer' ? (found ? 1 : 0) : id},
        {clock: s.now, next: s.next},
        {Due: new Map(s.pending.map((d) => [d.id, d.due + 1])), Ran: ran},
      )
      if (failure) return failure
    }
    return undefined
  })
}

export const entries: Entry[] = [
  {
    area: 'the undo window',
    rule: fire,
    laws: [firedAreRipe, keptAreUnripe, firePartitions],
    from: 'any',
    broken: [
      {what: 'a dispatch released one ms early (due <= now + 1)', rule: fireRule((due, now) => due.atMost(now.plus(1))), laws: [firedAreRipe]},
      {what: 'a dispatch kept at its due time (due < now)', rule: fireRule((due, now) => due.lt(now)), laws: [keptAreUnripe]},
      {what: 'a ripe dispatch both released and kept', rule: fireRule((due, now) => due.atMost(now), true), laws: [firePartitions]},
    ],
    held: [
      {against: 'Core.splitPut, Core.ripe (rule.compare)', run: fireHeld},
      {against: 'Core.fire = that fold (rule run beside it)', run: fireIsTheFold},
    ],
  },
  {
    area: 'the undo window',
    rule: cancel,
    laws: [cancelRemoves],
    from: 'any',
    broken: [{what: 'cancel that keeps everything', rule: cancelRule((d, _id) => d.eq(d)), laws: [cancelRemoves]}],
    held: [
      {against: 'Core.keepDispatch (rule.compare)', run: cancelHeld},
      {against: 'Core.cancel = that fold (rule run beside it)', run: cancelIsTheFold},
    ],
  },
  (() => {
    const w = windowLaws(window)
    return {
      area: 'the undo window',
      rule: window,
      laws: w.laws,
      steps: w.steps,
      from: 'any' as const,
      broken: [
        {what: 'a tick that runs a dispatch one ms early', rule: windowRule({late: true}), steps: [windowLaws(windowRule({late: true})).steps[0]!], laws: windowLaws(windowRule({late: true})).laws},
        {what: 'a tick that runs a dispatch and keeps it pending', rule: windowRule({keepRan: true}), laws: [windowLaws(windowRule({keepRan: true})).laws[4]!]},
        {what: 'an enqueue that runs at once', rule: windowRule({runOnEnqueue: true}), steps: [windowLaws(windowRule({runOnEnqueue: true})).steps[0]!], laws: windowLaws(windowRule({runOnEnqueue: true})).laws},
      ],
      held: [{against: 'Core.step on every message (rule run beside it, maps compared)', run: windowHeld}],
    }
  })(),
]
