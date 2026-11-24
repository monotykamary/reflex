// Text and numbers as reflexd has always read them.
//
// A string is a sequence of Unicode scalars (not UTF-16 units): lengths,
// take and drop count characters. Whitespace is ASCII's (space, tab, LF, VT,
// FF, CR), and lower case is ASCII's: "É" stays "É". Numbers that the API
// carries are 32-bit unsigned, and arithmetic on them wraps, as it did.

export const u32 = (n: number): number => n >>> 0

export const add32 = (a: number, b: number): number => (a + b) >>> 0
export const sub32 = (a: number, b: number): number => (a - b) >>> 0
export const mul32 = (a: number, b: number): number => Math.imul(a, b) >>> 0
export const div32 = (a: number, b: number): number => (b === 0 ? 0 : Math.floor((a >>> 0) / (b >>> 0)) >>> 0)

// Digits only, at least one, and the value fits in 32 bits.
export function readU32(s: string): number | null {
  if (s.length === 0) return null
  let acc = 0
  for (const ch of s) {
    const x = ch.codePointAt(0)!
    const n = add32(mul32(acc, 10), sub32(x, 48))
    if (div32(n, 10) !== acc) return null
    acc = n
  }
  return acc
}

export const showU32 = (n: number): string => String(n >>> 0)

const isSpace = (c: number) => c === 32 || (c >= 9 && c <= 13)

export function trimStart(s: string): string {
  let i = 0
  while (i < s.length && isSpace(s.charCodeAt(i))) i++
  return i === 0 ? s : s.slice(i)
}

export function trimEnd(s: string): string {
  let j = s.length
  while (j > 0 && isSpace(s.charCodeAt(j - 1))) j--
  return j === s.length ? s : s.slice(0, j)
}

export const trim = (s: string): string => trimEnd(trimStart(s))

export const toLower = (s: string): string => s.replace(/[A-Z]+/g, (m) => m.toLowerCase())

export const chars = (s: string): string[] => Array.from(s)

export function length(s: string): number {
  let n = 0
  for (const _ of s) n++
  return n
}

export function take(s: string, n: number): string {
  if (n <= 0) return ''
  let out = ''
  let i = 0
  for (const ch of s) {
    if (i++ >= n) break
    out += ch
  }
  return out
}

export function drop(s: string, n: number): string {
  if (n <= 0) return s
  let i = 0
  let at = 0
  for (const ch of s) {
    if (i++ >= n) break
    at += ch.length
  }
  return s.slice(at)
}

export const reverse = (s: string): string => Array.from(s).reverse().join('')

// The first character's code, or -1 for "".
export const firstCode = (s: string): number => (s.length === 0 ? -1 : s.codePointAt(0)!)

export const lines = (s: string): string[] => s.split('\n')

export const isEmpty = (s: string): boolean => s.length === 0

// a, or b when a is empty
export const orElse = (a: string, b: string): string => (a.length === 0 ? b : a)

// The same stable merge sort reflexd always ranked with: `le(a, b)` puts a first.
export function sortBy<T>(xs: readonly T[], le: (a: T, b: T) => boolean): T[] {
  if (xs.length === 0) return []
  let runs: T[][] = []
  for (let i = 0; i < xs.length; i += 2) {
    if (i + 1 < xs.length) {
      const x = xs[i]!
      const y = xs[i + 1]!
      runs.push(le(x, y) ? [x, y] : [y, x])
    } else runs.push([xs[i]!])
  }
  while (runs.length > 1) {
    const next: T[][] = []
    for (let i = 0; i < runs.length; i += 2) {
      if (i + 1 < runs.length) next.push(merge(runs[i]!, runs[i + 1]!, le))
      else next.push(runs[i]!)
    }
    runs = next
  }
  return runs[0]!
}

function merge<T>(a: T[], b: T[], le: (a: T, b: T) => boolean): T[] {
  const out: T[] = []
  let i = 0
  let j = 0
  while (i < a.length && j < b.length) {
    if (le(a[i]!, b[j]!)) out.push(a[i++]!)
    else out.push(b[j++]!)
  }
  while (i < a.length) out.push(a[i++]!)
  while (j < b.length) out.push(b[j++]!)
  return out
}
