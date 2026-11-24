// Locks, each the way the program that shares it takes it.
//  - dirLock: a directory made with mkdir, as proper-lockfile does (pi, Claude Code): held
//    while it exists, stale once its mtime is older than `stale`; the holder touches it.
//  - flock: an advisory lock on an open file, as Codex and grok take theirs.
import {dlopen, FFIType} from 'bun:ffi'
import {closeSync, mkdirSync, openSync, readFileSync, rmdirSync, rmSync, statSync, utimesSync, writeFileSync} from 'node:fs'
import {dirname} from 'node:path'
import {fail, sleep} from './util'

// Locks this process holds: taking one again inside it runs straight through.
const held = new Set<string>()
const reenter = <T>(path: string, fn: () => Promise<T> | T, take: () => Promise<T>) =>
  held.has(path) ? Promise.resolve(fn()) : take()

const alive = (pid: number) => { try { process.kill(pid, 0); return true } catch (e: any) { return e.code === 'EPERM' } }

export function dirLock<T>(path: string, fn: () => Promise<T> | T, opts: {stale: number; wait?: number; touch?: number; what?: string}): Promise<T> {
  return reenter(path, fn, () => takeDir(path, fn, opts))
}

async function takeDir<T>(path: string, fn: () => Promise<T> | T, opts: {stale: number; wait?: number; touch?: number; what?: string}): Promise<T> {
  const mark = `${path}.reflex-keys`   // ours, beside it: a lock a dead reflex-keys left is ours to clear
  const deadline = Date.now() + (opts.wait ?? 10_000)
  mkdirSync(dirname(path), {recursive: true})
  for (let i = 0; ; i++) {
    try { mkdirSync(path); break } catch (e: any) {
      if (e.code !== 'EEXIST') throw e
      let pid = 0
      try { pid = Number(readFileSync(mark, 'utf8')) } catch {}
      let age = 0
      try { age = Date.now() - statSync(path).mtimeMs } catch { continue }
      if ((pid && !alive(pid)) || age > opts.stale) {
        try { rmdirSync(path) } catch {}
        rmSync(mark, {force: true})
        continue
      }
      if (Date.now() > deadline) fail(`${opts.what ?? path} is locked (by another process); try again`)
      await sleep(Math.min(50 * 2 ** Math.min(i, 4), 500))
    }
  }
  writeFileSync(mark, String(process.pid))
  held.add(path)
  const timer = opts.touch ? setInterval(() => { try { const t = new Date(); utimesSync(path, t, t) } catch {} }, opts.touch) : undefined
  try { return await fn() } finally {
    if (timer) clearInterval(timer)
    held.delete(path)
    rmSync(mark, {force: true})
    try { rmdirSync(path) } catch {}
  }
}

let libc: {symbols: {flock: (fd: number, op: number) => number}} | undefined
function flockFn() {
  if (!libc) {
    const names = process.platform === 'darwin' ? ['libc.dylib', '/usr/lib/libSystem.B.dylib'] : ['libc.so.6', 'libc.so']
    let err: unknown
    for (const n of names) {
      try { libc = dlopen(n, {flock: {args: [FFIType.i32, FFIType.i32], returns: FFIType.i32}}) as any; break } catch (e) { err = e }
    }
    if (!libc) throw err
  }
  return libc.symbols.flock
}
const LOCK_EX = 2, LOCK_NB = 4, LOCK_UN = 8

export function flock<T>(path: string, fn: () => Promise<T> | T, opts: {wait?: number; what?: string} = {}): Promise<T> {
  return reenter(path, fn, () => takeFlock(path, fn, opts))
}

async function takeFlock<T>(path: string, fn: () => Promise<T> | T, opts: {wait?: number; what?: string}): Promise<T> {
  mkdirSync(dirname(path), {recursive: true})
  const fd = openSync(path, 'a+', 0o600)
  const f = flockFn(), deadline = Date.now() + (opts.wait ?? 10_000)
  try {
    for (let i = 0; f(fd, LOCK_EX | LOCK_NB) !== 0; i++) {
      if (Date.now() > deadline) fail(`${opts.what ?? path} is locked (by another process); try again`)
      await sleep(Math.min(20 * 2 ** Math.min(i, 4), 250))
    }
    held.add(path)
    try { return await fn() } finally { held.delete(path); f(fd, LOCK_UN) }
  } finally { closeSync(fd) }
}

// Several locks, taken in order, released in reverse.
export async function nested<T>(locks: ((inner: () => Promise<T>) => Promise<T>)[], fn: () => Promise<T> | T): Promise<T> {
  const run = (i: number): Promise<T> => i === locks.length ? Promise.resolve(fn()) : locks[i](() => run(i + 1))
  return run(0)
}
