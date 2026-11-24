// Routing: when Jev's answer may act (route.decideTarget, decideFolderPick),
// when it may turn into a resume (withPast, promotePick), how a side question
// reaches an agent (sideFor), and how many folders Jev is offered (the take
// in folders.rankWords): gdp-wired decisions and a rule, held to the real
// functions on every combination of what they read.

import {bool, fun, nat, oneOf, rule, when} from 'gdp-wired'
import * as Ix from '../src/folders.ts'
import type {Agent, Folder} from '../src/model.ts'
import type {Past} from '../src/past.ts'
import * as R from '../src/route.ts'
import type {Entry} from './kit.ts'
import {rand} from './kit.ts'

const KINDS = ['claude', 'pi', 'other'] as const
const kindName = (k: string) => (k === 'other' ? 'codex' : k)

// The side channel for an agent's kind, blocked or not.
const sideFun = (sloppy = false) =>
  fun('side for')
    .inputs({kind: oneOf(...KINDS), blocked: bool})
    .returns(({kind, blocked}) => ({
      native: kind.is('claude').and(sloppy ? blocked.or(blocked.not()) : blocked.not()),
      forked: kind.is('claude').and(blocked).or(kind.is('pi')),
    }))
const side = sideFun()
const noNativeBtw = side.law('blocked_agent_gets_no_native_btw: a side question never types into a blocked agent', ({blocked}) => [blocked], ({native}) => native.not())
const sideHeld = () =>
  side.compare(({kind, blocked}) => {
    const s = R.sideFor(kindName(kind), blocked ? 'blocked' : 'idle')
    return {native: s === 'native', forked: s === 'forked'}
  })
// Any kind of text: only "claude" and "pi" have a side channel.
function sideAnyKind(): {checked: number; failure?: string} {
  const r = rand(21)
  const kinds = ['claude', 'pi', '', 'Claude', 'claude ', 'codex', 'amp', 'pi-fabric', 'é']
  let n = 0
  for (let t = 0; t < 3000; t++) {
    const k = r(3) === 0 ? kinds[r(kinds.length)]! : Array.from({length: r(7)}, () => String.fromCharCode(97 + r(26))).join('')
    for (const st of ['idle', 'working', 'blocked', 'finished', 'unknown'] as const) {
      const want = R.sideFor(k === 'claude' ? 'claude' : k === 'pi' ? 'pi' : 'codex', st)
      if (R.sideFor(k, st) !== want) return {checked: n, failure: `sideFor(${JSON.stringify(k)}, ${st})`}
      n++
    }
  }
  return {checked: n}
}

// decideTarget(sure, isNew, agent, ...): what Jev's session choice becomes.
//   hasAgent    its key names a live session
//   side        a side question (Jev's noul >= 50%, or "btw")
//   kind, blocked   that session's harness and state
//   folderPick  Jev chose a folder at all; folderSure, folderFound: sure of
//               it, and it names one
const targetFun = (sloppy = false) =>
  fun('decide target')
    .inputs({
      sure: bool,
      isNew: bool,
      hasAgent: bool,
      side: bool,
      kind: oneOf(...KINDS),
      blocked: bool,
      folderPick: bool,
      folderSure: bool,
      folderFound: bool,
    })
    .returns(({sure, isNew, hasAgent, side, kind, folderPick, folderSure, folderFound}) => {
      const agentGo = side.not().or(kind.is('other').not())
      const folderGo = folderPick.and(folderSure).and(folderFound)
      const toAgent = (sloppy ? isNew.not().and(hasAgent) : sure.and(isNew.not()).and(hasAgent))
      const toFolder = sure.and(isNew)
      return {
        go: toAgent.and(agentGo).or(toAgent.not().and(toFolder).and(folderGo)),
        broke: toAgent.not().and(toFolder).and(folderPick.not()),
      }
    })
const target = targetFun()
const unsureTarget = target.law('unsure_target_never_acts: Jev never acts on a session choice below the threshold', ({sure}) => [sure.not()], ({go}) => go.not())
const brokenTarget = targetFun(true).law('unsure_target_never_acts: Jev never acts on a session choice below the threshold', ({sure}) => [sure.not()], ({go}) => go.not())

const HOME = '/Users/me'
const FOLDER: Folder = {path: '/Users/me/VCS/app', name: 'app', desc: '', recent: '', branch: 'main', age: 3, uses: 1}
const live = (kind: string, blocked: boolean): Agent => ({pane: 't1', name: 'a', kind, status: blocked ? 'blocked' : 'idle', cwd: '/Users/me/VCS/app', title: '', seq: 1, session: 's', screen: '', parent: '', profile: ''})

const targetHeld = () =>
  target.compare(({sure, isNew, hasAgent, side, kind, blocked, folderPick, folderSure, folderFound}) => {
    const a = live(kindName(kind), blocked)
    const folder: R.Pick | undefined = folderPick ? {key: folderFound ? 'f0' : 'f7', bp: folderSure ? 9100 : 1200, all: [{key: 'f0', bp: 5000}]} : undefined
    const tgt: R.Pick = {key: isNew ? 'new' : 'a0', bp: sure ? 8000 : 2000, all: [{key: 'a0', bp: 4000}, {key: 'new', bp: 3000}]}
    const d = R.decideTarget(sure, isNew, hasAgent ? a : undefined, 'look at the logs', HOME, 'claude', 6000, [{agent: a, recent: ''}], [FOLDER], tgt, folder, side ? 9000 : 0)
    return {go: d.d === 'go', broke: d.d === 'broke'}
  })

// decideFolderPick(sure, folder, ...): Jev's folder choice.
const folderFun = (sloppy = false) =>
  fun('decide folder')
    .inputs({sure: bool, found: bool})
    .returns(({sure, found}) => ({go: sloppy ? found : sure.and(found)}))
const folder = folderFun()
const unsureFolder = folder.law('unsure_folder_never_acts: nor on a folder choice below the threshold', ({sure}) => [sure.not()], ({go}) => go.not())
const brokenFolder = folderFun(true).law('unsure_folder_never_acts: nor on a folder choice below the threshold', ({sure}) => [sure.not()], ({go}) => go.not())
const folderHeld = () =>
  folder.compare(({sure, found}) => ({go: R.decideFolderPick(sure, found ? FOLDER : undefined, 'fix it', HOME, 'claude', [], [FOLDER], undefined, undefined).d === 'go'}))

// withPast(sure, key, pasts, d): Jev's "resume an earlier conversation?" on
// top of the decision d. `live`: d already sends to a live session; `found`:
// the key names an earlier conversation.
const pastFun = (sloppy = false) =>
  fun('with past')
    .inputs({sure: bool, live: bool, found: bool})
    .returns(({sure, live, found}) => ({changed: sure.and(sloppy ? found : live.not().and(found))}))
const past = pastFun()
const unsureResume = past.law('unsure_resume_changes_nothing: unsure, the decision stays exactly what it was', ({sure}) => [sure.not()], ({changed}) => changed.not())
const liveBeats = past.law('live_session_beats_resume: a request going to a live session is never turned into a resume', ({live}) => [live], ({changed}) => changed.not())
const brokenPast = pastFun(true).law('live_session_beats_resume: a request going to a live session is never turned into a resume', ({live}) => [live], ({changed}) => changed.not())

const PAST: Past = {agent: 'claude', id: 'id0', cwd: '/Users/me/VCS/app', title: 'earlier', last: 'the thing', age: 2, state: 'past', profile: ''}
const decisions = (live: boolean): R.Decision[] =>
  live
    ? [
        {d: 'go', action: {type: 'prompt', pane: 't1', text: 'x'}, label: 'l', why: 'w'},
        {d: 'go', action: {type: 'btw', pane: 't1', text: 'x'}, label: 'l', why: 'w'},
        {d: 'go', action: {type: 'fork', pane: 't1', kind: 'pi', cwd: '/w', session: 's', text: 'x'}, label: 'l', why: 'w'},
      ]
    : [
        {d: 'go', action: {type: 'spawn', cwd: '/w', kind: 'claude', text: 'x'}, label: 'l', why: 'w'},
        {d: 'choose', title: 't', opts: [], why: 'w'},
        {d: 'broke', message: 'm'},
      ]
function pastHeld(): {checked: number; failure?: string; exhaustive?: boolean} {
  let checked = 0
  for (const d of [...decisions(true), ...decisions(false)]) {
    const isLive = R.liveGo(d)
    const a = past.compare(({sure, live, found}) => {
      // A row whose `live` isn't this decision's is another decision's: give
      // the rule's own answer there, and check the rows this one describes.
      if (live !== isLive) return {changed: sure && !live && found}
      const out = R.withPast(sure, found ? 'p0' : 'p3', [PAST], d, 'x')
      return {changed: out !== d && JSON.stringify(out) !== JSON.stringify(d)}
    })
    if (a.failure) return a
    checked += a.checked
  }
  return {checked, exhaustive: true}
}
// promotePick(live, m, d): with live set, never anything but d.
function promoteHeld(): {checked: number; failure?: string} {
  let n = 0
  for (const d of [...decisions(true), ...decisions(false)])
    for (const m of [PAST, undefined]) {
      if (R.promotePick(true, m, d, 'x') !== d) return {checked: n, failure: `promotePick(true, ${m?.id}, ${d.d})`}
      n++
    }
  return {checked: n}
}

// The k folders Jev is offered: rankWords keeps a candidate while it has
// kept fewer than k (folders.takes), one candidate a request.
const takeRule = (sloppy = false) =>
  rule('take')
    .params({k: nat})
    .state({n: 0})
    .step(({n, k}) => ({n: sloppy ? when(n.atMost(k), n.plus(1), n) : when(n.lt(k), n.plus(1), n)}))
const take = takeRule()
const bounded = take.law('rank_is_bounded: Jev is offered at most k folders', ({n, k}) => n.atMost(k))
const takeHeld = () =>
  take.compare({init: () => ({n: 0}), step: ({k}, st) => ({n: Ix.takes(st.n as number, k) ? (st.n as number) + 1 : (st.n as number)})}, {trials: 300, depth: 20, bound: 12})

const WORDS = ['pi-fabric', 'jev', 'fabric', 'herdr', 'app', 'fix', 'the', 'acme', 'studio.app', 'test', 'theme', 'é']
function rankAny(): {checked: number; failure?: string} {
  const r = rand(22)
  for (let t = 0; t < 3000; t++) {
    const fs: Folder[] = Array.from({length: r(14)}, (_, i) => ({
      path: '/Users/me/VCS/' + WORDS[r(WORDS.length)] + i,
      name: WORDS[r(WORDS.length)]!,
      desc: r(4) === 0 ? 'A collection of 3 repositories' : WORDS[r(WORDS.length)]!,
      recent: WORDS[r(WORDS.length)]!,
      branch: 'main',
      age: r(1000),
      uses: r(9),
    }))
    const text = Array.from({length: r(6)}, () => WORDS[r(WORDS.length)]).join(' ')
    const k = r(12)
    const got = Ix.rank(text, fs, k)
    if (got.length > k) return {checked: t, failure: `rank(${JSON.stringify(text)}, ${fs.length} folders, ${k}) gave ${got.length}`}
    if (got.some((f) => !fs.includes(f))) return {checked: t, failure: 'rank offered a folder it was not given'}
  }
  return {checked: 3000}
}

export const entries: Entry[] = [
  {
    area: 'routing',
    decisions: [unsureTarget],
    broken: [{what: 'a session choice acted on without being sure', decision: brokenTarget}],
    held: [{against: 'R.decideTarget (fun.compare, every combination)', run: targetHeld, exhaustive: true}],
  },
  {
    area: 'routing',
    decisions: [unsureFolder],
    broken: [{what: 'a folder choice acted on without being sure', decision: brokenFolder}],
    held: [{against: 'R.decideFolderPick (fun.compare, every combination)', run: folderHeld, exhaustive: true}],
  },
  {
    area: 'routing',
    decisions: [unsureResume, liveBeats],
    broken: [{what: 'a resume that overrides a live session', decision: brokenPast}],
    held: [
      {against: 'R.withPast on every kind of decision (fun.compare)', run: pastHeld},
      {against: 'R.promotePick(true, ...) on every kind of decision', run: promoteHeld},
    ],
  },
  {
    area: 'routing',
    decisions: [noNativeBtw],
    broken: [{what: 'claude always takes /btw, blocked or not', decision: sideFun(true).law('blocked_agent_gets_no_native_btw: a side question never types into a blocked agent', ({blocked}) => [blocked], ({native}) => native.not())}],
    held: [
      {against: 'R.sideFor (fun.compare, every combination)', run: sideHeld, exhaustive: true},
      {against: 'R.sideFor on any kind of text', run: sideAnyKind},
    ],
  },
  {
    area: 'routing',
    rule: take,
    laws: [bounded],
    from: 'any',
    broken: [{what: 'a take that keeps one past k', rule: takeRule(true), laws: [takeRule(true).law('rank_is_bounded: Jev is offered at most k folders', ({n, k}) => n.atMost(k))]}],
    held: [
      {against: 'folders.takes (rule.compare)', run: takeHeld},
      {against: 'folders.rank on random requests and folders', run: rankAny},
    ],
  },
]
