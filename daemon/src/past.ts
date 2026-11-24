// Earlier agent conversations that could be resumed — Claude's, pi's and
// Codex's saved sessions, and Claude's background sessions. The app reads the
// harnesses' own session files and writes them to sessions.tsv, one line per
// session (sessions already live in herdr left out):
//
//   agent  id  cwd  title  last_prompt  age_hours  state  [profile]
//
// state: past (saved, not running) | background (a stopped `claude --bg`)
//        | running (a running `claude --bg`: attach to it)
//        | elsewhere (open in another terminal: fork it, never write twice)
// profile: the harness profile it was saved in (`reflex profile`), "" (or no
//          column, as older apps write it) for your own
//
// Parsing and ranking are pure. Jev is offered a short, relevant list: the
// request's words found in a session's title, last prompt or folder first,
// then recency.

import {bonus, machineOf, recency, tokens, weight} from './folders.ts'
import * as Js from './js.ts'
import {add32, lines, mul32, readU32, sortBy, toLower} from './str.ts'

export type Past = {agent: string; id: string; cwd: string; title: string; last: string; age: number; state: string; profile: string}

export function parse(tsv: string): Past[] {
  const out: Past[] = []
  for (const l of lines(tsv)) {
    const f = l.split('\t')
    if (f.length < 7) continue
    const [agent, id, cwd, title, last, age, state] = f as [string, string, string, string, string, string, string]
    out.push({agent, id, cwd, title, last, age: readU32(age) ?? 0, state, profile: f[7] ?? ''})
  }
  return out
}

function hits(toks: string[], hay: string): number {
  let n = 0
  for (let i = toks.length - 1; i >= 0; i--) n = add32(bonus(hay.includes(toks[i]!), weight(toks[i]!)), n)
  return n
}

type Scored = {score: number; age: number; p: Past}

const scoredLe = (a: Scored, b: Scored) => a.score > b.score || (a.score === b.score && a.age <= b.age)

// The k sessions most worth offering Jev for this request.
export function rank(text: string, xs: readonly Past[], k: number): Past[] {
  const toks = tokens(text)
  const scored = xs.map((p) => ({score: add32(mul32(hits(toks, toLower(p.title + ' ' + p.last + ' ' + p.cwd)), 4), recency(p.age)), age: p.age, p}))
  return sortBy(scored, scoredLe)
    .slice(0, Math.max(0, k))
    .map((s) => s.p)
}

// The sessions of one harness ("" for every harness); with a profile, only
// that profile's.
export const harness = (kind: string, xs: readonly Past[], profile = ''): Past[] =>
  xs.filter((p) => kind.length === 0 || (kind === p.agent && (profile.length === 0 || profile === p.profile)))

export const pastJson = (p: Past): string =>
  Js.obj([
    Js.kv('agent', Js.str(p.agent)),
    Js.kv('id', Js.str(p.id)),
    Js.kv('cwd', Js.str(p.cwd)),
    Js.kv('title', Js.str(p.title)),
    Js.kv('last', Js.str(p.last)),
    Js.kv('ageHours', Js.num(p.age)),
    Js.kv('state', Js.str(p.state)),
    ...(p.profile ? [Js.kv('profile', Js.str(p.profile))] : []),
  ])

// The sessions on machine m ("" for this Mac).
export const on = (m: string, xs: readonly Past[]): Past[] => xs.filter((p) => machineOf(p.cwd) === m)
