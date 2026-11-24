// Profiles, laid out as scripts/reflex.sh's `reflex profile` makes them:
// ~/.reflex/profiles/<harness>/<name>/ (REFLEX_PROFILES overrides the root). The bare
// harness (`claude`, no name) is your own home and login.
import {homedir} from 'node:os'
import {join} from 'node:path'
import {fail, sha256} from './util'

export const HARNESSES = ['claude', 'codex', 'pi', 'agy', 'opencode', 'amp', 'grok'] as const
export type Harness = (typeof HARNESSES)[number]

export type Profile = {
  harness: Harness
  name: string            // '' for your own
  key: string             // claude, claude[work]
  dir: string | null      // the profile's folder (null for your own)
  home: string            // the real home reflex-keys runs in
  hhome: string           // the home the harness runs with (agy, opencode, amp, grok get their own)
  env: Record<string, string>   // what the harness runs with
}

export const home = () => process.env.HOME || homedir()
export const os = (): 'darwin' | 'linux' => (process.env.REFLEX_KEYS_OS as any) || (process.platform === 'darwin' ? 'darwin' : 'linux')
// Where a Claude or agy login lives: the Keychain on a Mac (REFLEX_KEYS_STORE=file for tests).
export const keychainStore = () => (process.env.REFLEX_KEYS_STORE ? process.env.REFLEX_KEYS_STORE === 'keychain' : os() === 'darwin')

export function parse(spec: string): Profile {
  const m = /^([a-z]+)(?:\[([^\]]*)\])?$/.exec(spec) ?? fail(`not a profile: ${spec} (claude, claude[NAME], codex[NAME], ...)`)
  const harness = m[1] as Harness, name = m[2] ?? ''
  if (!HARNESSES.includes(harness)) fail(`no harness ${harness} (${HARNESSES.join(', ')})`)
  if (m[2] !== undefined && (!/^[a-z0-9._-]+$/.test(name) || name.startsWith('.'))) fail("a profile name is lowercase letters, digits, '.', '_' or '-'")
  const h = home()
  const dir = name ? join(process.env.REFLEX_PROFILES || join(h, '.reflex', 'profiles'), harness, name) : null
  const env: Record<string, string> = {REFLEX_HARNESS_PROFILE: `${harness}[${name}]`}
  let hhome = h
  if (dir) {
    if (harness === 'claude') env.CLAUDE_CONFIG_DIR = join(dir, 'claude')
    else if (harness === 'codex') env.CODEX_HOME = join(dir, 'codex')
    else if (harness === 'pi') env.PI_CODING_AGENT_DIR = join(dir, 'pi')
    else { hhome = join(dir, 'home'); env.HOME = hhome }
  }
  return {harness, name, key: name ? `${harness}[${name}]` : harness, dir, home: h, hhome, env}
}

// Claude Code's own folder and its Keychain item's name: `Claude Code-credentials`, and
// with CLAUDE_CONFIG_DIR set, `-` and the first 8 hex of sha256 of that string as given.
export const claudeDir = (p: Profile) => p.env.CLAUDE_CONFIG_DIR ?? join(p.home, '.claude')
export const claudeService = (p: Profile) =>
  'Claude Code-credentials' + (p.env.CLAUDE_CONFIG_DIR ? '-' + sha256(p.env.CLAUDE_CONFIG_DIR.normalize('NFC')).slice(0, 8) : '')
export const claudeAccount = () => {
  const u = process.env.USER || ''
  return /^[a-zA-Z0-9._-]+$/.test(u) ? u : 'claude-code-user'
}
export const codexHome = (p: Profile) => p.env.CODEX_HOME ?? join(p.home, '.codex')
export const piDir = (p: Profile) => p.env.PI_CODING_AGENT_DIR ?? join(p.home, '.pi', 'agent')

// The harness binaries: a scheduled tick has a bare PATH.
export function harnessPath() {
  const h = home()
  const extra = [join(h, '.local', 'bin'), join(h, '.bun', 'bin'), join(h, '.amp', 'bin'), '/opt/homebrew/bin', '/usr/local/bin']
  return [process.env.REFLEX_KEYS_PATH, process.env.PATH, ...extra].filter(Boolean).join(':')
}
