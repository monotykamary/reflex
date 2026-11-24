// The commands. Every decision about the lease is lease.ts's (the rule proven in laws/);
// this file reads and writes stores and records, and talks to the other machines.
import {mkdirSync} from 'node:fs'
import {join} from 'node:path'
import * as L from './lease'
import {callJson, machines, type Meta} from './net'
import {parse, os, type Profile} from './profile'
import {clearOutbox, known, load, myId, outbox, peers, save, savePeers, setOutbox, withProfile, type Outbox, type PState} from './state'
import {storeFor, type Store} from './stores'
import {ago, fail, now, say} from './util'

export const VERSION = '0.1.0'

export type Payload = {v: 1; kind: 'copy' | 'handover'; spec: string; from: string; stamp: L.Stamp; content: unknown}
export type Result = {kind: L.Receipt['kind']; why?: string; lease: L.Lease}

// ---- what this machine knows -------------------------------------------------------

export function meta(): Meta {
  const profiles: Meta['profiles'] = {}
  for (const k of known()) { const st = load(k); profiles[k] = {...st.lease, ...(outbox(k) ? {pending: true} : {})} }
  return {id: myId(), os: os(), version: VERSION, profiles}
}

// Every machine herdr-core reaches, with what it knows (those without reflex-keys left out).
export async function survey(): Promise<Map<string, Meta>> {
  const names = await machines()
  const got = await Promise.allSettled(names.map(n => callJson<Meta>(n, ['meta'])))
  const metas = new Map<string, Meta>(), seen = peers()
  got.forEach((g, i) => {
    if (g.status === 'fulfilled' && g.value?.id) { metas.set(names[i], g.value); seen[names[i]] = {id: g.value.id, os: g.value.os, at: now()} }
  })
  savePeers(seen)
  return metas
}

const nameOf = (id: string, metas?: Map<string, Meta>): string | undefined => {
  if (id === myId()) return '.'
  for (const [n, m] of metas ?? []) if (m.id === id) return n
}
const shown = (id: string) => {
  if (!id) return 'nobody'
  if (id === myId()) return 'this machine'
  for (const [n, pr] of Object.entries(peers())) if (pr.id === id) return n
  return id
}

function ensureDir(p: Profile) {
  if (!p.dir) return
  const sub = {claude: 'claude', codex: 'codex', pi: 'pi'}[p.harness as string] ?? 'home'
  mkdirSync(join(p.dir, sub), {recursive: true, mode: 0o700})
}

// ---- receiving -----------------------------------------------------------------------

export async function receive(pl: Payload): Promise<Result> {
  if (pl?.v !== 1 || !pl.spec || !pl.stamp) fail('not a reflex-keys payload')
  const p = parse(pl.spec), store = storeFor(p), me = myId()
  if (pl.stamp.full !== (pl.kind === 'handover')) fail('a copy carries the token only in a handover')
  return withProfile(p.key, async () => {
    const st = load(p.key)
    const r = L.receive(st.lease, me, pl.stamp)
    if (r.kind !== 'apply') return {kind: r.kind, why: r.why, lease: st.lease}
    ensureDir(p)
    if (r.token) await store.write(pl.content, true)
    else if (r.content) await store.write(pl.content, false)
    else if (store.rotates) {
      // A newer lease without a newer copy: no usable token stays here (a holder stops).
      const cur = await store.read()
      if (cur && store.usable(cur)) await store.write(cur, false)
    }
    st.lease = r.lease
    const cur = await store.read()
    st.fp = cur ? store.fingerprint(cur) : undefined
    save(p.key, st)
    return {kind: 'apply', lease: st.lease}
  })
}

// This machine's copy, for another (never the refresh token).
export async function exportCopy(spec: string): Promise<Payload> {
  const p = parse(spec), store = storeFor(p)
  return withProfile(p.key, async () => {
    const st = load(p.key)
    if (!st.lease.epoch) fail(`this machine has no lease for ${p.key}`)
    if (outbox(p.key)) fail(`a handover of ${p.key} is in flight from here`)
    const c = await store.read()
    if (!c) fail(`no ${p.key} login in ${store.where}`)
    return {v: 1, kind: 'copy', spec: p.key, from: myId(), stamp: L.stamp(st.lease), content: store.strip(c)}
  })
}

// ---- pushing -------------------------------------------------------------------------

async function push(p: Profile, store: Store, metas: Map<string, Meta>, lines: string[]) {
  const me = myId()
  const snap = await withProfile(p.key, async () => {
    const st = load(p.key), c = await store.read()
    return {st, content: c && store.strip(c)}
  })
  if (!snap.content || !snap.st.lease.epoch || outbox(p.key)) return
  let {st} = snap
  for (const [name, m] of metas) {
    if (m.id === me) continue
    const their = m.profiles[p.key] ?? L.NO_LEASE
    if (their.pending) continue
    // After a forced takeover a machine may hold a later generation of the old holder's: the holder renumbers past it.
    if (st.lease.holder === me && their.epoch < st.lease.epoch && their.gen >= st.lease.gen) {
      st = await withProfile(p.key, async () => { const s = load(p.key); s.lease = {...s.lease, gen: their.gen + 1}; save(p.key, s); return s })
    }
    if (!(their.epoch < st.lease.epoch || L.newer(st.lease, their))) { ack(p.key, m.id, name, their); continue }
    const pl: Payload = {v: 1, kind: 'copy', spec: p.key, from: me, stamp: L.stamp(st.lease), content: snap.content}
    try {
      const res = await callJson<Result>(name, ['receive'], JSON.stringify(pl))
      ack(p.key, m.id, name, res.lease)
      lines.push(`${p.key}: ${name} ${res.kind === 'apply' ? 'took' : res.kind === 'conflict' ? 'REFUSED' : 'kept its own'} gen ${st.lease.gen}${res.why ? ` (${res.why})` : ''}`)
    } catch (e: any) { lines.push(`${p.key}: couldn't push to ${name}: ${e.message}`) }
  }
}

function ack(key: string, id: string, name: string, l: L.Lease) {
  const st = load(key)
  st.acked[id] = {name, epoch: l.epoch, gen: l.gen, at: now()}
  save(key, st)
}

// ---- the holder's work -------------------------------------------------------------

async function holderStep(p: Profile, store: Store, lines: string[]) {
  const me = myId()
  await withProfile(p.key, async () => {
    const st = load(p.key)
    if (st.lease.holder !== me) return
    let c = await store.read()
    if (!c || !store.usable(c)) {
      st.error = `the holder's ${store.where} has no usable ${p.key} login: sign in again here`; st.errorAt = now()
      save(p.key, st); lines.push(`${p.key}: ${st.error}`); return
    }
    const renumber = (c: unknown) => {
      const f = store.fingerprint(c)
      if (f !== st.fp) { st.lease = L.renumber(st.lease); st.fp = f; return true }
      return false
    }
    if (renumber(c)) lines.push(`${p.key}: the login changed here: gen ${st.lease.gen}`)
    // Checked again just before the refresh, under the record's lock: still the holder.
    if (store.due(c) && L.mayRefresh(load(p.key).lease, me, store.usable(c))) {
      try {
        st.refreshNote = await store.refresh(c); st.refreshed = now()
        c = await store.read()
        if (c && renumber(c)) lines.push(`${p.key}: refreshed, gen ${st.lease.gen}`)
        else lines.push(`${p.key}: ${st.refreshNote}`)
      } catch (e: any) { st.error = `refresh failed: ${e.message}`; st.errorAt = now(); save(p.key, st); lines.push(`${p.key}: ${st.error}`); return }
    }
    st.error = undefined
    save(p.key, st)
  })
}

// A usable refresh token on a machine that isn't the holder would spend the holder's: it
// becomes a placeholder (sign in on the holder, or hand the lease here with hold).
async function strayStep(p: Profile, store: Store, lines: string[]) {
  if (!store.rotates) return
  await withProfile(p.key, async () => {
    const st = load(p.key)
    if (st.lease.holder === myId()) return
    const c = await store.read()
    if (c && store.usable(c)) {
      await store.write(c, false)
      lines.push(`${p.key}: a usable login was here on a machine that isn't the holder: replaced by a placeholder`)
    }
  })
}

async function deliver(key: string, o: Outbox, metas: Map<string, Meta>, lines: string[]): Promise<boolean> {
  const name = nameOf(o.to, metas)
  if (!name || name === '.') { lines.push(`${key}: the handover to ${shown(o.to)} waits: it isn't reachable`); return false }
  const pl: Payload = {v: 1, kind: 'handover', spec: key, from: myId(), stamp: o.stamp, content: o.content}
  try {
    const res = await callJson<Result>(name, ['receive'], JSON.stringify(pl))
    if (res.kind === 'apply' || (res.kind === 'ignore' && res.lease.holder === o.to && res.lease.epoch === o.stamp.epoch)) {
      clearOutbox(key)
      ack(key, o.to, name, res.lease)
      lines.push(`${key}: handed to ${name} (epoch ${o.stamp.epoch})`)
      return true
    }
    lines.push(`${key}: ${name} refused the handover: ${res.why}`)
  } catch (e: any) { lines.push(`${key}: the handover to ${name} failed, kept to retry: ${e.message}`) }
  return false
}

// ---- tick ----------------------------------------------------------------------------

export async function tickProfile(key: string, metas: Map<string, Meta>, lines: string[]) {
  const p = parse(key), store = storeFor(p), me = myId()
  let st = load(key)
  if (!st.lease.epoch) return
  // 1. A higher epoch, or a newer copy, somewhere: take it (a superseded holder stops here).
  let best: [string, L.Lease] | undefined
  for (const [n, m] of metas) {
    const l = m.profiles[key]
    if (!l || l.pending || m.id === me) continue
    const b = best?.[1] ?? st.lease
    if (l.epoch > b.epoch || L.newer(l, b)) best = [n, l]
  }
  if (best) {
    try {
      const res = await receive(await callJson<Payload>(best[0], ['export', key]))
      lines.push(`${key}: ${res.kind === 'apply' ? `took gen ${res.lease.gen} (epoch ${res.lease.epoch}) from ${best[0]}` : `${best[0]}'s copy: ${res.kind} (${res.why})`}`)
    } catch (e: any) { lines.push(`${key}: couldn't take ${best[0]}'s copy: ${e.message}`) }
  }
  // 2. A handover from here not yet delivered: nothing else until it is.
  const o = outbox(key)
  if (o && !(await deliver(key, o, metas, lines))) return
  st = load(key)
  // 3. The holder refreshes what's due; anyone else keeps no usable token.
  if (st.lease.holder === me) await holderStep(p, store, lines)
  else await strayStep(p, store, lines)
  // 4. Whoever is behind gets this machine's copy.
  await push(p, store, metas, lines)
}

export async function tick(): Promise<string[]> {
  const lines: string[] = []
  const metas = await survey()
  for (const key of known()) {
    try { await tickProfile(key, metas, lines) } catch (e: any) {
      lines.push(`${key}: ${e.message}`)
      try { await withProfile(key, async () => { const st = load(key); st.error = e.message; st.errorAt = now(); save(key, st) }) } catch {}
    }
  }
  return lines
}

// ---- watch's quick path ---------------------------------------------------------------

// The profiles this machine holds now.
export const heldHere = () => known().filter(k => load(k).lease.holder === myId())

// On the holder: the store changed (its harness, or Claude's daemon, refreshed): a new
// generation, pushed straight away.
export async function noticeChange(key: string, lines: string[]): Promise<boolean> {
  const p = parse(key), store = storeFor(p), me = myId()
  const changed = await withProfile(key, async () => {
    const st = load(key)
    if (st.lease.holder !== me || outbox(key)) return false
    const c = await store.read()
    if (!c || !store.usable(c)) return false
    const f = store.fingerprint(c)
    if (f === st.fp) return false
    st.lease = L.renumber(st.lease); st.fp = f
    save(key, st)
    lines.push(`${key}: the login changed here: gen ${st.lease.gen}`)
    return true
  })
  if (changed) await push(p, store, await survey(), lines)
  return changed
}

// ---- seed, hold ----------------------------------------------------------------------

const leasesOf = (key: string, metas: Map<string, Meta>) => [load(key).lease, ...[...metas.values()].map(m => m.profiles[key]).filter(Boolean)] as L.Lease[]

export async function seed(spec: string): Promise<string[]> {
  const p = parse(spec), store = storeFor(p), me = myId(), lines: string[] = []
  if (os() !== 'darwin' && !process.env.REFLEX_KEYS_ANY_HOLDER) fail('a holder is a Mac for now')
  const metas = await survey()
  await withProfile(p.key, async () => {
    const s = L.seed(leasesOf(p.key, metas), me)
    if ('error' in s) fail(`${p.key} is ${s.error.replace(/^already held by (\S+)/, (_, id) => `already held by ${shown(id)}`)}`)
    const c = await store.read()
    if (!c || !store.usable(c)) fail(`no usable ${p.key} login in ${store.where}: sign in here first (reflex profile login ${p.key})`)
    save(p.key, {lease: s.lease, fp: store.fingerprint(c), acked: {}})
  })
  lines.push(`${p.key}: held here, epoch 1`)
  await push(p, store, metas, lines)
  return lines
}

// On the holder: stop, and send the newest copy (with the token) to `to`.
export async function release(spec: string, to: string): Promise<string[]> {
  const p = parse(spec), store = storeFor(p), me = myId(), lines: string[] = []
  await withProfile(p.key, async () => {
    const pending = outbox(p.key)
    if (pending) { if (pending.to !== to) fail(`a handover of ${p.key} to ${shown(pending.to)} is in flight`); return }
    await store.guard(async () => {
      const st = load(p.key), c = await store.read()
      const r = L.release(st.lease, me, to, !!c && store.usable(c))
      if ('error' in r) fail(`${p.key}: ${r.error.replace(/\((\S+) is\)/, (_, id) => `(${shown(id)} is)`)}`)
      setOutbox(p.key, {to, stamp: r.send, content: c, at: now()})
      if (store.rotates) await store.write(c, false)
      st.lease = r.lease
      save(p.key, st)
    })
  })
  const metas = await survey()
  const o = outbox(p.key)
  if (o) await deliver(p.key, o, metas, lines)
  return lines
}

// A forced takeover here: a fresh sign-in on this machine, at an epoch above all known.
export async function takeover(spec: string): Promise<string[]> {
  const p = parse(spec), store = storeFor(p), me = myId(), lines: string[] = []
  if (os() !== 'darwin' && !process.env.REFLEX_KEYS_ANY_HOLDER) fail('a holder is a Mac for now')
  const metas = await survey()
  await withProfile(p.key, async () => {
    const c = await store.read()
    if (!c || !store.usable(c)) fail(`no usable ${p.key} login here: sign in here first (reflex profile login ${p.key}), then take it over`)
    const st = load(p.key)
    st.lease = L.takeover(leasesOf(p.key, metas), me)
    st.fp = store.fingerprint(c)
    save(p.key, st)
    lines.push(`${p.key}: taken over here, epoch ${st.lease.epoch}`)
  })
  await push(p, store, metas, lines)
  return lines
}

export async function hold(spec: string, on: string, force: boolean): Promise<string[]> {
  const p = parse(spec), me = myId()
  const metas = await survey()
  let target = me, targetOs = os()
  if (on !== '.' && on !== 'here') {
    const m: Meta = metas.get(on) ?? fail(`can't reach ${on}, or it has no reflex-keys (hc machine ls); for this machine itself: --on here`)
    target = m.id; targetOs = m.os as any
  }
  if (targetOs !== 'darwin' && !process.env.REFLEX_KEYS_ANY_HOLDER) fail(`${on} isn't a Mac: a holder is a Mac for now`)
  const cur = leasesOf(p.key, metas).reduce((a, b) => (b.epoch > a.epoch ? b : a), L.NO_LEASE)
  if (!cur.epoch) fail(`nobody holds ${p.key}: seed it where it's signed in (reflex-keys seed ${p.key})`)
  if (cur.holder === target) return [`${p.key}: ${on} already holds it (epoch ${cur.epoch})`]
  const holderName = nameOf(cur.holder, metas)
  if (!force) {
    if (!holderName) fail(`the holder of ${p.key} (${shown(cur.holder)}) isn't reachable. If it's gone for good, sign in on ${on} and run hold ${p.key} --on ${on} --force`)
    return holderName === '.' ? release(p.key, target) : (await callJson<{lines: string[]}>(holderName, ['release', p.key, '--to', target])).lines
  }
  if (holderName) fail(`the holder of ${p.key} (${holderName === '.' ? 'this machine' : holderName}) is reachable: hand it over without --force`)
  return target === me ? takeover(p.key) : (await callJson<{lines: string[]}>(on, ['takeover', p.key])).lines
}

// ---- status --------------------------------------------------------------------------

export type Status = {
  profile: string; holder: string; holderId: string; here: 'holder' | 'receiver'; epoch: number; gen: number
  login: 'usable' | 'placeholder' | 'none' | 'unreadable'; where: string
  expires: number | null; loginEnds: number | null; refreshed: number | null
  current: string[]; behind: string[]; pendingHandover: string | null; error: string | null; warnings: string[]
}

export async function status(): Promise<Status[]> {
  const me = myId(), out: Status[] = []
  for (const key of known()) {
    const p = parse(key), store = storeFor(p), st: PState = load(key), warnings: string[] = []
    let c: any = null, login: Status['login'] = 'none'
    try { c = await store.read(); login = !c ? 'none' : store.usable(c) ? 'usable' : 'placeholder' } catch { login = 'unreadable' }
    if (!store.rotates && c) login = 'usable'
    const expires = c ? store.expiry(c) : null, loginEnds = c ? store.loginEnd(c) : null
    if (loginEnds && loginEnds - now() < 5 * 86_400_000) warnings.push(`the login ends ${ago(loginEnds)}: sign in again on the holder before then`)
    if (expires && expires < now()) warnings.push('the access token here has expired')
    if (st.lease.holder === me && store.rotates && login !== 'usable') warnings.push('this is the holder but its store has no usable login')
    if (st.lease.holder !== me && store.rotates && login === 'usable') warnings.push('a usable refresh token on a machine that is not the holder')
    const o = outbox(key)
    const acks = Object.values(st.acked)
    out.push({
      profile: key, holder: shown(st.lease.holder), holderId: st.lease.holder, here: st.lease.holder === me ? 'holder' : 'receiver',
      epoch: st.lease.epoch, gen: st.lease.gen, login, where: store.where, expires, loginEnds, refreshed: st.refreshed ?? null,
      current: acks.filter(a => a.epoch === st.lease.epoch && a.gen === st.lease.gen).map(a => a.name).sort(),
      behind: acks.filter(a => a.epoch !== st.lease.epoch || a.gen !== st.lease.gen).map(a => `${a.name} (gen ${a.gen})`).sort(),
      pendingHandover: o ? shown(o.to) : null, error: st.error ?? null, warnings,
    })
  }
  return out
}

export function statusText(xs: Status[]): string {
  if (!xs.length) return 'no profiles held or received here (reflex-keys seed SPEC on the Mac where it is signed in)'
  return xs.map(s => [
    `${s.profile}: held by ${s.holder}, epoch ${s.epoch}, gen ${s.gen}; here: ${s.here}, login ${s.login} (${s.where})`,
    `  access token ends ${ago(s.expires)}${s.loginEnds ? `; the login ends ${ago(s.loginEnds)}` : ''}${s.refreshed ? `; refreshed ${ago(s.refreshed)}` : ''}`,
    ...(s.here === 'holder' ? [`  current: ${s.current.join(', ') || '-'}${s.behind.length ? `; behind: ${s.behind.join(', ')}` : ''}`] : []),
    ...(s.pendingHandover ? [`  handover to ${s.pendingHandover} in flight`] : []),
    ...(s.error ? [`  error: ${s.error}`] : []),
    ...s.warnings.map(w => `  warning: ${w}`),
  ].join('\n')).join('\n')
}

export {say}
