// Where each harness keeps its login, and how the holder makes the harness refresh it.
// Content is the login as it travels: only the parts reflex-keys copies.
import type {Profile} from '../profile'
import {redact, fail, sha256} from '../util'
import {harnessPath} from '../profile'

export type Content = any

export interface Store {
  rotates: boolean        // its refresh token works once (the holder alone may refresh)
  where: string           // where the login is kept (no secrets)
  read(): Promise<Content | null>
  usable(c: Content): boolean          // holds a usable refresh token (or, not rotating, a login)
  strip(c: Content): Content           // the copy with a placeholder in place of the refresh token
  write(c: Content, token: boolean): Promise<void>   // token false: stripped first
  expiry(c: Content): number | null    // when the access token ends (ms)
  loginEnd(c: Content): number | null  // when the login itself ends, if it does
  fingerprint(c: Content): string      // changes whenever the login does (a hash, never the values)
  due(c: Content): boolean             // the holder should make the harness refresh now
  refresh(c: Content): Promise<string> // make the harness refresh; what happened
  guard<T>(fn: () => Promise<T>): Promise<T>   // keeps the harness from refreshing meanwhile, where it can
}

export const fp = (...parts: unknown[]) => sha256(JSON.stringify(parts)).slice(0, 16)

export const margin = (harness: string, dflt: number) => {
  const v = process.env[`REFLEX_KEYS_MARGIN_${harness.toUpperCase()}`] ?? process.env.REFLEX_KEYS_MARGIN
  return v ? Number(v) * 1000 : dflt
}

// Run a harness command with the profile's env; its output is the harness's, kept from logs but for a redacted tail.
export async function run(p: Profile, argv: string[], extraEnv: Record<string, string> = {}, opts: {timeout?: number; drop?: string[]} = {}) {
  const env: Record<string, string | undefined> = {...process.env, ...p.env, PATH: harnessPath(), ...extraEnv}
  for (const k of opts.drop ?? []) delete env[k]
  let proc
  try {
    proc = Bun.spawn(argv, {env: env as any, stdin: 'ignore', stdout: 'ignore', stderr: 'pipe', timeout: opts.timeout ?? 120_000, killSignal: 'SIGTERM'})
  } catch (e: any) { return fail(`couldn't run ${argv[0]}: ${e.message}`) }
  const err = await new Response(proc.stderr).text()
  const code = await proc.exited
  if (code !== 0) fail(`${argv.slice(0, 3).join(' ')} exited ${code}${proc.signalCode ? ` (${proc.signalCode})` : ''}: ${redact(err.trim().split('\n').slice(-2).join(' '))}`)
}
