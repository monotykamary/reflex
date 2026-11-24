// The folder index: the folder candidates routing offers Jev when a request
// should start a new session. Parsing and ranking are pure; the facts come
// from scripts/reflex-scan.sh (one tab-separated line per folder).
//
// Ranking is deterministic and cheap, so Jev only ever chooses among a short,
// relevant list: folders named in the request first (pinned), then the best
// lexical matches, then recently active folders to fill the list.

import type {Folder} from './model.ts'
import {add32, drop, length, lines, mul32, readU32, reverse, sortBy, toLower} from './str.ts'

// Parsing
// -------

export function parse(tsv: string): Folder[] {
  const out: Folder[] = []
  for (const l of lines(tsv)) {
    const f = l.split('\t')
    if (f.length < 7) continue
    const [path, name, age, branch, uses, desc, recent] = f as [string, string, string, string, string, string, string]
    out.push({path, name, desc, recent, branch, age: readU32(age) ?? 0, uses: readU32(uses) ?? 0})
  }
  return out
}

// Tokens
// ------

const wordChar = (c: number) => (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c >= 128
const joiner = (c: number) => c === 45 || c === 46 || c === 95

const blank = (s: string) => Array.from(s, (ch) => (wordChar(ch.codePointAt(0)!) ? ch : ' ')).join('')
const blankKeeping = (s: string) =>
  Array.from(s, (ch) => {
    const c = ch.codePointAt(0)!
    return wordChar(c) || joiner(c) ? ch : ' '
  }).join('')

const STOP = new Set(
  'the an and or to in on of for with at by from it is this that be can you we me my our please fix add make run check update let lets us do does what how why where when into about some any all new use using also then now just get set see look there here btw hey so are was were start session repo project folder work working agent help should would could its not have has will need want like one two up out if as but too'.split(' '),
)

const keepToken = (w: string) => length(w) >= 2 && !STOP.has(w)
const filterTokens = (ws: string[]) => ws.filter(keepToken)

// "..x" -> "x"
function stripStart(s: string): string {
  let i = 0
  while (i < s.length && joiner(s.charCodeAt(i))) i++
  return s.slice(i)
}

// "pi-fabric." (the end of a sentence) -> "pi-fabric"
const strip = (w: string) => reverse(stripStart(reverse(stripStart(w))))

// Words
// -----
// The request's words as written. A joiner inside a word is part of a name:
// "pi-fabric" and "studio.app" stay whole, so "pi-fabric" names the folder
// pi-fabric and not every folder that starts with "pi-".
export const words = (text: string): string[] => filterTokens(blankKeeping(toLower(text)).split(' ').map(strip))

const isCompound = (w: string) => w.includes('-') || w.includes('.') || w.includes('_')

// What to look for in a folder's facts: each word, and a joined word's parts
// too ("pi-fabric" -> pi-fabric, pi, fabric).
export function expand(ws: string[]): string[] {
  const out: string[] = []
  for (const w of ws) {
    out.push(w)
    if (isCompound(w)) out.push(...filterTokens(blank(w).split(' ')))
  }
  return out
}

// The words of a request worth matching against folders.
export const tokens = (text: string): string[] => expand(words(text))

// A joined word is a name, and says more than one of its parts.
export const weight = (t: string): number => (isCompound(t) ? 3 : 1)

// Scoring
// -------

export const bonus = (hit: boolean, n: number): number => (hit ? n : 0)

function tokScore(tok: string, name: string, path: string, desc: string, recent: string): number {
  return add32(
    add32(add32(add32(bonus(name === tok, 12), bonus(name.includes(tok), 6)), bonus(path.includes(tok), 2)), bonus(desc.includes(tok), 2)),
    bonus(recent.includes(tok), 1),
  )
}

export const recency = (age: number): number => add32(add32(bonus(age < 24, 2), bonus(age < 168, 1)), bonus(age < 720, 1))

type Scored = {lexical: number; total: number; age: number; folder: Folder}

function score(toks: string[], f: Folder): Scored {
  const name = toLower(f.name)
  const path = toLower(f.path)
  const desc = toLower(f.desc)
  const recent = toLower(f.recent)
  let lex = 0
  for (let i = toks.length - 1; i >= 0; i--) lex = add32(tokScore(toks[i]!, name, path, desc, recent), lex)
  return {lexical: lex, total: add32(add32(mul32(lex, 4), recency(f.age)), Math.min(f.uses, 6)), age: f.age, folder: f}
}

const scoredLe = (a: Scored, b: Scored) => a.total > b.total || (a.total === b.total && a.age <= b.age)
const byAgeLe = (a: Scored, b: Scored) => a.age <= b.age

// A folder is named when a word of the request (as written: see Words) is its
// name, or the first part of it ("acme" names acme-web, "studio" studio.app).
const names = (name: string, t: string) =>
  name === t || name.startsWith(t + '-') || name.startsWith(t + '_') || name.startsWith(t + '.')

const isPinned = (toks: string[], s: Scored) => {
  const name = toLower(s.folder.name)
  return toks.some((t) => names(name, t))
}

// A folder holding many repositories (the scan describes it as "A collection
// of N repositories"): offered when named or matched, never just for being
// recent — its newest repo would put it on top of every request.
const isCollection = (s: Scored) => s.folder.desc.startsWith('A collection of')

// Whether a list that kept n so far keeps one more, within k.
export const takes = (n: number, k: number): boolean => n < k

// The first k of xs.
export function take<T>(xs: readonly T[], k: number): T[] {
  const out: T[] = []
  for (const x of xs) {
    if (!takes(out.length, k)) break
    out.push(x)
  }
  return out
}

export function rankWords(ws: string[], fs: readonly Folder[], k: number): Folder[] {
  const scored = fs.map((f) => score(expand(ws), f))
  const pinned: Scored[] = []
  const matched: Scored[] = []
  const others: Scored[] = []
  for (const s of scored) {
    if (isPinned(ws, s)) pinned.push(s)
    else if (0 < s.lexical) matched.push(s)
    else others.push(s)
  }
  const all = [
    ...sortBy(pinned, scoredLe),
    ...sortBy(matched, scoredLe),
    ...sortBy(
      others.filter((s) => !isCollection(s)),
      byAgeLe,
    ),
  ].map((s) => s.folder)
  return take(all, k)
}

// The k best folders for a request: named folders (the best match first),
// lexical matches, then the most recently active folders.
export const rank = (text: string, fs: readonly Folder[], k: number): Folder[] => rankWords(words(text), fs, k)

// Places on other Macs
// --------------------
// A folder or a session on another Mac has the path "<machine>:<path>",
// "work:/Users/you/VCS/app"; one on this Mac has its plain absolute path.
// Machine keys hold neither ':' nor '/'.

// The machine a path is on ("" for this Mac).
export const machineOf = (path: string): string => (path.startsWith('/') || path.length === 0 ? '' : path.split(':')[0]!)

// The path on its own machine: "work:/Users/you/VCS/app" -> /Users/you/VCS/app.
export function pathOn(path: string): string {
  const m = machineOf(path)
  return m.length === 0 ? path : drop(path, 1 + length(m))
}

// A path on machine m ("" for this Mac).
export const place = (m: string, path: string): string => (m.length === 0 ? path : m + ':' + path)

// The machine of a pane id ("work/w1:p2"; "" for this Mac's "w1:p2").
export function paneMachine(pane: string): string {
  const parts = pane.split('/')
  return parts.length >= 2 ? parts[0]! : ''
}

// The folders on machine m ("" for this Mac).
export const on = (m: string, fs: readonly Folder[]): Folder[] => fs.filter((f) => machineOf(f.path) === m)
