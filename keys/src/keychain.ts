// macOS Keychain items through /usr/bin/security. Secrets go in on stdin (`security -i`)
// and come out on stdout, never in argv.
import {spawnSync} from 'node:child_process'
import {fail} from './util'

const SECURITY = '/usr/bin/security'
const env = (home?: string) => (home ? {...process.env, HOME: home} : process.env)
const q = (s: string) => {
  if (/["\n\\]/.test(s)) fail(`a Keychain name can't hold quotes, backslashes or newlines: ${s}`)
  return `"${s}"`
}

export type Item = {service: string; account: string; keychain?: string; home?: string}

export function read(it: Item): string | null {
  const args = ['find-generic-password', '-a', it.account, '-s', it.service, '-w', ...(it.keychain ? [it.keychain] : [])]
  const r = spawnSync(SECURITY, args, {env: env(it.home), encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']})
  if (r.status === 44) return null   // errSecItemNotFound
  if (r.status !== 0) fail(`reading the Keychain item "${it.service}" failed (security exit ${r.status}): ${(r.stderr ?? '').trim()}`)
  return r.stdout.replace(/\n$/, '')
}

export function present(it: Item): boolean {
  const args = ['find-generic-password', '-a', it.account, '-s', it.service, ...(it.keychain ? [it.keychain] : [])]
  return spawnSync(SECURITY, args, {env: env(it.home), stdio: 'ignore'}).status === 0
}

function interactive(line: string, home?: string) {
  // security -i reads a line of at most about 4 KB
  if (line.length > 4000) fail('this login is too long to hand to security on stdin')
  const r = spawnSync(SECURITY, ['-i'], {env: env(home), input: line + '\nquit\n', encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe']})
  if (r.status !== 0) fail(`security -i failed (exit ${r.status})`)
  return r
}

// Add or replace, then read back: security -i doesn't report a failed command in its exit code.
export function write(it: Item, value: string) {
  const hex = Buffer.from(value, 'utf8').toString('hex')
  interactive(`add-generic-password -U -a ${q(it.account)} -s ${q(it.service)} -X ${q(hex)}${it.keychain ? ' ' + q(it.keychain) : ''}`, it.home)
  if (read(it) !== value) fail(`writing the Keychain item "${it.service}" didn't take (is that Keychain unlocked?)`)
}

export function unlock(keychain: string, password: string, home?: string) {
  interactive(`unlock-keychain -p ${q(password)} ${q(keychain)}`, home)
  const r = spawnSync(SECURITY, ['show-keychain-info', keychain], {env: env(home), stdio: 'ignore'})
  if (r.status !== 0) fail(`couldn't unlock ${keychain}`)
}
