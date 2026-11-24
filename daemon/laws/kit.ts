// What every law file hands the runner: a rule (or decisions), its laws,
// the bugs they rule out, and the real code each rule is held to.

import type {Decision, Rule, StepLaw} from 'gdp-wired'
import {proveDecision, proveSteps} from 'gdp-wired'

type Law = Parameters<typeof proveSteps>[1][number]
// biome-ignore lint: rules of any shape
type AnyRule = Rule<any, any, any, any, any, any, any, any>

export type Agreement = {checked: number; failure?: string; exhaustive?: boolean}
export type Held = {against: string; run: () => Agreement; exhaustive?: boolean}
export type Broken = {what: string; rule?: AnyRule; laws?: Law[]; steps?: StepLaw[]; decision?: Decision}
export type Entry = {
  area: string
  rule?: AnyRule
  laws?: Law[]
  steps?: StepLaw[]
  decisions?: Decision[]
  from?: 'any'
  broken: Broken[]
  held: Held[]
}

// A small seeded generator: rand(seed)(n) is 0..n-1.
export function rand(seed: number): (n: number) => number {
  let s = seed >>> 0 || 1
  return (n: number) => {
    s ^= s << 13
    s >>>= 0
    s ^= s >>> 17
    s ^= s << 5
    s >>>= 0
    return n <= 0 ? 0 : s % n
  }
}

type Step = {
  init(params: Record<string, number>): void
  // The request the rule takes, and the real code's state after the same
  // request: its scalars and its maps (missing keys read 0). A failure is
  // where they part.
  step(request: Record<string, unknown>, scalars: Record<string, number>, maps: Record<string, Map<number, number>>): string | undefined
}

// The rule's compiled machine run beside real code, its maps compared too
// (rule.compare compares scalars and lists).
export function mapsHold(r: AnyRule, trials: number, _depth: number, body: (step: Step) => string | undefined): Agreement {
  const g = r.compiled()
  let checked = 0
  for (let t = 0; t < trials; t++) {
    let ps: Record<string, number> = {}
    let st: ReturnType<typeof g.init> | undefined
    const trace: unknown[] = []
    const failure = body({
      init(params) {
        ps = r.encodeParams(params as never)
        st = g.init(ps)
      },
      step(request, scalars, maps) {
        trace.push(request)
        st = g.step(ps, st!, r.encodeInput(request as never))
        checked++
        const s = st as unknown as {scalars: Record<string, number>; maps: Record<string, Map<number, number>>}
        for (const [k, v] of Object.entries(scalars))
          if (s.scalars[k] !== v) return `${r.name}: ${k} is ${s.scalars[k]} in the rule, ${v} in the code, after ${JSON.stringify(trace)}`
        for (const [name, want] of Object.entries(maps)) {
          const got = s.maps[name] ?? new Map()
          const keys = new Set([...got.keys(), ...want.keys()])
          for (const k of keys)
            if ((got.get(k) ?? 0) !== (want.get(k) ?? 0))
              return `${r.name}: ${name}[${k}] is ${got.get(k) ?? 0} in the rule, ${want.get(k) ?? 0} in the code, after ${JSON.stringify(trace)}`
        }
        return undefined
      },
    })
    if (failure) return {checked, failure}
  }
  return {checked}
}

export type Row = {area: string; law: string; how: string; verdict: string; ok: boolean}

const ms = (t0: number) => `${Math.round(performance.now() - t0)} ms`

// Prove every law of an entry (proven && checked, and from every state the
// laws allow where the code is handed states), refute each broken variant,
// and hold the rule to the real code.
export function run(e: Entry): Row[] {
  const rows: Row[] = []
  const name = e.rule?.name ?? e.decisions?.[0]?.rule.name ?? '?'
  if (e.rule) {
    const t0 = performance.now()
    const v = proveSteps(e.rule, e.laws ?? [], e.steps ?? [], e.from ? {from: 'any'} : {})
    const ok = v.proven && v.checked && !v.assumes
    const how = `rule '${name}' (${e.from ? "proveSteps {from: 'any'}" : 'proveSteps'})`
    for (const l of [...(e.laws ?? []), ...(e.steps ?? [])])
      rows.push({area: e.area, law: l.name, how, verdict: ok ? `proven, checked (${ms(t0)} for the rule)` : `NOT PROVEN: ${v.goal} ${v.stuck} ${v.why ?? ''}`, ok})
  }
  for (const d of e.decisions ?? []) {
    const t0 = performance.now()
    const v = proveDecision(d)
    const ok = v.proven && v.checked
    rows.push({area: e.area, law: d.name, how: `fun '${d.rule.name}' (proveDecision)`, verdict: ok ? `proven, checked (${ms(t0)})` : `NOT PROVEN: ${v.goal} ${v.stuck} ${v.why ?? ''}`, ok})
  }
  for (const b of e.broken) {
    const t0 = performance.now()
    const v = b.decision ? proveDecision(b.decision) : proveSteps(b.rule!, b.laws ?? [], b.steps ?? [], e.from ? {from: 'any', search: {ms: 4000}} : {search: {ms: 4000}})
    const refuted = !v.proven
    rows.push({
      area: e.area,
      law: `broken: ${b.what}`,
      how: `the same laws on the broken '${name}'`,
      verdict: refuted ? `refused at ${v.goal ?? '?'}${v.run ? ' (a run breaks it)' : v.witness ? ' (a state breaks it)' : ''} (${ms(t0)})` : 'PROVEN: the broken variant got through',
      ok: refuted,
    })
  }
  for (const h of e.held) {
    const t0 = performance.now()
    const a = h.run()
    const ok = !a.failure && a.checked > 0 && (h.exhaustive ? a.exhaustive === true : true)
    rows.push({
      area: e.area,
      law: `held to ${h.against}`,
      how: `'${name}' run beside the real code`,
      verdict: a.failure ? `DIFFERS: ${a.failure}` : `agrees on ${a.checked} ${a.exhaustive ? 'cases (every one)' : 'steps'} (${ms(t0)})`,
      ok,
    })
  }
  return rows
}
