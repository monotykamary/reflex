// How much of each login's plan is used: Claude's, Codex's and agy's own usage endpoints,
// read with the access token this machine already has. Read only: reflex-keys never
// refreshes a token for this (rule 2). A Claude or Codex token that has run out here is
// reported as such; agy (Google's tokens don't rotate) is asked to refresh by running
// `agy models` in its profile, which saves the new token as agy always does.
//
//   reflex-keys usage [--json] [SPEC...]    every login here (profiles and your own) by default
//
// The last answers are kept in ~/.reflex/keys/usage.json: a login that fails now keeps its
// last numbers, with when they were read.
import {join} from 'node:path'
import {parse, type Profile} from './profile'
import {keysDir, known} from './state'
import {storeFor} from './stores'
import {run} from './stores/store'
import {jwtExp, now, readJson, redact, writeJson} from './util'

export type Window = {
  label: string            // "5 hours", "Week", "Week · Opus", "Gemini"
  percent: number          // used, 0-100
  resetsAt: number | null  // ms
}
export type Usage = {
  profile: string          // claude[tom], or claude for your own
  plan: string | null      // "Max 20x", "Pro", "Free"
  windows: Window[]
  at: number               // when these numbers were read (ms)
  error?: string           // why they couldn't be read now (the numbers are then the last ones)
}

const USAGE_HARNESSES = ['claude', 'codex', 'agy'] as const
const TIMEOUT = 15_000

const pct = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? Math.max(0, Math.min(100, Math.round(v))) : null)
const time = (v: unknown) => {
  if (typeof v === 'number') return v < 1e12 ? v * 1000 : v
  if (typeof v === 'string') { const t = Date.parse(v); return Number.isNaN(t) ? null : t }
  return null
}
const words = (s: string) => s.replace(/[_-]+/g, ' ').replace(/\b\w/g, c => c.toUpperCase())

// Claude: GET api.anthropic.com/api/oauth/usage (what Claude Code's /usage reads). `limits`
// lists each window ({kind, group, percent, resets_at, scope}); older answers have only
// five_hour, seven_day and seven_day_<model> ({utilization, resets_at}).
export function claudeWindows(j: any): Window[] {
  const out: Window[] = []
  const add = (label: string, percent: number | null, resetsAt: unknown) => {
    if (percent !== null && !out.some(w => w.label === label)) out.push({label, percent, resetsAt: time(resetsAt)})
  }
  for (const l of Array.isArray(j?.limits) ? j.limits : []) {
    const kind = String(l?.kind ?? ''), model = l?.scope?.model?.display_name
    const label = kind === 'weekly_all' ? 'Week'
      : kind === 'weekly_scoped' ? `Week · ${model ?? 'scoped'}`
      : /five|session|5h/.test(kind) || l?.group === 'session' ? '5 hours'
      : words(kind)
    add(label, pct(l?.percent), l?.resets_at)
  }
  const legacy: [string, string][] = [['five_hour', '5 hours'], ['seven_day', 'Week'], ['seven_day_opus', 'Week · Opus'], ['seven_day_sonnet', 'Week · Sonnet']]
  for (const [k, label] of legacy) if (j?.[k]) add(label, pct(j[k].utilization), j[k].resets_at)
  return out
}

export function claudePlan(o: any): string | null {
  const x = /max_(\d+x)/.exec(String(o?.rateLimitTier ?? ''))
  if (x) return `Max ${x[1]}`
  return typeof o?.subscriptionType === 'string' && o.subscriptionType ? words(o.subscriptionType) : null
}

// Codex: GET chatgpt.com/backend-api/wham/usage (with ChatGPT-Account-Id), whose
// rate_limit has a primary and a secondary window ({used_percent, limit_window_seconds, reset_at}).
const span = (s: unknown) => {
  if (typeof s !== 'number' || s <= 0) return 'Window'
  if (s === 18_000) return '5 hours'
  if (s === 604_800) return 'Week'
  return s % 86_400 === 0 ? `${s / 86_400} days` : `${Math.round(s / 3600)} hours`
}
export function codexWindows(j: any): Window[] {
  const out: Window[] = []
  for (const w of [j?.rate_limit?.primary_window, j?.rate_limit?.secondary_window]) {
    const p = pct(w?.used_percent)
    if (w && p !== null) out.push({label: span(w.limit_window_seconds), percent: p, resetsAt: time(w.reset_at) ?? (typeof w.reset_after_seconds === 'number' ? now() + w.reset_after_seconds * 1000 : null)})
  }
  return out
}
const CODEX_PLANS: Record<string, string> = {plus: 'Plus', pro: 'Pro', promax: 'Pro Max', team: 'Team', business: 'Business', enterprise: 'Enterprise', free: 'Free'}
export const codexPlan = (j: any): string | null => (typeof j?.plan_type === 'string' ? CODEX_PLANS[j.plan_type] ?? words(j.plan_type) : null)

// agy: Antigravity's own calls on cloudcode-pa.googleapis.com, loadCodeAssist (its project
// and tier) then fetchAvailableModels, where each model has quotaInfo {remainingFraction,
// resetTime}. One window per model family: the least left, and when that comes back.
const FAMILY: Record<string, string> = {MODEL_PROVIDER_GOOGLE: 'Gemini', MODEL_PROVIDER_ANTHROPIC: 'Claude', MODEL_PROVIDER_OPENAI: 'GPT'}
export function agyWindows(j: any): Window[] {
  const fam = new Map<string, {left: number; reset: number | null}>()
  for (const m of Object.values<any>(j?.models ?? {})) {
    const q = m?.quotaInfo
    if (!q || m?.isInternal || !m?.displayName || typeof q.remainingFraction !== 'number') continue
    const name = FAMILY[m.modelProvider] ?? words(String(m.modelProvider ?? 'other').replace(/^MODEL_PROVIDER_/, '').toLowerCase())
    const cur = fam.get(name), reset = time(q.resetTime)
    if (!cur || q.remainingFraction < cur.left) fam.set(name, {left: q.remainingFraction, reset})
  }
  const order = (l: string) => { const i = Object.values(FAMILY).indexOf(l); return i < 0 ? 99 : i }
  return [...fam].sort(([a], [b]) => order(a) - order(b)).map(([label, v]) => ({label, percent: pct((1 - v.left) * 100)!, resetsAt: v.reset}))
}
export function agyPlan(j: any): string | null {
  const t = j?.paidTier ?? j?.currentTier
  if (!t) return null
  if (typeof t.name === 'string' && t.name && t.name !== 'Antigravity') return t.name
  return typeof t.id === 'string' ? words(t.id.replace(/-tier$/, '')) : null
}

async function getJson(url: string, init: RequestInit): Promise<any> {
  const r = await fetch(url, {...init, signal: AbortSignal.timeout(TIMEOUT), headers: {'User-Agent': 'reflex-keys', ...(init.headers as any)}})
  if (r.status === 401 || r.status === 403) throw new Error(`${new URL(url).host} said ${r.status}: the login here isn't accepted`)
  if (!r.ok) throw new Error(`${new URL(url).host} said ${r.status}`)
  return r.json()
}

const agyToken = (c: any): {access: string; expiry: number | null} | null => {
  if (typeof c?.value !== 'string') return null
  const raw = c.value.startsWith('go-keyring-base64:') ? Buffer.from(c.value.slice(18), 'base64').toString('utf8') : c.value
  try { const j = JSON.parse(raw), t = j.token ?? j; return typeof t.access_token === 'string' ? {access: t.access_token, expiry: time(t.expiry)} : null } catch { return null }
}

async function read(p: Profile): Promise<Omit<Usage, 'profile' | 'at'>> {
  const store = storeFor(p)
  let c: any = await store.read()
  if (!c) throw new Error('not signed in here')
  switch (p.harness) {
    case 'claude': {
      const o = c.claudeAiOauth
      if (!o?.accessToken) throw new Error('not signed in here')
      if (typeof o.expiresAt === 'number' && o.expiresAt < now()) throw new Error('the access token here has run out (the holder pushes the next one)')
      const j = await getJson('https://api.anthropic.com/api/oauth/usage', {headers: {Authorization: `Bearer ${o.accessToken}`, 'anthropic-beta': 'oauth-2025-04-20'}})
      return {plan: claudePlan(o), windows: claudeWindows(j)}
    }
    case 'codex': {
      const t = c.tokens
      if (!t?.access_token) throw new Error('not signed in here')
      const exp = jwtExp(t.access_token)
      if (exp && exp < now()) throw new Error('the access token here has run out (the holder pushes the next one)')
      const j = await getJson('https://chatgpt.com/backend-api/wham/usage', {headers: {Authorization: `Bearer ${t.access_token}`, ...(t.account_id ? {'ChatGPT-Account-Id': t.account_id} : {})}})
      return {plan: codexPlan(j), windows: codexWindows(j)}
    }
    case 'agy': {
      let t = agyToken(c)
      if (!t) throw new Error('not signed in here')
      if (t.expiry !== null && t.expiry < now() + 120_000) {
        // agy refreshes as it starts and saves the new token (Google's don't rotate).
        await run(p, ['agy', 'models'], {}, {timeout: 60_000})
        c = await store.read(); t = agyToken(c)
        if (!t || (t.expiry !== null && t.expiry < now())) throw new Error("agy didn't refresh its token")
      }
      // (These calls answer 403 to any client but agy's own name.)
      const h = {Authorization: `Bearer ${t.access}`, 'Content-Type': 'application/json', 'User-Agent': 'antigravity'}
      const load = await getJson('https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist', {method: 'POST', headers: h, body: JSON.stringify({metadata: {ideType: 'ANTIGRAVITY'}})})
      const proj = load?.cloudaicompanionProject, project = typeof proj === 'string' ? proj : proj?.id
      const models = await getJson('https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels', {method: 'POST', headers: h, body: JSON.stringify(project ? {project} : {})})
      return {plan: agyPlan(load), windows: agyWindows(models)}
    }
    default: throw new Error(`no usage for ${p.harness}`)
  }
}

const cacheFile = () => join(keysDir(), 'usage.json')

// The logins here: the profiles reflex-keys keeps, and your own where you're signed in.
export function usageSpecs(): string[] {
  const own: string[] = [...USAGE_HARNESSES]
  return [...new Set([...known(), ...own])].filter(k => (USAGE_HARNESSES as readonly string[]).includes(parse(k).harness))
}

export async function usage(specs: string[] = usageSpecs()): Promise<Usage[]> {
  const last = readJson<Record<string, Usage>>(cacheFile()) ?? {}
  const got = await Promise.all(specs.map(async (key): Promise<Usage | null> => {
    try {
      return {profile: key, ...(await read(parse(key))), at: now()}
    } catch (e: any) {
      const error = redact(e?.message ?? String(e))
      // Your own login, unread and never read: one you don't use here (profiles are shown either way).
      if (!parse(key).name && !last[key]) return null
      return last[key] ? {...last[key], error} : {profile: key, plan: null, windows: [], at: 0, error}
    }
  }))
  const out = got.filter((u): u is Usage => u !== null)
  const next = {...last}
  for (const u of out) if (!u.error) next[u.profile] = u
  try { writeJson(cacheFile(), next) } catch {}
  return out
}

export function usageText(xs: Usage[]): string {
  if (!xs.length) return 'no logins here to read usage for'
  const when = (t: number | null) => (t ? new Date(t).toLocaleString() : '?')
  return xs.map(u => [
    `${u.profile}${u.plan ? ` (${u.plan})` : ''}${u.error ? `: ${u.error}` : ''}`,
    ...u.windows.map(w => `  ${w.label}: ${w.percent}% used, resets ${when(w.resetsAt)}`),
  ].join('\n')).join('\n')
}
