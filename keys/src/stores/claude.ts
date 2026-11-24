// Claude Code 2.1.330. Mac: the Keychain item `Claude Code-credentials[-<8 hex>]`, account
// $USER (a `.credentials.json` beside the config is only a fallback, and its presence makes
// a running Claude watch the file instead: removed). Linux: <config>/.credentials.json.
// The store is one JSON object; reflex-keys copies only `claudeAiOauth` and keeps the rest.
//
// Locks, as Claude takes them (proper-lockfile directories): every store write under
// <config>/.storage-write.lock (stale 15 s); a refresh under <config>/.oauth_refresh.lock
// and <realpath(config)>.lock (stale 60 s, touched every 5 s). Claude re-reads under the
// refresh lock and adopts a token stored meanwhile.
//
// Placeholder: `refreshToken` left out. Claude never refreshes without one
// ("no_refresh_token"); "" would mean logged out.
//
// Refresh: `claude auth login` with CLAUDE_CODE_OAUTH_REFRESH_TOKEN and
// CLAUDE_CODE_OAUTH_SCOPES exchanges the refresh token without a browser and stores the
// result (in the env, never argv). It is a full sign-in: it rereads the profile, asks for
// a long-lived access token, revokes any stored `designOauth` token, and drops the login's
// end, which reflex-keys puts back (a refresh doesn't extend it). It takes no refresh lock,
// so reflex-keys holds Claude's around it.
import {rmSync} from 'node:fs'
import {join} from 'node:path'
import * as kc from '../keychain'
import {dirLock} from '../lock'
import {claudeAccount, claudeDir, claudeService, keychainStore, type Profile} from '../profile'
import {clone, fail, now, readJson, target, writeJson} from '../util'
import {fp, margin, run, type Content, type Store} from './store'

export function claudeStore(p: Profile): Store {
  const dir = claudeDir(p), file = join(dir, '.credentials.json')
  const item = {service: claudeService(p), account: claudeAccount(), keychain: kc.defaultKeychain()}
  const mac = keychainStore()

  const readAll = (): any => {
    if (mac) {
      const v = kc.read(item)
      if (v != null) { try { return JSON.parse(v) } catch { return fail(`${item.service} doesn't hold JSON`) } }
    }
    return readJson(file)
  }
  const writeAll = (all: any) => {
    if (mac) { kc.write(item, JSON.stringify(all)); rmSync(file, {force: true}) }
    else writeJson(file, all, '.credentials.json.')
  }
  const storageLock = <T>(fn: () => Promise<T>) => dirLock(join(dir, '.storage-write.lock'), fn, {stale: 15_000, touch: 5_000, wait: 15_000, what: "Claude's store"})
  const refreshLocks = <T>(fn: () => Promise<T>) =>
    dirLock(join(dir, '.oauth_refresh.lock'), () =>
      dirLock(`${target(dir)}.lock`, fn, {stale: 60_000, touch: 5_000, wait: 30_000, what: "Claude's refresh lock"}),
    {stale: 60_000, touch: 5_000, wait: 30_000, what: "Claude's refresh lock"})

  const s: Store = {
    rotates: true,
    where: mac ? `Keychain "${item.service}"` : file,
    async read() {
      const all = readAll()
      return all?.claudeAiOauth ? {claudeAiOauth: all.claudeAiOauth} : null
    },
    usable: (c: Content) => typeof c?.claudeAiOauth?.refreshToken === 'string' && c.claudeAiOauth.refreshToken !== '',
    strip(c: Content) { const o = clone(c); delete o?.claudeAiOauth?.refreshToken; return o },
    async write(c: Content, token: boolean) {
      const o = clone((token ? c : s.strip(c)).claudeAiOauth ?? fail('no claudeAiOauth in this copy'))
      await storageLock(async () => { writeAll({...(readAll() ?? {}), claudeAiOauth: o}) })
    },
    expiry: (c: Content) => c?.claudeAiOauth?.expiresAt ?? null,
    loginEnd: (c: Content) => c?.claudeAiOauth?.refreshTokenExpiresAt ?? null,
    fingerprint: (c: Content) => fp(c?.claudeAiOauth?.accessToken, c?.claudeAiOauth?.refreshToken, c?.claudeAiOauth?.expiresAt),
    due: (c: Content) => (s.expiry(c) ?? 0) - now() < margin('claude', 2 * 3_600_000),
    guard: refreshLocks,
    async refresh(c: Content) {
      return refreshLocks(async () => {
        const cur = await s.read()
        if (!cur || !s.usable(cur)) fail('no usable Claude login here to refresh')
        if (s.fingerprint(cur) !== s.fingerprint(c)) return 'changed meanwhile'
        const o = cur.claudeAiOauth
        const scopes = Array.isArray(o.scopes) ? o.scopes.join(' ') : ''
        if (!scopes) fail('the stored Claude login names no scopes')
        await run(p, ['claude', 'auth', 'login'], {CLAUDE_CODE_OAUTH_REFRESH_TOKEN: o.refreshToken, CLAUDE_CODE_OAUTH_SCOPES: scopes},
          {timeout: 180_000, drop: ['CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY']})
        const after = await s.read()
        if (!after || !s.usable(after) || s.fingerprint(after) === s.fingerprint(cur)) fail('claude auth login stored no new login')
        // A refresh doesn't extend the login: keep its end.
        const end = o.refreshTokenExpiresAt, got = after.claudeAiOauth.refreshTokenExpiresAt
        if (typeof end === 'number' && !(typeof got === 'number' && got <= end))
          await storageLock(async () => {
            const all = readAll()
            if (all?.claudeAiOauth?.refreshToken === after.claudeAiOauth.refreshToken) writeAll({...all, claudeAiOauth: {...all.claudeAiOauth, refreshTokenExpiresAt: end}})
          })
        return 'refreshed'
      })
    },
  }
  return s
}
