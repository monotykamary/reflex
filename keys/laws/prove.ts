// bun laws/prove.ts: prove the holder protocol's laws, refute the broken variants, print the verdicts.
import {proveSteps} from 'gdp-wired'
import {holder, holderRule, laws} from './protocol'

export function verdict(r: ReturnType<typeof holderRule>, opts: object = {}) {
  const {invariants, steps} = laws(r)
  const t = Date.now()
  const v: any = proveSteps(r, invariants, steps, opts as any)
  return {proven: v.proven, checked: v.checked, assumes: v.assumes, goal: v.goal, stuck: v.stuck, run: v.run, found: v.found?.laws?.map((l: any) => l.source), ms: Date.now() - t}
}

export const broken = {
  'handover without stopping the old holder': holderRule({stopOnRelease: false}),
  'a forced takeover without the old holder': holderRule({force: true}),
  'a receiver without the version check': holderRule({versionCheck: false}),
  'a push that carries the token': holderRule({placeholder: false}),
  'a handover that sends an older copy': holderRule({sendNewest: false}),
}

if (import.meta.main) {
  console.log('holder', JSON.stringify(verdict(holder)))
  for (const [name, r] of Object.entries(broken)) {
    const v = verdict(r, {search: {ms: 20_000}})
    console.log(name, JSON.stringify({proven: v.proven, goal: v.goal, stuck: v.stuck, run: v.run}))
  }
}
