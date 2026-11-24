// Route: turns a request plus what reflexd can see into one typed Jev call,
// and Jev's typed answer into a decision. Jev never writes text and never
// invents a target: it picks keys from candidate lists built here, and every
// key maps back to a candidate or the request goes to the inbox as a question.
// Pure: no IO.

import {machineOf, paneMachine, pathOn, place} from './folders.ts'
import * as Js from './js.ts'
import type {J, Res} from './js.ts'
import type {Action, Agent, Folder, Opt, Status} from './model.ts'
import {actionJson, optJsons, showStatus} from './model.ts'
import type {Past} from './past.ts'
import {add32, div32, drop, isEmpty, length, lines, mul32, orElse, showU32, sortBy, take, toLower, trim, trimEnd, trimStart} from './str.ts'

// An agent offered to Jev, with a little of what its pane shows.
export type Seen = {agent: Agent; recent: string}

export type Decision =
  // act (after the undo window)
  | {d: 'go'; action: Action; label: string; why: string}
  // not confident: ask, offering numbered options
  | {d: 'choose'; title: string; opts: Opt[]; why: string}
  // routing could not run
  | {d: 'broke'; message: string}

// Text helpers
// ------------

// /Users/x/VCS/a -> ~/VCS/a when `home` is /Users/x
const shortHere = (home: string, path: string) =>
  path.startsWith(home) && !isEmpty(home) ? '~' + drop(path, length(home)) : path

// /Users/you/VCS/a -> ~/VCS/a: a path under its own Mac's home.
export function tilde(path: string): string {
  const parts = path.split('/')
  if (parts.length >= 3 && parts[1] === 'Users' && !isEmpty(parts[2]!)) return '~' + parts.slice(3).map((p) => '/' + p).join('')
  return path
}

// A path as Jev reads it: ~/VCS/a here, work:~/VCS/a on another Mac.
export const short = (home: string, path: string): string =>
  isEmpty(machineOf(path)) ? shortHere(home, path) : machineOf(path) + ':' + tilde(pathOn(path))

export const clip = (s: string, n: number): string => (length(s) > n ? take(s, n) + '…' : s)

const idx = (prefix: string, i: number) => prefix + String(i)

// blank, or a horizontal rule drawn by a TUI
function isRuleLine(s: string): boolean {
  for (const ch of s) {
    const c = ch.codePointAt(0)!
    if (!(c === 9472 || c === 9473 || c === 45 || c === 61 || c === 32)) return false
  }
  return true
}

const nonblank = (ls: string[]): string[] => ls.filter((h) => !isRuleLine(trim(h))).map(trimEnd)

function lastLines(t: string, n: number): string {
  const xs = nonblank(lines(t))
  return xs.slice(Math.max(0, xs.length - n)).join('\n')
}

const indent = (ls: string[]) => ls.map((h) => '    | ' + h + '\n').join('')

const titlePart = (title: string) => (isEmpty(title) ? '' : ', title: ' + clip(title, 80))

// The state Jev reads
// -------------------

const agentLine = (home: string, i: number, s: Seen) => {
  const a = s.agent
  return (
    idx('a', i) +
    ': ' +
    a.kind +
    ' agent in ' +
    short(home, place(paneMachine(a.pane), a.cwd)) +
    ' (' +
    showStatus(a.status) +
    ')' +
    titlePart(a.title) +
    '\n' +
    indent(lines(lastLines(s.recent, 6)))
  )
}

const descPart = (d: string) => (isEmpty(d) ? '' : '. ' + clip(d, 160))
const recentPart = (r: string) => (isEmpty(r) ? '' : '. Recent commits: ' + clip(r, 160))

// When the folder was last worked on (its last commit), and how often the user
// has started sessions there: when a request names no project, the folder the
// user has been in lately is the likelier one.
function agePart(age: number): string {
  const ago = age < 1 ? 'within the hour' : age < 48 ? showU32(age) + ' hours ago' : showU32(div32(age, 24)) + ' days ago'
  return ' Last worked on ' + ago + '.'
}

const usesPart = (n: number) => (n === 0 ? '' : ' The user started ' + showU32(n) + ' sessions here before.')

const folderLine = (home: string, i: number, f: Folder) =>
  idx('f', i) + ': ' + f.name + ' — ' + short(home, f.path) + descPart(f.desc) + recentPart(f.recent) + agePart(f.age) + usesPart(f.uses) + '\n'

const section = (title: string, body: string) => (isEmpty(body) ? '' : '\n' + title + '\n' + body)

// An earlier conversation, as Jev reads it.
const pastLine = (home: string, i: number, p: Past) =>
  idx('p', i) +
  ': ' +
  p.agent +
  ' conversation ' +
  Js.str(p.title) +
  ' in ' +
  short(home, p.cwd) +
  ',' +
  agePart(p.age) +
  ' Last asked: ' +
  Js.str(clip(p.last, 160)) +
  '\n'

// `memory`: what the user sent where lately, and where they corrected a
// pick for a similar request (written by the app; may be empty).
export function stateText(text: string, home: string, seen: Seen[], folders: Folder[], pasts: Past[], memory: string): string {
  return (
    'The user said: ' +
    Js.str(text) +
    '\n' +
    section('Live coding-agent sessions (terminal panes):', seen.map((s, i) => agentLine(home, i, s)).join('')) +
    section('Folders where a new session could be started:', folders.map((f, i) => folderLine(home, i, f)).join('')) +
    section('Earlier conversations, not running, that could be resumed:', pasts.map((p, i) => pastLine(home, i, p)).join('')) +
    section('What the user did before (use it for follow-ups and to follow their corrections):', memory)
  )
}

// Questions
// ---------

const agentChoices = (xs: Seen[], home: string): string[] => [
  ...xs.map((s, i) => Js.kv(idx('a', i), Js.str(s.agent.kind + ' in ' + short(home, place(paneMachine(s.agent.pane), s.agent.cwd)) + titlePart(s.agent.title)))),
  Js.kv('new', Js.str('none of these sessions: start a new session in a folder')),
]

const folderChoices = (xs: Folder[], home: string): string[] =>
  xs.map((f, i) => Js.kv(idx('f', i), Js.str(f.name + ' (' + short(home, f.path) + ')')))

const pastChoices = (xs: Past[], home: string): string[] => [
  ...xs.map((p, i) => Js.kv(idx('p', i), Js.str(p.agent + ' conversation ' + p.title + ' (' + short(home, p.cwd) + ')'))),
  Js.kv('none', Js.str('none: this is new work, even if it is in the same project')),
]

const question = (name: string, type: string, instructions: string, criteria?: string[]) =>
  Js.kv(
    name,
    Js.obj([
      Js.kv('type', Js.str(type)),
      Js.kv('instructions', Js.str(instructions)),
      ...(criteria ? [Js.kv('criteria', Js.obj(criteria))] : []),
    ]),
  )

const TARGET =
  "Which live session is the user's request meant for? Match the project, files and topic the user mentions against each session's folder, title and recent output. Choose new when the request is about a different project or no session fits. If the request follows on from something the user just sent (also, that, there, again, the same, or the same topic), choose the session it went to. Where the user corrected an earlier pick for a similar request, choose what they chose."
const FOLDER =
  'If a new session is started for this request, which folder is the request about? Prefer a folder the user names; otherwise the folder whose name, description or recent commits match the request. A folder that holds several repositories is their parent: choose it when the request spans more than one of the repositories it holds, or names the parent itself; choose the single repository when the request is about one. A collection of many repositories is chosen only when the user names it or the work is about the whole collection. When several fit about equally, or the request names no project, prefer the one worked on most recently. Where the user corrected an earlier pick for a similar request, choose what they chose.'
const SIDE =
  "Is this a quick side question about what an agent is doing or has done (like 'btw, why did you...?', 'what does X mean?'), to be answered without interrupting or redirecting the agent's work? Answer no for new instructions or tasks."
const RESUME =
  'Does the user want to go back to one of these earlier conversations? Choose one only when the request clearly continues that specific earlier work — it says continue, resume, back to, finish, or names the same task and topic. A new task, even in the same project, is none. When unsure, choose none.'

export function questions(home: string, seen: Seen[], folders: Folder[], pasts: Past[]): string[] {
  return [
    ...(seen.length > 0 ? [question('target', 'choice', TARGET, agentChoices(seen, home)), question('side', 'noul', SIDE)] : []),
    ...(folders.length > 0 ? [question('folder', 'choice', FOLDER, folderChoices(folders, home))] : []),
    ...(pasts.length > 0 ? [question('resume', 'choice', RESUME, pastChoices(pasts, home))] : []),
  ]
}

// One `jev` request line for `jev-fabric -- serve`.
export function request(text: string, home: string, seen: Seen[], folders: Folder[], pasts: Past[], memory: string): string {
  return (
    Js.obj([
      Js.kv('id', '1'),
      Js.kv('op', Js.str('jev')),
      Js.kv(
        'request',
        Js.obj([Js.kv('state', Js.str(stateText(text, home, seen, folders, pasts, memory))), Js.kv('questions', Js.obj(questions(home, seen, folders, pasts)))]),
      ),
    ]) + '\n'
  )
}

// Reading Jev's answer
// --------------------

// Basis points (0..10000) of a JSON probability lexeme such as "0.97", "1.0",
// "1" or "3e-05" (any negative exponent reads as 0).
function frac(s: string, scale: number): number {
  const cs = Array.from(s)
  let acc = 0
  const scales: number[] = []
  let sc = scale
  for (let i = 0; i < cs.length; i++) {
    scales.push(sc)
    sc = div32(sc, 10)
  }
  // frac(c :: t, scale) = digit(c) ? v * scale + frac(t, scale / 10) : 0
  for (let i = cs.length - 1; i >= 0; i--) {
    const c = cs[i]!.codePointAt(0)!
    acc = c >= 48 && c <= 57 ? add32(mul32(c - 48, scales[i]!), acc) : 0
  }
  return acc
}

function bpInt(lex: string): number {
  if (lex.length === 0) return 0
  const c = lex.codePointAt(0)!
  if (c === 49) return 10000
  if (c !== 48) return 0
  const t = Array.from(lex).slice(1)
  if (t.length === 0) return 0
  return t[0] === '.' ? frac(t.slice(1).join(''), 1000) : 0
}

export const bpOf = (lex: string): number => (lex.includes('e-') || lex.includes('E-') ? 0 : bpInt(lex))

// A choice answer: the picked key, its probability (bp), and every key's bp.
export type Prob = {key: string; bp: number}
export type Pick = {key: string; bp: number; all: Prob[]}

const probs = (m: J | undefined): Prob[] => (m?.t === 'obj' ? m.fields.map(([name, v]) => ({key: name, bp: bpOf(Js.textOf(v))})) : [])

export function lookupBp(xs: Prob[], key: string): number {
  for (const p of xs) if (p.key === key) return p.bp
  return 0
}

function pickOf(ans: J): Pick {
  const all = probs(Js.get(ans, 'probabilities'))
  const key = Js.textAt(ans, 'choice')
  return {key, bp: lookupBp(all, key), all}
}

export function pick(answers: J, name: string): Pick | undefined {
  const a = Js.get(answers, name)
  return a === undefined ? undefined : pickOf(a)
}

export const noulBp = (answers: J): number => bpOf(Js.textOf(Js.path(['side', 'noul'], answers)))

// The answers object of a serve response line, or the error it reports.
function answersOf(v: J): Res<J> {
  const a = Js.path(['result', 'answers'], v)
  if (Js.asBool(Js.get(v, 'ok')) && a !== undefined) return Js.done(a)
  return Js.fail(1, 'jev: ' + orElse(Js.textOf(Js.path(['error', 'message'], v)), orElse(Js.textAt(v, 'error'), 'no answers')))
}


// The serve output: a banner line, then one response line.
export function response(out: string): Res<J> {
  const ls = nonblank(lines(out))
  if (ls.length < 2) return Js.fail(1, 'jev-fabric: no response')
  const r = Js.read(ls[1]!)
  return r.ok ? answersOf(r.v) : r
}

// Deciding
// --------

const HARNESSES = ['claude', 'codex', 'pi', 'grok', 'opencode', 'amp', 'agy', 'cursor', 'droid', 'copilot', 'omp', 'kimi']

// The harness for a new session: one the user names, else the default.
export function harness(text: string, dflt: string): string {
  for (const t of toLower(text).split(' ')) if (HARNESSES.includes(t)) return t
  return dflt
}

export const forcedSide = (text: string): boolean => toLower(trim(text)).startsWith('btw') || trim(text).startsWith('/btw')

// "btw, why x" -> "why x"; other text unchanged
export function sideText(text: string): string {
  const t = trim(text)
  if (!forcedSide(text)) return t
  const noSlash = t.startsWith('/') ? t.slice(1) : t
  const rest = drop(noSlash, 3)
  const noPunct = rest.startsWith(',') || rest.startsWith(':') ? rest.slice(1) : rest
  return trimStart(noPunct)
}

// How a side question reaches an agent without interrupting it.
//   claude: its native /btw (no tools, shares the prompt cache) while it can
//           take input; when blocked on a dialog, a headless forked session
//   pi:     a headless fork of its session (`pi --fork`), same cached prefix
//   others: no safe side channel: ask the user instead
export type Side = 'native' | 'forked' | 'none'

export function sideForOf(claude: boolean, pi: boolean, blocked: boolean): Side {
  if (claude) return blocked ? 'forked' : 'native'
  return pi ? 'forked' : 'none'
}

export const sideFor = (kind: string, status: Status): Side => sideForOf(kind === 'claude', kind === 'pi', status === 'blocked')

// The last path component: /a/b/herdr -> herdr
export function leaf(path: string): string {
  let last = path
  for (const h of path.split('/')) if (!isEmpty(h)) last = h
  return last
}

const labelAgent = (kind: string, cwd: string) => kind + ' · ' + leaf(cwd)

function sideDecision(side: Side, a: Agent, text: string, dflt: string): Decision {
  if (side === 'native') return {d: 'go', action: {type: 'btw', pane: a.pane, text}, label: 'btw → ' + labelAgent(a.kind, a.cwd), why: 'side question; native /btw'}
  if (side === 'forked')
    return {
      d: 'go',
      action: {type: 'fork', pane: a.pane, kind: a.kind, cwd: a.cwd, session: a.session, text},
      label: 'btw → fork of ' + labelAgent(a.kind, a.cwd),
      why: 'side question; forked session',
    }
  return {
    d: 'choose',
    title: 'No side channel for ' + a.kind + ': how should this go?',
    opts: [
      {key: '1', label: 'send to ' + labelAgent(a.kind, a.cwd) + ' as a prompt', action: {type: 'prompt', pane: a.pane, text}},
      {key: '2', label: 'ask a new ' + dflt + ' session in ' + leaf(a.cwd), action: {type: 'spawn', cwd: a.cwd, kind: dflt, text}},
    ],
    why: 'side question for a harness without /btw or fork',
  }
}

export function agentDecision(side: boolean, a: Agent, text: string, _home: string, dflt: string): Decision {
  if (side) return sideDecision(sideFor(a.kind, a.status), a, sideText(text), dflt)
  return {d: 'go', action: {type: 'prompt', pane: a.pane, text}, label: '→ ' + labelAgent(a.kind, a.cwd), why: 'routed to a live session'}
}

const spawnDecision = (f: Folder, text: string, dflt: string): Decision => ({
  d: 'go',
  action: {type: 'spawn', cwd: f.path, kind: harness(text, dflt), text},
  label: 'new ' + harness(text, dflt) + ' in ' + leaf(f.path),
  why: 'new session in a folder',
})

function nth<T>(xs: readonly T[], key: string, prefix: string): T | undefined {
  for (let i = 0; i < xs.length; i++) if (key === idx(prefix, i)) return xs[i]
  return undefined
}

// Options for an unsure route: every candidate Jev gave weight to, best first.
export type Ranked = {bp: number; label: string; action: Action}

const rankedLe = (a: Ranked, b: Ranked) => a.bp >= b.bp

const seenRanked = (xs: Seen[], all: Prob[], text: string): Ranked[] =>
  xs.map((s, i) => ({bp: lookupBp(all, idx('a', i)), label: '→ ' + labelAgent(s.agent.kind, s.agent.cwd), action: {type: 'prompt', pane: s.agent.pane, text}}))

const folderRanked = (xs: Folder[], all: Prob[], newBp: number, text: string, dflt: string): Ranked[] =>
  xs.map((f, i) => ({
    bp: div32(mul32(lookupBp(all, idx('f', i)), Math.max(newBp, 1)), 10000),
    label: 'new ' + harness(text, dflt) + ' in ' + leaf(f.path),
    action: {type: 'spawn', cwd: f.path, kind: harness(text, dflt), text},
  }))

function optsOf(xs: Ranked[], n: number): Opt[] {
  return xs.slice(0, n).map((r, i) => ({key: showU32(i + 1), label: r.label + ' (' + showU32(div32(r.bp, 100)) + '%)', action: r.action}))
}

const allOf = (m: Pick | undefined): Prob[] => (m ? m.all : [])

// How much Jev leans to "new session" (all of it when there are no agents).
const newWeight = (m: Pick | undefined): number => (m ? lookupBp(m.all, 'new') : 10000)

// Keep the two best options, then only those Jev gave at least 3%.
const worth = (xs: Ranked[]): Ranked[] => xs.filter((r, kept) => kept < 2 || r.bp >= 300)

function choose(target: Pick | undefined, folder: Pick | undefined, seen: Seen[], folders: Folder[], text: string, dflt: string, why: string): Decision {
  const ranked = sortBy([...seenRanked(seen, allOf(target), text), ...folderRanked(folders, allOf(folder), newWeight(target), text, dflt)], rankedLe)
  return {d: 'choose', title: 'Where should this go?', opts: optsOf(worth(ranked), 4), why}
}

const confident = (bp: number, threshold: number) => bp >= threshold

export function decideFolderPick(
  sure: boolean,
  m: Folder | undefined,
  text: string,
  _home: string,
  dflt: string,
  seen: Seen[],
  folders: Folder[],
  target: Pick | undefined,
  folder: Pick | undefined,
): Decision {
  if (sure && m) return spawnDecision(m, text, dflt)
  return choose(target, folder, seen, folders, text, dflt, 'folder choice below the confidence threshold')
}

function decideFolder(m: Pick | undefined, text: string, home: string, dflt: string, threshold: number, seen: Seen[], folders: Folder[], target: Pick | undefined, folder: Pick | undefined): Decision {
  if (!m) return {d: 'broke', message: 'nothing to route to: no live sessions and no indexed folders'}
  return decideFolderPick(confident(m.bp, threshold), nth(folders, m.key, 'f'), text, home, dflt, seen, folders, target, folder)
}

export function decideTarget(
  sure: boolean,
  isNew: boolean,
  agent: Agent | undefined,
  text: string,
  home: string,
  dflt: string,
  threshold: number,
  seen: Seen[],
  folders: Folder[],
  target: Pick | undefined,
  folder: Pick | undefined,
  side: number,
): Decision {
  if (sure && !isNew && agent) return agentDecision(side >= 5000 || forcedSide(text), agent, text, home, dflt)
  if (sure && isNew) return decideFolder(folder, text, home, dflt, threshold, seen, folders, target, folder)
  return choose(target, folder, seen, folders, text, dflt, 'session choice below the confidence threshold')
}

// The decision for a request.
//   side   - Jev's noul that this is a side question (bp), or forced by "btw"
//   target - Jev's choice among live sessions (absent when there are none)
//   folder - Jev's choice among folders (absent when there are none)
export function decide(text: string, home: string, dflt: string, threshold: number, seen: Seen[], folders: Folder[], target: Pick | undefined, folder: Pick | undefined, side: number): Decision {
  if (target)
    return decideTarget(confident(target.bp, threshold), target.key === 'new', nth(seen, target.key, 'a')?.agent, text, home, dflt, threshold, seen, folders, target, folder, side)
  return decideFolder(folder, text, home, dflt, threshold, seen, folders, target, folder)
}

// Resuming an earlier conversation
// --------------------------------

// The agent's own arguments to bring a session back (mode "continue": the
// folder's latest, for an agent whose id we never had).
export function resumeArgs(kind: string, mode: string, id: string): string[] {
  if (mode === 'continue') return kind === 'codex' ? ['resume', '--last'] : ['--continue']
  // agy names a conversation to resume with --conversation (it has no fork).
  if (kind === 'agy') return ['--conversation', id]
  if (kind === 'claude') return mode === 'attach' ? ['attach', id] : mode === 'fork' ? ['--resume', id, '--fork-session'] : ['--resume', id]
  if (kind === 'pi') return mode === 'fork' ? ['--fork', id] : ['--session', id]
  if (kind === 'codex') return ['resume', id]
  return ['--resume', id]
}

// A separate question, defaulting to "none", and a step after the decision:
// it may turn the decision into a resume only when Jev is sure, and never
// when a live session already won (sending there is the stronger reading).

const modeOf = (state: string) => (state === 'running' ? 'attach' : state === 'elsewhere' ? 'fork' : 'resume')

export const resumeAction = (p: Past, text: string): Action => ({type: 'resume', cwd: p.cwd, kind: p.agent, session: p.id, mode: modeOf(p.state), text})

export const resumeLabel = (p: Past): string => 'resume ' + p.agent + ' · ' + clip(p.title, 48)

// A decision that already sends to a live session.
export const liveGo = (d: Decision): boolean => d.d === 'go' && (d.action.type === 'prompt' || d.action.type === 'btw' || d.action.type === 'fork')

export function promotePick(live: boolean, m: Past | undefined, d: Decision, text: string): Decision {
  if (live || !m) return d
  return {d: 'go', action: resumeAction(m, text), label: resumeLabel(m), why: 'continues an earlier conversation'}
}

export function withPast(sure: boolean, key: string, pasts: Past[], d: Decision, text: string): Decision {
  if (!sure) return d
  return promotePick(liveGo(d), nth(pasts, key, 'p'), d, text)
}

export function decideWithPast(
  resume: Pick | undefined,
  text: string,
  home: string,
  dflt: string,
  threshold: number,
  seen: Seen[],
  folders: Folder[],
  pasts: Past[],
  target: Pick | undefined,
  folder: Pick | undefined,
  side: number,
): Decision {
  return withPast(confident(resume ? resume.bp : 0, threshold), resume ? resume.key : 'none', pasts, decide(text, home, dflt, threshold, seen, folders, target, folder, side), text)
}

// The decision for a raw `jev-fabric -- serve` output.
export function decideOutput(out: string, text: string, home: string, dflt: string, threshold: number, seen: Seen[], folders: Folder[], pasts: Past[]): Decision {
  const r = response(out)
  if (!r.ok) return {d: 'broke', message: r.msg}
  const a = r.v
  return decideWithPast(pick(a, 'resume'), text, home, dflt, threshold, seen, folders, pasts, pick(a, 'target'), pick(a, 'folder'), noulBp(a))
}

// JSON of a decision, for the route response.
export function decisionJson(d: Decision): string {
  const {kv, str, obj, arr} = Js
  switch (d.d) {
    case 'go':
      return obj([kv('decision', str('go')), kv('label', str(d.label)), kv('why', str(d.why)), kv('action', actionJson(d.action))])
    case 'choose':
      return obj([kv('decision', str('choose')), kv('title', str(d.title)), kv('why', str(d.why)), kv('options', arr(optJsons(d.opts)))])
    case 'broke':
      return obj([kv('decision', str('error')), kv('error', str(d.message))])
  }
}

// Jev's transport failed (network, interruption): worth one retry.
export const transient = (d: Decision): boolean => d.d === 'broke' && d.message.includes('transport')

export const isGo = (d: Decision): boolean => d.d === 'go'

// Live candidates, for a search list
// ----------------------------------
// Every session and folder Jev weighed, best first, with Jev's own decision
// and its side-question score: the Ask bar shows these as you type and lets
// you pick another row. Nothing is sent.

const rankedJson = (r: Ranked) => Js.obj([Js.kv('bp', Js.num(r.bp)), Js.kv('label', Js.str(r.label)), Js.kv('action', actionJson(r.action))])

const pastRanked = (xs: Past[], all: Prob[], text: string): Ranked[] =>
  xs.map((p, i) => ({bp: lookupBp(all, idx('p', i)), label: resumeLabel(p), action: resumeAction(p, text)}))

function rankedAll(target: Pick | undefined, folder: Pick | undefined, resume: Pick | undefined, seen: Seen[], folders: Folder[], pasts: Past[], text: string, dflt: string): Ranked[] {
  return sortBy(
    [...seenRanked(seen, allOf(target), text), ...folderRanked(folders, allOf(folder), newWeight(target), text, dflt), ...pastRanked(pasts, allOf(resume), text)],
    rankedLe,
  )
}

export function candidatesOutput(out: string, text: string, home: string, dflt: string, threshold: number, seen: Seen[], folders: Folder[], pasts: Past[], ms: number): string {
  const r = response(out)
  if (!r.ok) return Js.obj([Js.kv('ok', 'false'), Js.kv('error', Js.str(r.msg)), Js.kv('ms', Js.num(ms))])
  const a = r.v
  const target = pick(a, 'target')
  const folder = pick(a, 'folder')
  const resume = pick(a, 'resume')
  const side = noulBp(a)
  return Js.obj([
    Js.kv('ok', 'true'),
    Js.kv('ms', Js.num(ms)),
    Js.kv('side', Js.num(side)),
    Js.kv('threshold', Js.num(threshold)),
    Js.kv('harness', Js.str(dflt)),
    Js.kv('decision', decisionJson(decideWithPast(resume, text, home, dflt, threshold, seen, folders, pasts, target, folder, side))),
    Js.kv('ranked', Js.arr(rankedAll(target, folder, resume, seen, folders, pasts, text, dflt).map(rankedJson))),
  ])
}
