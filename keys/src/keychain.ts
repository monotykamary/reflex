// macOS Keychain items through /usr/bin/security. Secrets go in on stdin (`security -i`)
// and come out on stdout, never in argv.
import {spawnSync} from 'node:child_process'
import {userInfo} from 'node:os'
import {fail} from './util'

const SECURITY = '/usr/bin/security'
const env = (home?: string) => (home ? {...process.env, HOME: home} : process.env)
const q = (s: string) => {
  if (/["\n\\]/.test(s)) fail(`a Keychain name can't hold quotes, backslashes or newlines: ${s}`)
  return `"${s}"`
}

export type Item = {service: string; account: string; keychain?: string; home?: string}

// Your default Keychain, or the one REFLEX_KEYS_KEYCHAIN names (tests: a temp Keychain).
export const defaultKeychain = () => process.env.REFLEX_KEYS_KEYCHAIN || undefined

// `security` finds the default Keychain from the account, not from $HOME: a write with no
// Keychain named, under another HOME, would go to (or ask about) your own. Refused.
function guard(it: Item) {
  if (it.keychain) return
  const h = it.home ?? process.env.HOME
  if (h && h !== userInfo().homedir) fail(`not writing "${it.service}" to the default Keychain from another HOME (${h}): name a Keychain`)
}

export function read(it: Item): string | null {
  const args = ['find-generic-password', '-a', it.account, '-s', it.service, '-w', ...(it.keychain ? [it.keychain] : [])]
  const r = spawnSync(SECURITY, args, {env: env(it.home), encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 20_000})
  if (r.status === 44) return null   // errSecItemNotFound
  if (r.status !== 0) fail(`reading the Keychain item "${it.service}" failed (security exit ${r.status}): ${(r.stderr ?? '').trim()}`)
  return r.stdout.replace(/\n$/, '')
}

export function present(it: Item): boolean {
  const args = ['find-generic-password', '-a', it.account, '-s', it.service, ...(it.keychain ? [it.keychain] : [])]
  return spawnSync(SECURITY, args, {env: env(it.home), stdio: 'ignore', timeout: 20_000}).status === 0
}

function interactive(line: string, home?: string) {
  // security -i reads a line of at most about 4 KB
  if (line.length > 4000) fail('this login is too long to hand to security on stdin')
  const r = spawnSync(SECURITY, ['-i'], {env: env(home), input: line + '\nquit\n', encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 20_000})
  if (r.status !== 0) fail(`security -i failed (exit ${r.status})`)
  return r
}

// Add or replace, then read back: security -i doesn't report a failed command in its exit code.
export function write(it: Item, value: string) {
  guard(it)
  const hex = Buffer.from(value, 'utf8').toString('hex')
  interactive(`add-generic-password -U -a ${q(it.account)} -s ${q(it.service)} -X ${q(hex)}${it.keychain ? ' ' + q(it.keychain) : ''}`, it.home)
  if (read(it) !== value) fail(`writing the Keychain item "${it.service}" didn't take (is that Keychain unlocked?)`)
}

export function unlock(keychain: string, password: string, home?: string) {
  interactive(`unlock-keychain -p ${q(password)} ${q(keychain)}`, home)
  const r = spawnSync(SECURITY, ['show-keychain-info', keychain], {env: env(home), stdio: 'ignore', timeout: 20_000})
  if (r.status !== 0) fail(`couldn't unlock ${keychain}`)
}
