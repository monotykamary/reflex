// The inbox: when a poll makes a card (core.change) and how long a card
// lives (core.itemLiveOf), as gdp-wired decisions held to the real functions
// on every combination of what they read.

import {bool, fun, no, oneOf, when} from 'gdp-wired'
import * as Core from '../src/core.ts'
import type {Agent, Sort, Status} from '../src/model.ts'
import type {Entry} from './kit.ts'

const STATUS = ['idle', 'working', 'blocked', 'finished', 'unknown'] as const
const SORTS = ['ask', 'ready', 'reply', 'route', 'note'] as const

// change(prev, cur): `seen` (a previous view of the pane), what it was and is,
// whether its seq stayed, whether the question on screen stayed the same.
const changeFun = (sloppy = false) =>
  fun('change')
    .inputs({seen: bool, was: oneOf(...STATUS), now: oneOf(...STATUS), sameSeq: bool, sameAsk: bool})
    .returns(({seen, was, now, sameSeq, sameAsk}) => {
      const same = sloppy ? sameSeq.and(sameAsk) : seen.and(was.is('blocked')).and(sameSeq).and(sameAsk)
      return {
        blocked: now.is('blocked').and(same.not()),
        finished: now.is('blocked').not().and(seen).and(was.is('working')).and(now.is('idle').or(now.is('finished'))),
      }
    })

const change = changeFun()
const newBlockedAsks = change.law('new_blocked_agent_asks: a newly seen agent that is blocked asks you', ({seen, now}) => [seen.not(), now.is('blocked')], ({blocked}) => blocked)
const finishedReports = change.law(
  'finished_turn_reports: a working agent that becomes ready reports a finished turn',
  ({seen, was, now}) => [seen, was.is('working'), now.is('idle')],
  ({finished}) => finished,
)
const sameQuestion = change.law(
  'the same question, still asked, is not asked again',
  ({seen, was, now, sameSeq, sameAsk}) => [seen, was.is('blocked'), now.is('blocked'), sameSeq, sameAsk],
  ({blocked, finished}) => blocked.not().and(finished.not()),
)
const brokenChange = changeFun(true).law('new_blocked_agent_asks: a newly seen agent that is blocked asks you', ({seen, now}) => [seen.not(), now.is('blocked')], ({blocked}) => blocked)

const ASK_A = 'Proceed?\n❯ 1. Yes\n  2. No'
const ASK_B = 'Overwrite it?\n❯ 1. Overwrite\n  2. Keep both\n  3. Skip'
const agent = (status: Status, seq: number, screen: string): Agent => ({pane: 't1', name: 'a', kind: 'claude', status, cwd: '/w', title: '', seq, session: '', screen, parent: ''})

const changeHeld = () =>
  change.compare(({seen, was, now, sameSeq, sameAsk}) => {
    const prev = seen ? agent(was as Status, 7, ASK_A) : undefined
    const c = Core.change(prev, agent(now as Status, sameSeq ? 7 : 8, sameAsk ? ASK_A : ASK_B))
    return {blocked: c === 'blocked', finished: c === 'finished'}
  })

// itemLiveOf(kind, here): a card's kind, whether its agent is still listed,
// and that agent's status.
const liveFun = (sloppy = false) =>
  fun('item live')
    .inputs({kind: oneOf(...SORTS), here: bool, status: oneOf(...STATUS)})
    .returns(({kind, here, status}) => ({
      live: when(kind.is('ask'), sloppy ? here : here.and(status.is('blocked')), when(kind.is('ready'), here.and(status.is('working').not()), kind.is('ask').not())),
    }))

const live = liveFun()
const answeredClears = live.law(
  'answered_question_clears: a question card goes once its agent is no longer blocked',
  ({kind, status}) => [kind.is('ask'), status.is('blocked').not()],
  ({live}) => live.not(),
)
const goneClears = live.law('a card about an agent goes when the agent does', ({kind, here}) => [kind.is('ask').or(kind.is('ready')), here.not()], ({live}) => live.not())
const askStays = live.law('a question card stays while its agent is blocked', ({kind, here, status}) => [kind.is('ask'), here, status.is('blocked')], ({live}) => live)
const brokenLive = liveFun(true).law(
  'answered_question_clears: a question card goes once its agent is no longer blocked',
  ({kind, status}) => [kind.is('ask'), status.is('blocked').not()],
  ({live}) => live.not(),
)

const liveHeld = () => live.compare(({kind, here, status}) => ({live: Core.itemLiveOf(kind as Sort, here ? agent(status as Status, 1, '') : undefined)}))

void no

export const entries: Entry[] = [
  {
    area: 'the inbox',
    decisions: [newBlockedAsks, finishedReports, sameQuestion],
    broken: [{what: 'a change that takes any repeated question for the same ask, seen before or not', decision: brokenChange}],
    held: [{against: 'Core.change (fun.compare, every combination)', run: changeHeld, exhaustive: true}],
  },
  {
    area: 'the inbox',
    decisions: [answeredClears, goneClears, askStays],
    broken: [{what: 'a question card kept while its agent is listed, blocked or not', decision: brokenLive}],
    held: [{against: 'Core.itemLiveOf (fun.compare, every combination)', run: liveHeld, exhaustive: true}],
  },
]
