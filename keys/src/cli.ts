#!/usr/bin/env bun
// reflex-keys: one machine per profile (the holder) refreshes its harness login, early,
// and sends the result to every other machine; the others hold a placeholder instead of
// a usable refresh token. Design: docs/profiles.md. Protocol and its proofs: keys/laws/.
//
//   reflex-keys seed SPEC                 this Mac, where SPEC is signed in, becomes its holder
//   reflex-keys tick                      run every few minutes on each Mac: refresh what's due
//                                         (holder), take newer copies, send them to who's behind
//   reflex-keys hold SPEC --on MACHINE    hand the lease to MACHINE (its current holder stops first)
//                         [--force]       ... when the holder is gone for good: MACHINE, signed in
//                                         again, takes it over at a higher epoch
//   reflex-keys status [--json]           per profile: holder, epoch, generation, expiry, who's current
//
// Between reflex-keys processes (stdin/stdout JSON, never argv):
//   receive                               apply a copy from stdin
//   export SPEC                           this machine's copy (with a placeholder) on stdout
//   meta | whoami                         what this machine knows (no secrets)
//   release SPEC --to ID                  (on the holder) stop and hand over to machine ID
//   takeover SPEC                         (on the next holder) the forced takeover
//
// SPEC: claude, claude[NAME], codex[NAME], pi[NAME], agy[NAME], opencode[NAME], amp[NAME], grok[NAME].
import {exportCopy, hold, meta, receive, release, seed, status, statusText, takeover, tick, VERSION} from './ops'
import {myId} from './state'
import {Fail, redact} from './util'

const usage = 'usage: reflex-keys seed SPEC | tick | hold SPEC --on MACHINE [--force] | status [--json] | receive | export SPEC | meta | release SPEC --to ID | takeover SPEC'

async function main(argv: string[]): Promise<number> {
  const [cmd, ...rest] = argv
  const flag = (f: string) => { const i = rest.indexOf(f); if (i < 0) return undefined; const v = rest[i + 1]; rest.splice(i, 2); return v }
  const has = (f: string) => { const i = rest.indexOf(f); if (i < 0) return false; rest.splice(i, 1); return true }
  const json = (v: unknown) => process.stdout.write(JSON.stringify(v) + '\n')
  const print = (lines: string[]) => { for (const l of lines) process.stderr.write(redact(l) + '\n') }
  switch (cmd) {
    case 'seed': { if (rest.length !== 1) break; print(await seed(rest[0])); return 0 }
    case 'tick': { const quiet = has('--quiet'); const lines = await tick(); if (!quiet) print(lines); return 0 }
    case 'hold': {
      const on = flag('--on'), force = has('--force')
      if (!on || rest.length !== 1) break
      print(await hold(rest[0], on, force)); return 0
    }
    case 'status': {
      const j = has('--json'), xs = await status()
      if (j) json(xs); else process.stdout.write(statusText(xs) + '\n')
      return 0
    }
    case 'receive': {
      const input = await new Response(Bun.stdin.stream()).text()
      let pl: any
      try { pl = JSON.parse(input) } catch { throw new Fail('receive: stdin is not JSON') }
      json(await receive(pl)); return 0
    }
    case 'export': { if (rest.length !== 1) break; json(await exportCopy(rest[0])); return 0 }
    case 'meta': case 'whoami': json(meta()); return 0
    case 'release': { const to = flag('--to'); if (!to || rest.length !== 1) break; json({lines: await release(rest[0], to)}); return 0 }
    case 'takeover': { if (rest.length !== 1) break; json({lines: await takeover(rest[0])}); return 0 }
    case 'id': process.stdout.write(myId() + '\n'); return 0
    case '--version': case 'version': process.stdout.write(VERSION + '\n'); return 0
    case undefined: case '-h': case '--help': case 'help': process.stdout.write(usage + '\n'); return 0
  }
  process.stderr.write(usage + '\n')
  return 2
}

main(process.argv.slice(2)).then(code => process.exit(code), (e: any) => {
  const msg = e instanceof Fail ? e.message : e?.message ?? String(e)
  // Callers on another machine read the error from stdout.
  if (['receive', 'export', 'meta', 'release', 'takeover'].includes(process.argv[2])) process.stdout.write(JSON.stringify({error: redact(msg)}) + '\n')
  process.stderr.write(`reflex-keys: ${redact(msg)}\n`)
  process.exit(1)
})
