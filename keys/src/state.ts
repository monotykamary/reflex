// What this machine knows, under ~/.reflex/keys (REFLEX_KEYS_DIR): per profile its lease
// and what each machine last confirmed; a handover not yet delivered (outbox, 0600: it
// holds the refresh token until the next holder has it); the machines last seen.
import {hostname} from 'node:os'
import {randomBytes} from 'node:crypto'
import {mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs'
import {join} from 'node:path'
import {NO_LEASE, type Lease, type Stamp} from './lease'
import {dirLock} from './lock'
import {home} from './profile'
import {readJson, writeJson} from './util'

export const keysDir = () => process.env.REFLEX_KEYS_DIR || join(home(), '.reflex', 'keys')

// This machine: Reflex's own id (`reflex id`), made the same way if it isn't there yet.
export function myId(): string {
  const f = join(home(), '.reflex', 'id')
  try { const s = readFileSync(f, 'utf8').trim(); if (s) return s } catch {}
  mkdirSync(join(home(), '.reflex'), {recursive: true})
  const id = `${hostname().split('.')[0]}-${randomBytes(4).toString('hex')}`
  writeFileSync(f, id + '\n')
  return id
}

export type Ack = {name: string; epoch: number; gen: number; at: number}
export type PState = {
  lease: Lease
  fp?: string               // the store's fingerprint when gen was last set
  acked: Record<string, Ack>
  refreshed?: number; refreshNote?: string
  error?: string; errorAt?: number
}
export type Outbox = {to: string; stamp: Stamp; content: unknown; at: number}

const file = (key: string) => join(keysDir(), 'profiles', `${key}.json`)
const outFile = (key: string) => join(keysDir(), 'outbox', `${key}.json`)

export function load(key: string): PState {
  const st = readJson<PState>(file(key)) ?? {lease: NO_LEASE, acked: {}}
  st.acked ??= {}
  // A handover written to the outbox has happened, whatever the record says.
  const o = outbox(key)
  if (o && o.stamp.epoch > st.lease.epoch) st.lease = {epoch: o.stamp.epoch, holder: o.stamp.holder, gen: o.stamp.gen}
  return st
}
export const save = (key: string, st: PState) => writeJson(file(key), st)

export function known(): string[] {
  try { return readdirSync(join(keysDir(), 'profiles')).filter(f => f.endsWith('.json')).map(f => f.slice(0, -5)).sort() } catch { return [] }
}

export const outbox = (key: string) => readJson<Outbox>(outFile(key))
export const setOutbox = (key: string, o: Outbox) => { mkdirSync(join(keysDir(), 'outbox'), {recursive: true, mode: 0o700}); writeJson(outFile(key), o) }
export const clearOutbox = (key: string) => rmSync(outFile(key), {force: true})

// One change to a profile's record at a time, on this machine. Never held across a call to
// another machine (two machines pushing to each other would wait on each other).
export const withProfile = <T>(key: string, fn: () => Promise<T>) =>
  dirLock(join(keysDir(), 'locks', `${key}.lock`), fn, {stale: 10 * 60_000, wait: 180_000, what: `reflex-keys' record of ${key}`})

export type Peer = {id: string; os: string; at: number}
export const peers = (): Record<string, Peer> => readJson(join(keysDir(), 'peers.json')) ?? {}
export const savePeers = (p: Record<string, Peer>) => writeJson(join(keysDir(), 'peers.json'), p)
