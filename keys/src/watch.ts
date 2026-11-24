// reflex-keys watch: the service a LaunchAgent keeps alive on every Mac.
//  - every ~15 s: the stores of the profiles this Mac holds; a change (a harness or Claude's
//    daemon refreshed) is a new generation, pushed at once;
//  - every ~10 min, at start, and after a sleep: the full tick (Codex and pi refreshed when
//    due, newer copies taken, whoever is behind brought up to date);
//  - for each Claude profile this Mac holds: one `claude daemon run` with that profile's env
//    (Claude's daemon refreshes the login ~4 min before it ends), unless `claude daemon
//    status` says one already runs for that config; restarted with backoff when it exits,
//    stopped (its exact PID) when this Mac stops holding the profile.
// Each daemon runs under a small sh guard that kills it (by its PID) when watch is gone, even
// after a SIGKILL; watch stops its guards on SIGTERM, SIGINT and SIGHUP.
import {appendFileSync, mkdirSync, renameSync, statSync} from 'node:fs'
import {join} from 'node:path'
import {heldHere, noticeChange, tick} from './ops'
import {harnessPath, parse} from './profile'
import {keysDir} from './state'
import {redact, sleep} from './util'

const ms = (name: string, dflt: number) => Number(process.env[name] ?? dflt)

export function logger(quiet: boolean) {
  const file = join(keysDir(), 'watch.log')
  mkdirSync(keysDir(), {recursive: true})
  return (msg: string) => {
    const line = `${new Date().toISOString()} ${redact(msg)}\n`
    try {
      if (statSync(file).size > ms('REFLEX_KEYS_LOG_BYTES', 256 * 1024)) renameSync(file, `${file}.1`)
    } catch {}
    try { appendFileSync(file, line, {mode: 0o600}) } catch {}
    if (!quiet) process.stderr.write(line)
  }
}

type Daemon = {proc?: ReturnType<typeof Bun.spawn>; started: number; backoff: number; next: number; external?: number}

// The guard: runs the daemon, kills it by its PID when watch ($1) is gone or the guard is stopped.
const GUARD = `w=$1; shift
"$@" & c=$!
trap 'kill "$c" 2>/dev/null; wait "$c"; exit 143' TERM INT HUP
while kill -0 "$w" 2>/dev/null && kill -0 "$c" 2>/dev/null; do sleep 1; done
kill "$c" 2>/dev/null; wait "$c"`

async function daemonRunning(env: Record<string, string>): Promise<boolean> {
  try {
    const p = Bun.spawn(['claude', 'daemon', 'status'], {env, stdin: 'ignore', stdout: 'pipe', stderr: 'ignore', timeout: 30_000})
    const out = await new Response(p.stdout).text()
    return (await p.exited) === 0 && !/^\s*not running/.test(out)
  } catch { return false }
}

export async function watch(opts: {quiet: boolean}) {
  const log = logger(opts.quiet)
  const poll = ms('REFLEX_KEYS_POLL_MS', 15_000), every = ms('REFLEX_KEYS_TICK_MS', 600_000)
  const daemons = new Map<string, Daemon>()
  let stopping = false

  const stopDaemon = async (key: string, why: string) => {
    const d = daemons.get(key)
    daemons.delete(key)
    if (d?.proc && d.proc.exitCode === null) {
      log(`${key}: stopping Claude's daemon (pid ${d.proc.pid}): ${why}`)
      d.proc.kill('SIGTERM')
      const done = await Promise.race([d.proc.exited, sleep(10_000).then(() => null)])
      if (done === null) { d.proc.kill('SIGKILL'); await d.proc.exited }
    }
  }
  const stopAll = async (why: string) => { for (const k of [...daemons.keys()]) await stopDaemon(k, why) }
  for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP'] as const)
    process.on(sig, () => { if (stopping) return; stopping = true; log(`watch: ${sig}, stopping`); stopAll(sig).finally(() => process.exit(0)) })

  const supervise = async (held: string[]) => {
    const claude = new Set(held.filter(k => k.startsWith('claude')))
    for (const k of daemons.keys()) if (!claude.has(k)) await stopDaemon(k, 'this Mac no longer holds it')
    for (const key of claude) {
      const p = parse(key)
      const env = {...process.env, ...p.env, PATH: harnessPath()} as Record<string, string>
      const d = daemons.get(key) ?? {started: 0, backoff: 5_000, next: 0}
      daemons.set(key, d)
      if (d.proc && d.proc.exitCode === null) continue
      if (d.proc) {
        const ran = Date.now() - d.started
        if (ran > 600_000) d.backoff = 5_000
        log(`${key}: Claude's daemon exited (${d.proc.exitCode}) after ${Math.round(ran / 1000)} s; again in ${Math.round(d.backoff / 1000)} s`)
        d.next = Date.now() + d.backoff
        d.backoff = Math.min(d.backoff * 2, 600_000)
        d.proc = undefined
      }
      if (Date.now() < d.next) continue
      // One already running for this config (the user's own, say): leave it, look again later.
      if (d.external && Date.now() - d.external < ms('REFLEX_KEYS_EXTERNAL_CHECK_MS', 300_000)) continue
      if (await daemonRunning(env)) {
        if (!d.external) log(`${key}: Claude's daemon already runs for this config; not starting another`)
        d.external = Date.now(); continue
      }
      d.external = undefined
      const logFile = join(keysDir(), `claude-${key}.log`)
      d.proc = Bun.spawn(['sh', '-c', GUARD, 'reflex-keys-guard', String(process.pid), 'claude', 'daemon', 'run', '--log-file', logFile],
        {env, stdin: 'ignore', stdout: 'ignore', stderr: 'ignore'})
      d.started = Date.now()
      log(`${key}: started Claude's daemon (guard pid ${d.proc.pid}), log ${logFile}`)
    }
  }

  log(`watch: started (pid ${process.pid}), polling every ${poll / 1000} s, a full tick every ${every / 1000} s`)
  let lastTick = 0, lastLoop = Date.now()
  while (!stopping) {
    const woke = Date.now() - lastLoop > poll + 60_000   // a sleep (the Mac's, or a stall)
    lastLoop = Date.now()
    const lines: string[] = []
    try {
      if (!lastTick || woke || Date.now() - lastTick >= every) {
        if (woke) lines.push('watch: awake again')
        lines.push(...(await tick()))
        lastTick = Date.now()
      } else {
        for (const key of heldHere()) {
          try { await noticeChange(key, lines) } catch (e: any) { lines.push(`${key}: ${e.message}`) }
        }
      }
      await supervise(heldHere())
    } catch (e: any) { lines.push(`watch: ${e.message}`) }
    for (const l of lines) log(l)
    await sleep(poll)
  }
}
