// pi 1.6.0: <agent dir>/auth.json, one entry per provider. pi locks it with proper-lockfile
// (a directory <realpath>.lock, stale after 30 s), re-reads under the lock, and reloads the
// file whenever its stat changes.
//
// Rotating: the Anthropic and OpenAI (Codex) sign-ins. Copied as they are: Copilot (its
// GitHub token doesn't rotate), Google's, API keys.
//
// Placeholder: any non-empty string in `refresh` (pi refuses an empty one); a refresh with
// it fails, pi keeps the entry, and the next request reads the holder's push.
//
// Refresh: `pi auth print-bearer-token --provider X --min-expiry D` (the token to /dev/null).
import {join} from 'node:path'
import {dirLock} from '../lock'
import {piDir, type Profile} from '../profile'
import {clone, now, readJson, target, writeJson} from '../util'
import {fp, margin, run, type Content, type Store} from './store'

export const PI_ROTATING = new Set(['anthropic', 'openai-codex'])
export const PI_PLACEHOLDER = 'reflex-keys:not-the-holder'

export function piStore(p: Profile): Store {
  const file = join(piDir(p), 'auth.json')
  const rotating = (c: any) => Object.entries(c ?? {}).filter(([k, e]: [string, any]) => PI_ROTATING.has(k) && e?.type === 'oauth') as [string, any][]
  const lock = <T>(fn: () => Promise<T>) => dirLock(`${target(file)}.lock`, fn, {stale: 30_000, touch: 5_000, wait: 30_000, what: "pi's auth.json lock"})
  const left = margin('pi', 2 * 3_600_000)

  const s: Store = {
    rotates: true,
    where: file,
    async read() { return readJson(file) },
    usable: (c: Content) => rotating(c).some(([, e]) => typeof e.refresh === 'string' && e.refresh !== '' && e.refresh !== PI_PLACEHOLDER),
    strip(c: Content) { const o = clone(c ?? {}); for (const [k] of rotating(o)) o[k].refresh = PI_PLACEHOLDER; return o },
    async write(c: Content, token: boolean) {
      const next = token ? clone(c ?? {}) : s.strip(c)
      // Only the providers in the copy; anything else here stays.
      await lock(async () => writeJson(file, {...(readJson(file) ?? {}), ...next}, '.auth.json.'))
    },
    expiry(c: Content) {
      const xs = rotating(c).map(([, e]) => e.expires).filter((x: any) => typeof x === 'number')
      return xs.length ? Math.min(...xs) : null
    },
    loginEnd: () => null,
    fingerprint: (c: Content) => fp(c),
    due: (c: Content) => rotating(c).some(([, e]) => typeof e.expires === 'number' && e.expires - now() < left),
    guard: lock,
    async refresh(c: Content) {
      const due = rotating(c).filter(([, e]) => typeof e.expires === 'number' && e.expires - now() < left).map(([k]) => k)
      for (const k of due)
        await run(p, ['pi', 'auth', 'print-bearer-token', '--provider', k, '--min-expiry', `${Math.ceil(left / 60_000)}m`], {}, {timeout: 120_000})
      return due.length ? `refreshed ${due.join(', ')}` : 'nothing due'
    },
  }
  return s
}
