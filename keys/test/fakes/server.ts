// A fake sign-in server for the fake harnesses: refresh tokens work once, as the real ones.
// Tokens look like `rt:<account>:<n>`; $WORLD/server/<account>.json holds the one that works.
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs'
import {join} from 'node:path'

const dir = () => join(process.env.WORLD!, 'server')
type Acct = {current: string; n: number; spent: number; refreshes: number}

export function account(name: string): Acct {
  try { return JSON.parse(readFileSync(join(dir(), `${name}.json`), 'utf8')) } catch { return {current: '', n: 0, spent: 0, refreshes: 0} }
}
const put = (name: string, a: Acct) => { mkdirSync(dir(), {recursive: true}); writeFileSync(join(dir(), `${name}.json`), JSON.stringify(a)) }

// A fresh sign-in: a new token that works.
export function signIn(name: string): string {
  const a = account(name)
  a.n++
  a.current = `rt:${name}:${a.n}`
  put(name, a)
  return a.current
}

// Spend `rt`: the next one, or null (and counted) when it was already spent.
export function refresh(rt: string): {refresh: string; access: string} | null {
  const name = rt.split(':')[1] ?? ''
  const a = account(name)
  if (!rt || rt !== a.current) { a.spent++; put(name, a); return null }
  a.n++; a.refreshes++
  a.current = `rt:${name}:${a.n}`
  put(name, a)
  return {refresh: a.current, access: `at:${name}:${a.n}`}
}

export const jwt = (exp: number) =>
  ['e30', Buffer.from(JSON.stringify({exp: Math.floor(exp / 1000)})).toString('base64url'), 'sig'].join('.')
