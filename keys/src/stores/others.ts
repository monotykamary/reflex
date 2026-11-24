// The harnesses that run with a home of their own (HOME=<profile>/home): agy, amp, grok,
// opencode. Read from their code on 2026-11-24 (opencode 2.3.2, amp 0.0.1767960117, grok
// build 1.0.45 source at 2bdd1d6: not installed here, unverified against a binary).
import {Database} from 'bun:sqlite'
import {existsSync} from 'node:fs'
import {join} from 'node:path'
import * as kc from '../keychain'
import {flock} from '../lock'
import {keychainStore, type Profile} from '../profile'
import {clone, fail, readJson, writeJson} from '../util'
import {fp, type Content, type Store} from './store'

const NO_TRIGGER = async () => 'no harness command refreshes it early: it refreshes itself when used on the holder'

// agy (Antigravity): its Google sign-in, Keychain item service "gemini", account
// "antigravity" (in the profile's own Keychain, which Reflex keeps unlocked with a password
// held in your login Keychain). Google refresh tokens don't rotate: copied as they are.
export const PROFILE_KEYCHAIN = 'Reflex profile keychain'
export function agyStore(p: Profile): Store {
  if (!keychainStore()) {
    const no = () => fail('agy outside a Mac: where it keeps its login there is not known yet')
    return {rotates: false, where: '?', read: no, strip: c => c, usable: () => false, write: no, expiry: () => null, loginEnd: () => null, fingerprint: () => '', due: () => false, refresh: no, guard: fn => fn()}
  }
  const keychain = p.name ? join(p.hhome, 'Library', 'Keychains', 'reflex-profile.keychain-db') : undefined
  const item: kc.Item = {service: 'gemini', account: 'antigravity', keychain, home: p.name ? p.hhome : undefined}
  const open = () => {
    if (!keychain) return
    if (!existsSync(keychain)) fail(`${p.key} has no Keychain here yet: make the profile first (reflex profile new ${p.key})`)
    const pw = kc.read({service: PROFILE_KEYCHAIN, account: `agy/${p.name}`}) ?? fail(`${p.key}'s Keychain password isn't in your Keychain`)
    kc.unlock(keychain, pw, p.hhome)
  }
  return {
    rotates: false,
    where: keychain ? `${keychain} "gemini"` : 'Keychain "gemini"',
    async read() { open(); const v = kc.read(item); return v == null ? null : {value: v} },
    usable: (c: Content) => typeof c?.value === 'string' && c.value !== '',
    strip: (c: Content) => c,
    async write(c: Content) { open(); kc.write(item, c.value) },
    expiry: () => null, loginEnd: () => null,
    fingerprint: (c: Content) => fp(c?.value),
    due: () => false, refresh: NO_TRIGGER, guard: fn => fn(),
  }
}

// amp: <home>/.local/share/amp/secrets.json, "<name>@<url>" → string; the login is
// "apiKey@https://ampcode.com/", a long-lived token (no refresh): copied as is. Its MCP
// OAuth tokens stay per machine. A running amp caches the file and rewrites all of it on
// its next write: a copy lands for good once amp there restarts.
export function ampStore(p: Profile): Store {
  const file = join(p.hhome, '.local', 'share', 'amp', 'secrets.json')
  const ours = (c: any) => Object.fromEntries(Object.entries(c ?? {}).filter(([k]) => !k.startsWith('mcp-oauth-')))
  return {
    rotates: false,
    where: file,
    async read() { const c = readJson(file); return c && Object.keys(ours(c)).length ? ours(c) : null },
    usable: (c: Content) => Object.keys(c ?? {}).some(k => k.startsWith('apiKey@')),
    strip: (c: Content) => c,
    async write(c: Content) { writeJson(file, {...(readJson(file) ?? {}), ...ours(c)}, '.amp-temp-') },
    expiry: () => null, loginEnd: () => null,
    fingerprint: (c: Content) => fp(c),
    due: () => false, refresh: NO_TRIGGER, guard: fn => fn(),
  }
}

// grok (xAI's Grok Build CLI): <home>/.grok/auth.json, scope → entry. An `oidc` entry's
// refresh_token works once; API keys don't rotate. Locked by a flock on auth.json.lock,
// written atomically. Placeholder: refresh_token left out (grok then never refreshes and
// adopts the file's token at expiry); "" would be spent and end the login.
export function grokStore(p: Profile): Store {
  const file = join(p.hhome, '.grok', 'auth.json')
  const lock = <T>(fn: () => Promise<T>) => flock(`${file}.lock`, fn, {what: "grok's auth.json.lock"})
  const oidc = (c: any) => Object.values(c ?? {}).filter((e: any) => e?.auth_mode === 'oidc') as any[]
  return {
    rotates: true,
    where: file,
    async read() { return readJson(file) },
    usable: (c: Content) => oidc(c).some(e => typeof e.refresh_token === 'string' && e.refresh_token !== ''),
    strip(c: Content) { const o = clone(c ?? {}); for (const e of oidc(o)) delete e.refresh_token; return o },
    async write(c: Content, token: boolean) {
      const next = token ? clone(c ?? {}) : this.strip(c)
      await lock(async () => writeJson(file, {...(readJson(file) ?? {}), ...next}, '.auth.json.'))
    },
    expiry(c: Content) {
      const xs = oidc(c).map(e => Date.parse(e.expires_at ?? '')).filter(x => !Number.isNaN(x))
      return xs.length ? Math.min(...xs) : null
    },
    loginEnd: () => null,
    fingerprint: (c: Content) => fp(c),
    due: () => false, refresh: NO_TRIGGER, guard: lock,
  }
}

// opencode 2.x: rows of the `credential` table in <home>/.local/share/opencode/opencode.db
// (SQLite, WAL, busy_timeout 5000). Rotating: the OAuth sign-ins of openai, xai, opencode
// and gitlab. As they are: github-copilot, poe, digitalocean, API keys. Others (MCP OAuth)
// stay per machine. opencode refreshes 5 min before `expires`, under its own lock, and keeps
// a row written meanwhile. Placeholder: refresh "" and expires 0 (opencode never refreshes
// a credential with no expiry; a missing key would break its decoding).
export const OPENCODE_ROTATING = new Set(['openai', 'xai', 'opencode', 'gitlab'])
const OPENCODE_STATIC = new Set(['github-copilot', 'poe', 'digitalocean'])
export function opencodeStore(p: Profile): Store {
  const file = join(p.hhome, '.local', 'share', 'opencode', 'opencode.db')
  const rot = (r: any) => OPENCODE_ROTATING.has(r.integration_id) && r.value?.type === 'oauth'
  const copied = (r: any) => rot(r) || r.value?.type === 'key' || OPENCODE_STATIC.has(r.integration_id)
  const db = (write: boolean) => {
    if (!existsSync(file)) fail(`${file} doesn't exist: run opencode once in ${p.key} there first`)
    const d = new Database(file, write ? {readwrite: true} : {readonly: true})
    d.exec('PRAGMA busy_timeout = 5000')
    return d
  }
  const rows = (): any[] => {
    const d = db(false)
    try {
      return (d.query('SELECT * FROM credential').all() as any[]).map(r => ({...r, value: JSON.parse(r.value)})).filter(copied)
    } finally { d.close() }
  }
  return {
    rotates: true,
    where: file,
    async read() { if (!existsSync(file)) return null; const r = rows(); return r.length ? {rows: r} : null },
    usable: (c: Content) => (c?.rows ?? []).some((r: any) => rot(r) && typeof r.value.refresh === 'string' && r.value.refresh !== ''),
    strip(c: Content) { const o = clone(c ?? {rows: []}); for (const r of o.rows ?? []) if (rot(r)) { r.value.refresh = ''; r.value.expires = 0 } return o },
    async write(c: Content, token: boolean) {
      if (!token) c = this.strip(c)
      const d = db(true)
      try {
        const cols = new Set((d.query('PRAGMA table_info(credential)').all() as any[]).map(x => x.name))
        d.transaction(() => {
          for (const r0 of c?.rows ?? []) {
            const r = clone(r0)
            const row: Record<string, any> = Object.fromEntries(Object.entries({...r, value: JSON.stringify(r.value)}).filter(([k]) => cols.has(k)))
            const keys = Object.keys(row)
            d.query(`INSERT INTO credential (${keys.join(', ')}) VALUES (${keys.map(() => '?').join(', ')})
              ON CONFLICT(id) DO UPDATE SET ${keys.filter(k => k !== 'id').map(k => `${k} = excluded.${k}`).join(', ')}`).run(...keys.map(k => row[k]))
          }
        })()
      } finally { d.close() }
    },
    expiry(c: Content) {
      const xs = (c?.rows ?? []).filter(rot).map((r: any) => r.value.expires).filter((x: any) => typeof x === 'number' && x > 0)
      return xs.length ? Math.min(...xs) : null
    },
    loginEnd: () => null,
    fingerprint: (c: Content) => fp((c?.rows ?? []).map((r: any) => [r.id, r.value])),
    due: () => false, refresh: NO_TRIGGER, guard: fn => fn(),
  }
}
