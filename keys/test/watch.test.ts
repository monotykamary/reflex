// reflex-keys watch on the holder: pushes a changed store within a poll; runs one Claude
// daemon (fake) per Claude profile it holds, restarts it when it exits, stops it on a
// handover, leaves one already running alone, and its daemon dies with it (even SIGKILL).
import {afterAll, describe, expect, test} from 'bun:test'
import {readFileSync} from 'node:fs'
import {join, resolve} from 'node:path'
import {account, signIn} from './fakes/server'
import {readJ, world, writeJ, type World} from './world'

const H = 3_600_000
const KEYS = resolve(import.meta.dir, '..')
const worlds: World[] = [], watchers: ReturnType<typeof Bun.spawn>[] = []
afterAll(() => {
  for (const p of watchers) if (p.exitCode === null) p.kill('SIGKILL')   // each by its own PID
  for (const w of worlds) w.done()
})

function setup() {
  const w = world({work: 'darwin', studio: 'darwin', box: 'linux'})
  worlds.push(w)
  process.env.WORLD = w.root
  return w
}
const ok = (r: {code: number | null; out: string; err: string}) => { if (r.code !== 0) throw new Error(`exit ${r.code}: ${r.err}${r.out}`); return r }
const startWatch = (w: World, m: string, extra: Record<string, string> = {}) => {
  const p = Bun.spawn([process.execPath, join(KEYS, 'src', 'cli.ts'), 'watch', '--quiet'], {
    cwd: w.home(m), env: {...w.env(m), REFLEX_KEYS_POLL_MS: '300', REFLEX_KEYS_TICK_MS: '600000', ...extra}, stdin: 'ignore', stdout: 'ignore', stderr: 'ignore',
  })
  watchers.push(p)
  return p
}
async function until(what: string, f: () => boolean, ms = 20_000) {
  const end = Date.now() + ms
  while (Date.now() < end) { if (f()) return; await Bun.sleep(100) }
  throw new Error(`timed out waiting for ${what}`)
}
const alive = (pid: number) => { if (!(pid > 0)) return false; try { process.kill(pid, 0); return true } catch { return false } }
const daemonPid = (w: World, m: string) => { try { return Number(readFileSync(join(w.root, `daemon-${m}.pid`), 'utf8')) } catch { return 0 } }
const watchLog = (w: World, m: string) => { try { return readFileSync(w.path(m, '.reflex', 'keys', 'watch.log'), 'utf8') } catch { return '' } }

const claudeFile = (w: World, m: string) => w.path(m, '.reflex', 'profiles', 'claude', 'work', 'claude', '.credentials.json')
const signInClaude = (w: World, m: string, acct: string, expiresIn: number) => writeJ(claudeFile(w, m), {
  claudeAiOauth: {accessToken: `at:${acct}:0`, refreshToken: signIn(acct), expiresAt: Date.now() + expiresIn, scopes: ['user:inference']},
})

describe('watch', () => {
  test('pushes a change on the holder within a poll (pi)', async () => {
    const w = setup()
    const f = (m: string) => w.path(m, '.reflex', 'profiles', 'pi', 'w', 'pi', 'auth.json')
    writeJ(f('work'), {anthropic: {type: 'oauth', refresh: signIn('jo'), access: 'at:jo:0', expires: Date.now() + 8 * H}})
    ok(w.run('work', ['seed', 'pi[w]']))
    const watcher = startWatch(w, 'work')
    await until('the first tick', () => watchLog(w, 'work').includes('watch: started'))
    await Bun.sleep(500)
    // pi on the holder refreshed by itself
    const a = readJ(f('work'))
    writeJ(f('work'), {...a, anthropic: {...a.anthropic, access: 'at:jo:9', refresh: 'rt:jo:9', expires: Date.now() + 8 * H}})
    await until('the box gets the new access token', () => readJ(f('box'))?.anthropic?.access === 'at:jo:9')
    expect(readJ(f('box')).anthropic.refresh).toBe('reflex-keys:not-the-holder')
    await until('the log line', () => watchLog(w, 'work').includes('pi[w]: the login changed here: gen 2'))
    expect(watchLog(w, 'work')).not.toMatch(/rt:jo|at:jo/)
    watcher.kill('SIGTERM'); await watcher.exited
  }, 60_000)

  test("runs Claude's daemon for a held Claude profile, pushes its refresh, restarts it, stops it at a handover", async () => {
    const w = setup()
    signInClaude(w, 'work', 'kim', 2 * 60_000)       // inside the daemon's ~4 min
    ok(w.run('work', ['seed', 'claude[work]']))
    const watcher = startWatch(w, 'work')
    await until("the daemon's refresh reaches studio and the box", () =>
      readJ(claudeFile(w, 'studio'))?.claudeAiOauth?.accessToken === 'at:kim:2' && readJ(claudeFile(w, 'box'))?.claudeAiOauth?.accessToken === 'at:kim:2')
    expect(account('kim')).toMatchObject({refreshes: 1, spent: 0})
    expect('refreshToken' in readJ(claudeFile(w, 'box')).claudeAiOauth).toBe(false)
    const first = daemonPid(w, 'work')
    expect(alive(first)).toBe(true)
    // it exits: started again (backoff 5 s)
    process.kill(first, 'SIGKILL')
    await until('a new daemon', () => daemonPid(w, 'work') !== first && alive(daemonPid(w, 'work')))
    // handed over: work's daemon stops
    const second = daemonPid(w, 'work')
    ok(w.run('box', ['hold', 'claude[work]', '--on', 'studio']))
    await until("work's daemon stops", () => !alive(second))
    expect(watchLog(w, 'work')).toContain('no longer holds it')
    expect(account('kim').spent).toBe(0)
    watcher.kill('SIGTERM'); await watcher.exited
  }, 60_000)

  test('leaves a Claude daemon that already runs for that config alone', async () => {
    const w = setup()
    signInClaude(w, 'work', 'lou', 8 * H)
    writeJ(join(w.root, 'daemon-running'), {})
    ok(w.run('work', ['seed', 'claude[work]']))
    const watcher = startWatch(w, 'work')
    await until('it notices', () => watchLog(w, 'work').includes('already runs'))
    await Bun.sleep(1_000)
    expect(daemonPid(w, 'work')).toBe(0)
    watcher.kill('SIGTERM'); await watcher.exited
  }, 60_000)

  test('its daemon dies with it, even when watch is SIGKILLed', async () => {
    const w = setup()
    signInClaude(w, 'work', 'max', 8 * H)
    ok(w.run('work', ['seed', 'claude[work]']))
    const watcher = startWatch(w, 'work')
    await until('a daemon', () => alive(daemonPid(w, 'work')))
    const d = daemonPid(w, 'work')
    watcher.kill('SIGKILL'); await watcher.exited
    await until('the daemon gone', () => !alive(d), 10_000)
  }, 60_000)
})
