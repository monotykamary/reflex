// The holder protocol's decisions, one machine's view. Pure: no files, no network.
// laws/protocol.ts states the same protocol as a gdp-wired rule over every machine and
// proves its laws; test/laws.test.ts runs these functions beside that rule's compiled
// machine on random runs and requires they agree at every step.
//
// A profile's lease: `epoch` goes up at every handover, `holder` is the machine (its
// Reflex id) that alone refreshes during that epoch, `gen` numbers the copies of the
// login the holder has made (it goes up each time the holder's store changes).

export type Lease = {epoch: number; holder: string; gen: number}
export const NO_LEASE: Lease = {epoch: 0, holder: '', gen: 0}

// What travels with a copy. `full`: it carries the usable refresh token (only a
// handover to `holder` does); every other copy carries a placeholder.
export type Stamp = {epoch: number; holder: string; gen: number; full: boolean}

export type Receipt =
  | {kind: 'ignore'; lease: Lease; why: string}
  | {kind: 'conflict'; lease: Lease; why: string}
  // content: write the copy's login into the store. token: keep a usable refresh token
  // (only when this machine becomes the holder); otherwise the store holds a placeholder.
  | {kind: 'apply'; lease: Lease; content: boolean; token: boolean}

export function receive(mine: Lease, me: string, p: Stamp): Receipt {
  if (p.epoch < mine.epoch) return {kind: 'ignore', lease: mine, why: `an older lease (epoch ${p.epoch} < ${mine.epoch})`}
  if (p.epoch === mine.epoch && p.epoch > 0 && mine.holder !== '' && p.holder !== mine.holder)
    return {kind: 'conflict', lease: mine, why: `two holders at epoch ${p.epoch}: ${mine.holder} and ${p.holder}`}
  if (p.full) {
    if (p.holder !== me) return {kind: 'conflict', lease: mine, why: `a full copy addressed to ${p.holder}`}
    if (p.epoch === mine.epoch && mine.holder === me) return {kind: 'ignore', lease: mine, why: 'already the holder'}
    return {kind: 'apply', lease: {epoch: p.epoch, holder: me, gen: Math.max(mine.gen, p.gen)}, content: true, token: true}
  }
  const leaseNewer = p.epoch > mine.epoch
  const contentNewer = p.gen > mine.gen || (p.gen === mine.gen && leaseNewer)
  if (!leaseNewer && !contentNewer) return {kind: 'ignore', lease: mine, why: 'not newer'}
  if (!leaseNewer && mine.holder === me) return {kind: 'ignore', lease: mine, why: 'this machine is the holder'}
  return {
    kind: 'apply',
    lease: {epoch: Math.max(mine.epoch, p.epoch), holder: leaseNewer ? p.holder : mine.holder, gen: contentNewer ? p.gen : mine.gen},
    content: contentNewer,
    token: false,
  }
}

// The copy this machine sends to others: never the refresh token.
export const stamp = (mine: Lease): Stamp => ({epoch: mine.epoch, holder: mine.holder, gen: mine.gen, full: false})

// Only the holder, with a usable login in its store, makes the harness refresh.
export const mayRefresh = (mine: Lease, me: string, token: boolean): boolean => mine.holder === me && token

// The holder's store changed (its harness refreshed): the next copy's number.
export const renumber = (mine: Lease): Lease => ({...mine, gen: mine.gen + 1})

// Handover: the holder stops (its store then holds a placeholder) and sends its newest
// copy, with the token, to the next holder at the next epoch.
export function release(mine: Lease, me: string, to: string, token: boolean): {lease: Lease; send: Stamp} | {error: string} {
  if (mine.holder !== me) return {error: `this machine isn't the holder (${mine.holder || 'none'} is)`}
  if (!token) return {error: "the holder's store has no usable login to hand over"}
  if (to === me) return {error: 'already the holder'}
  const lease = {epoch: mine.epoch + 1, holder: to, gen: mine.gen}
  return {lease, send: {...lease, full: true}}
}

// The first holder: only where no machine knows of a lease for the profile.
export function seed(known: Lease[], me: string): {lease: Lease} | {error: string} {
  const held = known.find(l => l.epoch > 0)
  if (held) return {error: `already held by ${held.holder} at epoch ${held.epoch}: hand it over with hold`}
  return {lease: {epoch: 1, holder: me, gen: 1}}
}

// A forced takeover (the old holder gone for good): a fresh sign-in here, at an epoch
// above every one known. Not covered by the at-most-one law: an old holder that comes
// back refreshes until it sees the higher epoch (receive above stops it).
export function takeover(known: Lease[], me: string): Lease {
  const epoch = Math.max(0, ...known.map(l => l.epoch)) + 1
  const gen = Math.max(0, ...known.map(l => l.gen)) + 1
  return {epoch, holder: me, gen}
}

// Newer than: by generation, then epoch (what receive applies).
export const newer = (a: {epoch: number; gen: number}, b: {epoch: number; gen: number}) =>
  a.epoch >= b.epoch && (a.gen > b.gen || (a.gen === b.gen && a.epoch > b.epoch))
