// Codex 0.172.0: $CODEX_HOME/auth.json (the default `file` store). Codex writes it under a
// flock on $CODEX_HOME/auth.lock (the whole read-modify-write) and one on auth.json.lock
// (the commit), as a private temp file renamed over it, and saves a refresh only if the
// file is unchanged (compare-and-swap): a push mid-refresh wins.
//
// Placeholder: `tokens.refresh_token: ""` (the key is required).
//
// Refresh: the app server's `account/read` with `refreshToken: true` ("requests a proactive
// token refresh before returning"; v2 protocol, app-server/src/request_processors/
// account_processor/workspace_routing.rs `get_account` → AuthManager::refresh_token, a
// forced refresh through Codex's own guarded reload and locks). `codex app-server` speaks
// JSON-RPC over stdio: initialize, initialized, account/read.
import {join} from 'node:path'
import {flock} from '../lock'
import {codexHome, harnessPath, type Profile} from '../profile'
import {clone, fail, jwtExp, now, readJson, redact, target, writeJson} from '../util'
import {fp, margin, type Content, type Store} from './store'

export function codexStore(p: Profile): Store {
  const dir = codexHome(p), file = join(dir, 'auth.json')
  const locks = <T>(fn: () => Promise<T>) =>
    flock(join(dir, 'auth.lock'), () => flock(`${target(file)}.lock`, fn, {what: "Codex's auth.json.lock"}), {what: "Codex's auth.lock"})
  const account = (c: any) => c?.tokens?.account_id ?? null

  const s: Store = {
    rotates: true,
    where: file,
    async read() { return readJson(file) },
    usable: (c: Content) => typeof c?.tokens?.refresh_token === 'string' && c.tokens.refresh_token !== '',
    strip(c: Content) { const o = clone(c); if (o?.tokens) o.tokens.refresh_token = ''; return o },
    async write(c: Content, token: boolean) {
      const next = token ? clone(c) : s.strip(c)
      if (!next?.tokens) fail('this Codex copy has no tokens')
      await locks(async () => {
        const cur = readJson(file)
        if (account(cur) && account(next) && account(cur) !== account(next)) fail(`${file} is signed in to another account; not replacing it`)
        writeJson(file, next, '.auth-')
      })
    },
    expiry: (c: Content) => jwtExp(c?.tokens?.access_token),
    loginEnd: () => null,
    fingerprint: (c: Content) => fp(c?.tokens?.access_token, c?.tokens?.refresh_token, c?.last_refresh),
    due(c: Content) {
      const left = (s.expiry(c) ?? 0) - now()
      const age = now() - (Date.parse(c?.last_refresh ?? '') || 0)
      return left < margin('codex', 24 * 3_600_000) || age > 24 * 3_600_000
    },
    guard: <T>(fn: () => Promise<T>) => flock(join(dir, 'auth.lock'), fn, {what: "Codex's auth.lock"}),
    async refresh(c: Content) {
      const before = s.fingerprint(c)
      await appServerRefresh(p)
      const after = await s.read()
      if (!after || !s.usable(after)) fail('Codex has no usable login after the refresh')
      if (s.fingerprint(after) === before) fail("Codex didn't refresh (account/read returned; auth.json unchanged)")
      return 'refreshed'
    },
  }
  return s
}

async function appServerRefresh(p: Profile) {
  const env = {...process.env, ...p.env, PATH: harnessPath()}
  let proc
  try {
    proc = Bun.spawn(['codex', 'app-server'], {env, stdin: 'pipe', stdout: 'pipe', stderr: 'pipe', timeout: 90_000})
  } catch (e: any) { return fail(`couldn't run codex: ${e.message}`) }
  const send = (m: object) => { proc.stdin.write(JSON.stringify(m) + '\n'); proc.stdin.flush() }
  const errText = new Response(proc.stderr).text()
  try {
    const reader = proc.stdout.getReader()
    let buf = '', answer: any
    const wait = async (id: number) => {
      for (;;) {
        const nl = buf.indexOf('\n')
        if (nl >= 0) {
          const line = buf.slice(0, nl); buf = buf.slice(nl + 1)
          let m: any
          try { m = JSON.parse(line) } catch { continue }
          if (m?.id === id) return m
          continue
        }
        const {value, done} = await reader.read()
        if (done) fail(`codex app-server ended before answering: ${redact((await errText).trim().split('\n').slice(-2).join(' '))}`)
        buf += new TextDecoder().decode(value)
      }
    }
    send({id: 1, method: 'initialize', params: {clientInfo: {name: 'reflex-keys', version: '0.1.0'}}})
    const init = await wait(1)
    if (init.error) fail(`codex app-server refused initialize: ${redact(JSON.stringify(init.error))}`)
    send({method: 'initialized'})
    send({id: 2, method: 'account/read', params: {refreshToken: true}})
    answer = await wait(2)
    if (answer.error) fail(`codex account/read failed: ${redact(String(answer.error.message ?? ''))}`)
  } finally {
    try { proc.stdin.end() } catch {}
    const done = await Promise.race([proc.exited, Bun.sleep(5_000).then(() => null)])
    if (done === null) { proc.kill(); await proc.exited }
  }
}
