// The other machines, through herdr-core: `hc machine ls` lists them, `hc exec --on M -i`
// runs reflex-keys there with a payload on stdin (never in argv). A box gets the binary at
// ~/.local/bin/reflex-keys.
import type {Lease} from './lease'
import {redact} from './util'

export type Meta = {id: string; os: string; version: string; profiles: Record<string, Lease & {pending?: boolean}>}
export type Reply = {code: number; out: string; err: string}

const HC = () => process.env.REFLEX_KEYS_HC || 'hc'
const REMOTE = 'exec "$HOME/.local/bin/reflex-keys" "$@"'

export async function machines(): Promise<string[]> {
  const p = Bun.spawn([HC(), 'machine', 'ls', '--json'], {stdin: 'ignore', stdout: 'pipe', stderr: 'pipe', timeout: 30_000})
  const out = await new Response(p.stdout).text()
  if ((await p.exited) !== 0) return []
  try {
    const j = JSON.parse(out)
    return (j.machines ?? []).filter((m: any) => m.state === 'connected').map((m: any) => String(m.name))
  } catch { return [] }
}

export async function call(machine: string, args: string[], input?: string, timeout = 120_000): Promise<Reply> {
  const p = Bun.spawn([HC(), 'exec', '--on', machine, '-i', '--timeout', String(Math.ceil(timeout / 1000)), '--', 'sh', '-c', REMOTE, 'reflex-keys', ...args], {
    stdin: input === undefined ? 'ignore' : new Blob([input]), stdout: 'pipe', stderr: 'pipe', timeout: timeout + 15_000,
  })
  const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()])
  return {code: await p.exited, out, err}
}

export async function callJson<T = any>(machine: string, args: string[], input?: string): Promise<T> {
  const r = await call(machine, args, input)
  let j: any
  try { j = JSON.parse(r.out) } catch {}
  if (r.code !== 0 || j === undefined) {
    const why = j?.error ?? (r.err.trim().split('\n').slice(-1)[0] || `exit ${r.code}`)
    throw new Error(`${machine}: ${redact(why)}`)
  }
  return j
}
