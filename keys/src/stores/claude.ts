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
// Refresh: Claude's own daemon (`claude daemon run`, which `reflex-keys watch` keeps running
// on the holder with the profile's env) refreshes about 4 minutes before the access token
// ends, under Claude's own locks; watch sees the store change and pushes it. reflex-keys
// never makes Claude refresh any other way.
import {rmSync} from 'node:fs'
import {join} from 'node:path'
import * as kc from '../keychain'
import {dirLock} from '../lock'
import {claudeAccount, claudeDir, claudeService, keychainStore, type Profile} from '../profile'
import {clone, fail, readJson, target, writeJson} from '../util'
import {fp, type Content, type Store} from './store'

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
    due: () => false,
    guard: refreshLocks,
    refresh: async () => "Claude's daemon refreshes it (reflex-keys watch runs it on the holder)",
  }
  return s
}
