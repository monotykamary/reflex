// The holder protocol as a gdp-wired rule over every machine (any number: maps keyed by
// machine), and its laws. src/lease.ts is one machine's side of it; test/laws.test.ts
// proves these laws, keeps the broken variants refused, and runs lease.ts beside the
// compiled rule.
//
// Per machine k:  E[k] the lease epoch it knows,  G[k] the generation of its copy,
//                 R[k] 1 when its record names itself holder,
//                 F[k] 1 when its harness store holds a usable refresh token (the
//                      harness can refresh, and so spend the token, only then).
// The network: at most one handover in flight (inflight, its epoch mE, generation mG,
// receiver mTo). top: the newest generation ever made; epoch: the newest epoch.
//
// Requests: seed (the first holder), refresh (a harness refreshes: only with a usable
// token), push (machine m sends its copy, with a placeholder, to machine `to`), release
// (the holder m stops and sends its copy with the token toward `to`), deliver (the
// handover arrives).

import {forall, max, nat, not, oneOf, rule, when} from 'gdp-wired'

export const ops = ['seed', 'refresh', 'push', 'release', 'deliver'] as const

const base = rule('reflex-keys holder')
  .inputs({op: oneOf(...ops), m: nat, to: nat})
  .state({top: 0, epoch: 0, inflight: 0, mE: 0, mG: 0, mTo: 0})
  .maps({E: 0, G: 0, R: 0, F: 0})

type Variant = {
  stopOnRelease?: boolean   // the old holder stops at a handover
  sendNewest?: boolean      // a handover carries the holder's newest copy
  versionCheck?: boolean    // a receiver keeps a newer copy
  placeholder?: boolean     // a pushed copy carries a placeholder, not the token
  force?: boolean           // a forced takeover exists (seed may run again with a lease held)
}

export function holderRule(v: Variant = {}) {
  const {stopOnRelease = true, sendNewest = true, versionCheck = true, placeholder = true, force = false} = v
  return base
    .flags(({op, m, to, epoch, inflight, mE, E, G, R, F}) => {
      const older = E.at(m).lt(E.at(to))
      const leaseNewer = E.at(m).gt(E.at(to))
      const contentNewer = G.at(m).gt(G.at(to)).or(G.at(m).eq(G.at(to)).and(leaseNewer))
      const toHolds = R.at(to).eq(1).and(not(leaseNewer))
      const pushing = op.is('push').and(not(m.eq(to)))
        // the old holder doesn't push while its handover is in flight
        .and(not(inflight.eq(1).and(E.at(m).eq(mE))))
      return {
        seeding: op.is('seed').and(force ? E.at(m).lt(epoch).or(epoch.eq(0)) : epoch.eq(0)),
        refreshing: op.is('refresh').and(F.at(m).eq(1)),
        applying: versionCheck
          ? pushing.and(not(older)).and(leaseNewer.or(contentNewer)).and(not(toHolds))
          : pushing,
        takesContent: versionCheck ? contentNewer : pushing,
        leaseUp: leaseNewer,
        releasing: op.is('release').and(R.at(m).eq(1)).and(F.at(m).eq(1)).and(inflight.eq(0)).and(not(m.eq(to))),
        delivering: op.is('deliver').and(inflight.eq(1)),
      }
    })
    .step(({m, to, top, epoch, inflight, mE, mG, mTo, E, G, R, F, seeding, refreshing, applying, takesContent, leaseUp, releasing, delivering}) => {
      const at = (k: any, who: any) => k.eq(who)
      const nextEpoch = epoch.plus(1)
      const seedGen = force ? top.plus(1) : 1
      return {
        E: E.each(k => when(seeding.and(at(k, m)), nextEpoch,
          when(applying.and(at(k, to)), max(E.at(k), E.at(m)),
            when(releasing.and(at(k, m)), nextEpoch,
              when(delivering.and(at(k, mTo)), mE, E.at(k)))))),
        G: G.each(k => when(seeding.and(at(k, m)), seedGen,
          when(refreshing.and(at(k, m)), G.at(k).plus(1),
            when(applying.and(takesContent).and(at(k, to)), G.at(m),
              when(delivering.and(at(k, mTo)), max(G.at(k), mG), G.at(k)))))),
        R: R.each(k => when(seeding.and(at(k, m)), 1,
          when(applying.and(leaseUp).and(at(k, to)), 0,
            when(releasing.and(at(k, m)), stopOnRelease ? 0 : 1,
              when(delivering.and(at(k, mTo)), 1, R.at(k)))))),
        F: F.each(k => when(seeding.and(at(k, m)), 1,
          when(applying.and(at(k, to)), placeholder ? 0 : 1,
            when(releasing.and(at(k, m)), stopOnRelease ? 0 : 1,
              when(delivering.and(at(k, mTo)), 1, F.at(k)))))),
        top: when(seeding, max(top, seedGen), when(refreshing, max(top, G.at(m).plus(1)), top)),
        epoch: when(seeding.or(releasing), nextEpoch, epoch),
        inflight: when(releasing, 1, when(delivering, 0, inflight)),
        mE: when(releasing, nextEpoch, mE),
        mG: when(releasing, sendNewest ? G.at(m) : G.at(m).minus(1), mG),
        mTo: when(releasing, to, mTo),
      }
    })
}

export const holder = holderRule()

// The laws, stated against any variant of the rule.
export function laws(r: ReturnType<typeof holderRule>) {
  const invariants = [
    r.law('at most one handover is in flight', ({inflight}) => inflight.atMost(1)),
    r.law('lease and token flags are 0 or 1', ({R, F}) => forall(k => R.at(k).atMost(1).and(F.at(k).atMost(1)))),
    r.law('at most one machine can refresh (a usable token is in one store, or in flight to the next holder)',
      ({F, inflight}) => F.sum().plus(inflight).atMost(1)),
    r.law('at most one machine holds the lease', ({R, inflight}) => R.sum().plus(inflight).atMost(1)),
    r.law('a non-holder never stores a usable refresh token', ({R, F}) => forall(k => F.at(k).atMost(R.at(k)))),
    r.law('the holder has the newest generation', ({R, G, top}) => forall(k => R.at(k).eq(1).implies(G.at(k).eq(top)))),
    r.law('a handover in flight carries the newest generation and epoch',
      ({inflight, mG, mE, top, epoch}) => inflight.eq(1).implies(mG.eq(top).and(mE.eq(epoch)))),
    r.law('no copy is newer than the newest', ({G, E, top, epoch}) => forall(k => G.at(k).atMost(top).and(E.at(k).atMost(epoch)))),
    r.law('before the first seed nobody holds a lease or a token',
      ({epoch, R, F, inflight}) => epoch.eq(0).implies(R.sum().plus(F.sum()).plus(inflight).eq(0))),
    r.law('before the first seed no copy exists', ({top, epoch}) => epoch.eq(0).implies(top.atMost(0))),
    r.law('the holder knows the newest epoch', ({R, E, epoch}) => forall(k => R.at(k).eq(1).implies(E.at(k).eq(epoch)))),
  ]
  const steps = [
    r.stepLaw("a receiver's generation never decreases", ({G}, after) => forall(k => G.at(k).atMost(after.G.at(k)))),
    r.stepLaw("a receiver's epoch never decreases", ({E}, after) => forall(k => E.at(k).atMost(after.E.at(k)))),
    r.stepLaw('after a handover the new holder has the newest generation',
      ({mTo}, after) => after.G.at(mTo).eq(after.top).and(after.R.at(mTo).eq(1)).and(after.F.at(mTo).eq(1)),
      ({delivering}) => delivering),
  ]
  return {invariants, steps}
}
