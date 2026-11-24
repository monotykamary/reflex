import {createHash, randomBytes} from 'node:crypto'
import {closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, realpathSync, renameSync, rmSync, writeSync} from 'node:fs'
import {basename, dirname, join} from 'node:path'

export class Fail extends Error {}
export function fail(msg: string): never { throw new Fail(msg) }

export const sha256 = (s: string) => createHash('sha256').update(s).digest('hex')
export const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))
export const now = () => Number(process.env.REFLEX_KEYS_NOW ?? Date.now())

// Anything that looks like a token (a long run of token characters) never reaches a log.
export const redact = (s: string) => s.replace(/[A-Za-z0-9_\-.+=]{32,}/g, '[…]').slice(0, 2000)

export const say = (msg: string) => { process.stderr.write(`reflex-keys: ${redact(msg)}\n`) }

export function readJson<T = any>(path: string): T | null {
  let text: string
  try { text = readFileSync(path, 'utf8') } catch (e: any) { if (e.code === 'ENOENT') return null; throw e }
  try { return JSON.parse(text) } catch { return fail(`${path} isn't JSON`) }
}

// The file a path names, through links (a write replaces the target, not the link).
export function target(path: string): string {
  try { return realpathSync(path) } catch { return path }
}

// Readers see the whole old file or the whole new one: a private temp file beside it, synced, renamed over it.
export function atomicWrite(path: string, data: string, prefix = '.reflex-keys-') {
  const dest = target(path)
  mkdirSync(dirname(dest), {recursive: true, mode: 0o700})
  const tmp = join(dirname(dest), `${prefix}${basename(dest)}.${randomBytes(6).toString('hex')}`)
  const fd = openSync(tmp, 'wx', 0o600)
  try {
    writeSync(fd, data)
    fsyncSync(fd)
  } finally { closeSync(fd) }
  try { renameSync(tmp, dest) } catch (e) { rmSync(tmp, {force: true}); throw e }
  try { const d = openSync(dirname(dest), 'r'); try { fsyncSync(d) } finally { closeSync(d) } } catch {}
}

export const writeJson = (path: string, value: unknown, prefix?: string) => atomicWrite(path, JSON.stringify(value, null, 2) + '\n', prefix)

export const exists = (p: string) => existsSync(p)

// A JWT's exp, in ms (read, never printed).
export function jwtExp(token: unknown): number | null {
  if (typeof token !== 'string') return null
  const part = token.split('.')[1]
  if (!part) return null
  try {
    const exp = JSON.parse(Buffer.from(part, 'base64url').toString('utf8')).exp
    return typeof exp === 'number' ? exp * 1000 : null
  } catch { return null }
}

export const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v))

export function ago(ms: number | null | undefined): string {
  if (ms == null) return '-'
  const d = ms - now(), a = Math.abs(d)
  const s = a < 3_600_000 ? `${Math.round(a / 60_000)}m` : a < 172_800_000 ? `${Math.round(a / 3_600_000)}h` : `${Math.round(a / 86_400_000)}d`
  return d >= 0 ? `in ${s}` : `${s} ago`
}
