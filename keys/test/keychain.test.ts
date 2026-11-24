// The Keychain stores (Claude's item, agy's in a profile Keychain), against temp
// Keychains made under a temp folder: never named "login", every read and write naming
// them by path (REFLEX_KEYS_KEYCHAIN for what would go to your default one), no search
// list or default changed, deleted afterwards. Your default Keychain and search list are
// checked unchanged, and nothing lands in your Keychain.
//
// `security` takes the default Keychain from $HOME: a write without a Keychain under a temp
// HOME that has no default asks you about a missing Keychain (a GUI dialog). keychain.ts
// refuses such a write.
import {afterAll, beforeAll, describe, expect, test} from 'bun:test'
import {spawnSync} from 'node:child_process'
import {existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import * as kc from '../src/keychain'
import {parse, claudeService} from '../src/profile'
import {storeFor} from '../src/stores'

// Opt in (REFLEX_KEYS_KEYCHAIN_TESTS=1): it makes and deletes real (temp) Keychains on this Mac.
const mac = process.platform === 'darwin' && process.env.REFLEX_KEYS_KEYCHAIN_TESTS === '1'
const realHome = process.env.HOME!
const sec = (args: string[]) => spawnSync('/usr/bin/security', args, {encoding: 'utf8', timeout: 20_000})
const real = () => ({def: sec(['default-keychain', '-d', 'user']).stdout, list: sec(['list-keychains', '-d', 'user']).stdout})

describe.skipIf(!mac)('Keychain stores', () => {
  let T = '', K = '', PK = '', before = {def: '', list: ''}
  const saved = {...process.env}
  beforeAll(() => {
    before = real()
    T = mkdtempSync(join(tmpdir(), 'reflex-keys-kc-'))
    K = join(T, 'reflex-keys-test.keychain-db')
    expect(sec(['create-keychain', '-p', 'test-only-pw', K]).status).toBe(0)
    expect(sec(['unlock-keychain', '-p', 'test-only-pw', K]).status).toBe(0)
    expect(real()).toEqual(before)
    Object.assign(process.env, {HOME: T, USER: 'tester', REFLEX_KEYS_STORE: 'keychain', REFLEX_KEYS_OS: 'darwin', REFLEX_KEYS_KEYCHAIN: K})
  })
  afterAll(() => {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k]
    Object.assign(process.env, saved)
    for (const k of [PK, K]) if (k && existsSync(k)) sec(['delete-keychain', k])
    rmSync(T, {recursive: true, force: true})
    expect(real()).toEqual(before)
    expect(sec(['find-generic-password', '-a', 'tester']).status).toBe(44)   // nothing in yours
  })

  test('a write to the default Keychain from another HOME is refused (no dialog)', () => {
    expect(() => kc.write({service: 'reflex-keys-test', account: 'tester', home: T}, 'x')).toThrow('name a Keychain')
  })

  test("Claude's item: written through security -i, read back, placeholder without refreshToken; a stray .credentials.json removed", async () => {
    const p = parse('claude[t]'), s = storeFor(p)
    mkdirSync(p.env.CLAUDE_CONFIG_DIR!, {recursive: true})
    writeFileSync(join(p.env.CLAUDE_CONFIG_DIR!, '.credentials.json'), '{}')
    const login = {claudeAiOauth: {accessToken: 'at-1', refreshToken: 'rt-1', expiresAt: Date.now() + 3_600_000, scopes: ['user:inference']}}
    await s.write(login, true)
    expect(await s.read()).toEqual(login)
    expect(existsSync(join(p.env.CLAUDE_CONFIG_DIR!, '.credentials.json'))).toBe(false)
    expect(sec(['find-generic-password', '-a', 'tester', '-s', claudeService(p), K]).status).toBe(0)
    expect(sec(['find-generic-password', '-s', claudeService(p)]).status).toBe(44)   // not in yours
    await s.write(login, false)
    const c = await s.read()
    expect(c.claudeAiOauth.accessToken).toBe('at-1')
    expect('refreshToken' in c.claudeAiOauth).toBe(false)
    expect(s.usable(c)).toBe(false)
  })

  test("agy's login in its profile Keychain, unlocked with the password kept in the default one", async () => {
    const p = parse('agy[t]'), s = storeFor(p)
    PK = join(p.hhome, 'Library', 'Keychains', 'reflex-profile.keychain-db')
    mkdirSync(join(p.hhome, 'Library', 'Keychains'), {recursive: true})
    expect(sec(['create-keychain', '-p', 'profile-pw', PK]).status).toBe(0)
    expect(sec(['add-generic-password', '-U', '-s', 'Reflex profile keychain', '-a', 'agy/t', '-w', 'profile-pw', K]).status).toBe(0)
    sec(['lock-keychain', PK])
    await s.write({value: '{"token":"g-1"}'}, false)   // not rotating: copied as is
    expect(await s.read()).toEqual({value: '{"token":"g-1"}'})
    expect(sec(['find-generic-password', '-s', 'gemini', '-a', 'antigravity', PK]).status).toBe(0)
    expect(real()).toEqual(before)
  })
})
void realHome
