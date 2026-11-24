// The OS boundary of reflexd: one request over a Unix socket, processes,
// files, randomness and the clock. Every failure comes back as a value
// (code and the system's own words for it), never as a thrown error.

import {connect} from 'node:net'
import {appendFile, mkdir, readFile, writeFile} from 'node:fs/promises'
import type {Res} from './js.ts'
import {done, fail} from './js.ts'

const ERRNO: Record<string, [number, string]> = {
  EPERM: [1, 'Operation not permitted'],
  ENOENT: [2, 'No such file or directory'],
  EINTR: [4, 'Interrupted system call'],
  EIO: [5, 'Input/output error'],
  E2BIG: [7, 'Argument list too long'],
  ENOEXEC: [8, 'Exec format error'],
  EBADF: [9, 'Bad file descriptor'],
  ENOMEM: [12, 'Cannot allocate memory'],
  EACCES: [13, 'Permission denied'],
  EBUSY: [16, 'Resource busy'],
  EEXIST: [17, 'File exists'],
  ENOTDIR: [20, 'Not a directory'],
  EISDIR: [21, 'Is a directory'],
  EINVAL: [22, 'Invalid argument'],
  EMFILE: [24, 'Too many open files'],
  ETXTBSY: [26, 'Text file busy'],
  EFBIG: [27, 'File too large'],
  ENOSPC: [28, 'No space left on device'],
  EPIPE: [32, 'Broken pipe'],
  EAGAIN: [35, 'Resource temporarily unavailable'],
  ENOTSOCK: [38, 'Socket operation on non-socket'],
  EPROTOTYPE: [41, 'Protocol wrong type for socket'],
  EADDRINUSE: [48, 'Address already in use'],
  EADDRNOTAVAIL: [49, "Can't assign requested address"],
  ENETDOWN: [50, 'Network is down'],
  ENETUNREACH: [51, 'Network is unreachable'],
  ECONNABORTED: [53, 'Software caused connection abort'],
  ECONNRESET: [54, 'Connection reset by peer'],
  ENOTCONN: [57, 'Socket is not connected'],
  ETIMEDOUT: [60, 'Operation timed out'],
  ECONNREFUSED: [61, 'Connection refused'],
  ELOOP: [62, 'Too many levels of symbolic links'],
  ENAMETOOLONG: [63, 'File name too long'],
  EHOSTUNREACH: [65, 'No route to host'],
}

export function failOf<T>(name: string, fallback?: string): Res<T> {
  const e = ERRNO[name]
  return e ? fail(e[0], e[1]) : fail(1, fallback ?? name)
}

export function failErr<T>(err: unknown): Res<T> {
  const code = (err as {code?: string})?.code
  return failOf(typeof code === 'string' ? code : '', (err as Error)?.message ?? String(err))
}

// The longest Unix socket path the system takes (sockaddr_un.sun_path).
const SUN_PATH = process.platform === 'darwin' ? 104 : 108

// One newline-delimited request and response over a Unix stream socket:
// connect, write `line`, read until the first '\n' (left out), EOF or `max`
// bytes, all within `timeoutMs`.
export function unixCall(path: string, line: string, max: number, timeoutMs: number): Promise<Res<string>> {
  if (Buffer.byteLength(path) >= SUN_PATH) return Promise.resolve(failOf('ENAMETOOLONG'))
  return new Promise((resolve) => {
    const chunks: Buffer[] = []
    let n = 0
    let finished = false
    const sock = connect({path})
    const end = (r: Res<string>) => {
      if (finished) return
      finished = true
      clearTimeout(timer)
      sock.destroy()
      resolve(r)
    }
    const timer = setTimeout(() => end(failOf('ETIMEDOUT')), Math.max(1, timeoutMs))
    sock.on('connect', () => sock.write(line))
    sock.on('data', (b: Buffer) => {
      const nl = b.indexOf(10)
      if (nl >= 0) {
        chunks.push(b.subarray(0, nl))
        n += nl
        if (n > max) return end(failOf('EFBIG'))
        return end(done(Buffer.concat(chunks).toString('utf8')))
      }
      chunks.push(b)
      n += b.length
      if (n > max) end(failOf('EFBIG'))
    })
    sock.on('end', () => end(done(Buffer.concat(chunks).toString('utf8'))))
    sock.on('close', () => end(done(Buffer.concat(chunks).toString('utf8'))))
    sock.on('error', (err) => end(failErr(err)))
  })
}

export type Ran = {status: number; out: string; err: string}

// Run a program (searched on PATH, no shell) with `input` on its stdin; its
// exit status and what it wrote, up to `max` bytes in all, within `timeoutMs`
// (killed past it).
export async function run(cmd: string, args: string[], input: string, max: number, timeoutMs: number): Promise<Res<Ran>> {
  let proc: ReturnType<typeof Bun.spawn>
  try {
    proc = Bun.spawn([cmd, ...args], {stdin: 'pipe', stdout: 'pipe', stderr: 'pipe'})
  } catch (err) {
    return failErr(err)
  }
  let over = false
  let late = false
  const timer = setTimeout(() => {
    late = true
    proc.kill('SIGKILL')
  }, Math.max(1, timeoutMs))
  let total = 0
  const collect = async (stream: ReadableStream<Uint8Array>): Promise<Buffer> => {
    const parts: Uint8Array[] = []
    const reader = stream.getReader()
    for (;;) {
      const {value, done: end} = await reader.read()
      if (end) break
      total += value.length
      if (total > max) {
        over = true
        proc.kill('SIGKILL')
        continue
      }
      parts.push(value)
    }
    return Buffer.concat(parts)
  }
  try {
    const sink = proc.stdin as import('bun').FileSink
    try {
      if (input.length > 0) sink.write(input)
      await sink.end()
    } catch {
      // a program that doesn't read its input
    }
    const [out, err] = await Promise.all([collect(proc.stdout as ReadableStream<Uint8Array>), collect(proc.stderr as ReadableStream<Uint8Array>)])
    await proc.exited
    clearTimeout(timer)
    if (late) return failOf('ETIMEDOUT')
    if (over) return failOf('EFBIG')
    const status = proc.exitCode ?? (proc.signalCode ? 128 + signalNumber(String(proc.signalCode)) : 1)
    return done({status, out: out.toString('utf8'), err: err.toString('utf8')})
  } catch (err) {
    clearTimeout(timer)
    return failErr(err)
  }
}

function signalNumber(name: string): number {
  const n = (require('node:os') as typeof import('node:os')).constants.signals[name as keyof typeof import('node:os').constants.signals]
  return typeof n === 'number' ? n : 0
}

// A file's text, up to `max` bytes.
export async function readText(path: string, max: number): Promise<Res<string>> {
  try {
    const b = await readFile(path)
    return done((b.length > max ? b.subarray(0, max) : b).toString('utf8'))
  } catch (err) {
    return failErr(err)
  }
}

// Write ("w") or append ("a") text to a file.
export async function put(path: string, mode: 'w' | 'a', data: string): Promise<Res<null>> {
  try {
    if (mode === 'a') await appendFile(path, data)
    else await writeFile(path, data)
    return done(null)
  } catch (err) {
    return failErr(err)
  }
}

export async function mkdirP(path: string): Promise<void> {
  try {
    await mkdir(path, {recursive: true})
  } catch {
    // as `mkdir -p` that failed: nothing to do
  }
}

export function randomU32(): number {
  return crypto.getRandomValues(new Uint32Array(1))[0]!
}

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

export const nowMs = (): number => Math.floor(performance.timeOrigin + performance.now())

export const env = (name: string, dflt: string): string => {
  const v = process.env[name]
  return v === undefined || v.length === 0 ? dflt : v
}

export function ppid(): number {
  return process.ppid
}
