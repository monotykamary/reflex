// The protocol's laws (laws/protocol.ts): proven and kernel-checked; each broken variant
// refused by a real run; and src/lease.ts (what reflex-keys runs) held to the proven rule.
import {describe, expect, test} from 'bun:test'
import {holder, laws, ops} from '../laws/protocol'
import {broken, verdict} from '../laws/prove'
import * as L from '../src/lease'

describe('the holder protocol', () => {
  test('its laws are proven and checked, from no assumed invariant', () => {
    const v = verdict(holder)
    expect(v).toMatchObject({proven: true, checked: true})
    expect(v.assumes).toBeUndefined()
  }, 120_000)

  for (const [name, r] of Object.entries(broken))
    test(`refused: ${name}`, () => {
      const v = verdict(r, {search: {ms: 20_000}})
      expect(v.proven).toBe(false)
      expect(v.run).toBeDefined()   // a real run from the start breaks a law
    }, 120_000)

  test('the laws agree with their own arithmetic (crossCheck)', () => {
    const {invariants, steps} = laws(holder)
    const c = holder.crossCheck(invariants, steps, {trials: 300, depth: 12, bound: 4})
    expect(c.failure).toBeUndefined()
    expect(c.checked).toBeGreaterThan(0)
  }, 120_000)
})

// One machine's code, run on every machine of a simulated network, beside the rule.
type Machine = {lease: L.Lease; token: boolean}
const id = (k: number) => `m${k}`

function simulate() {
  const ms = new Map<number, Machine>()
  const at = (k: number) => ms.get(k) ?? {lease: L.NO_LEASE, token: false}
  let handed = 0, top = 0, epoch = 0, flight: {send: L.Stamp; to: number; from: number} | null = null, last = {mE: 0, mG: 0, mTo: 0}
  const take = (k: number, r: L.Receipt) => { if (r.kind === 'apply') ms.set(k, {lease: r.lease, token: r.token}) }
  return {
    step(op: (typeof ops)[number], m: number, to: number) {
      const a = at(m)
      if (op === 'seed') {
        const s = L.seed([...ms.values()].map(x => x.lease), id(m))
        if ('lease' in s) { ms.set(m, {lease: s.lease, token: true}); epoch = s.lease.epoch; top = Math.max(top, s.lease.gen) }
      } else if (op === 'refresh') {
        if (a.token) { const l = L.renumber(a.lease); ms.set(m, {lease: l, token: true}); top = Math.max(top, l.gen) }
      } else if (op === 'push') {
        if (m !== to && flight?.from !== m) take(to, L.receive(at(to).lease, id(to), L.stamp(a.lease)))
      } else if (op === 'release') {
        const r = flight ? {error: 'busy'} : L.release(a.lease, id(m), id(to), a.token)
        if ('lease' in r) {
          ms.set(m, {lease: r.lease, token: false})
          flight = {send: r.send, to, from: m}; epoch = r.lease.epoch
          last = {mE: r.send.epoch, mG: r.send.gen, mTo: to}
        }
      } else if (op === 'deliver') {
        if (flight) { take(flight.to, L.receive(at(flight.to).lease, id(flight.to), flight.send)); flight = null; handed++ }
      }
    },
    view(k: number) { const x = at(k); return {E: x.lease.epoch, G: x.lease.gen, R: x.lease.holder === id(k) ? 1 : 0, F: x.token ? 1 : 0} },
    handed: () => handed,
    holder: () => [0, 1, 2, 3].find(k => at(k).lease.holder === id(k)),
    scalars: () => ({top, epoch, inflight: flight ? 1 : 0, ...last}),
  }
}

test('lease.ts makes the proven rule\'s decisions, step by step', () => {
  const rule = holder.compiled(), ps = holder.encodeParams({})
  let seed = 7
  const rand = (n: number) => { // mulberry32
    seed = (seed + 0x6d2b79f5) | 0
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) % n
  }
  let steps = 0, applied = 0, handed = 0
  for (let trial = 0; trial < 400; trial++) {
    let st: any = rule.init(ps)
    const sim = simulate()
    for (let i = 0; i < 30; i++) {
      const op = ops[rand(ops.length)], h = sim.holder(), m = h !== undefined && rand(2) === 0 ? h : rand(4), to = rand(4)
      st = rule.step(ps, st, holder.encodeInput({op, m, to}))
      sim.step(op, m, to)
      steps++
      for (const [name, want] of Object.entries(sim.scalars()))
        expect([trial, i, name, st.scalars[name]]).toEqual([trial, i, name, want])
      for (let k = 0; k < 4; k++)
        for (const [name, want] of Object.entries(sim.view(k))) {
          const got = st.maps[name].get(k) ?? 0
          expect([trial, i, op, m, to, name, k, got]).toEqual([trial, i, op, m, to, name, k, want])
        }
      if (op === 'deliver' || op === 'release') applied++
    }
    handed += sim.handed()
  }
  expect(steps).toBe(12_000)
  expect(applied).toBeGreaterThan(100)
  expect(handed).toBeGreaterThan(50)
})
