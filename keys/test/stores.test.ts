// The file and SQLite stores (amp, grok, opencode), the locks shared with the harnesses,
// and the atomic write, in a temp HOME.
import {afterAll, beforeAll, describe, expect, test} from 'bun:test'
import {Database} from 'bun:sqlite'
import {mkdirSync, mkdtempSync, rmSync, statSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import {dirLock, flock} from '../src/lock'
import {parse} from '../src/profile'
import {storeFor} from '../src/stores'
import {atomicWrite, redact} from '../src/util'
import {readJ, writeJ} from './world'

let T = ''
const saved = {...process.env}
beforeAll(() => { T = mkdtempSync(join(tmpdir(), 'reflex-keys-stores-')); Object.assign(process.env, {HOME: T, REFLEX_KEYS_STORE: 'file', REFLEX_KEYS_OS: 'linux'}) })
afterAll(() => {
  for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k]
  Object.assign(process.env, saved)
  rmSync(T, {recursive: true, force: true})
})

describe('stores', () => {
  test('grok: an oidc refresh token is left out of a copy; API keys stay', async () => {
    const p = parse('grok[t]'), s = storeFor(p), f = join(p.hhome, '.grok', 'auth.json')
    const login = {
      'https://auth.x.ai::b1a0': {key: 'k1', auth_mode: 'oidc', refresh_token: 'r1', expires_at: new Date(Date.now() + 3_600_000).toISOString(), create_time: new Date().toISOString()},
      'xai::api_key': {key: 'xai-1', auth_mode: 'api_key'},
    }
    writeJ(f, {other: {key: 'mine', auth_mode: 'api_key'}})
    expect(s.usable(login)).toBe(true)
    await s.write(login, false)
    const got = readJ(f)
    expect('refresh_token' in got['https://auth.x.ai::b1a0']).toBe(false)
    expect(got['xai::api_key'].key).toBe('xai-1')
    expect(got.other.key).toBe('mine')
    expect(s.usable(got)).toBe(false)
    expect(statSync(f).mode & 0o777).toBe(0o600)
  })

  test('amp: the API key copied as is, MCP OAuth tokens stay per machine', async () => {
    const p = parse('amp[t]'), s = storeFor(p), f = join(p.hhome, '.local', 'share', 'amp', 'secrets.json')
    writeJ(f, {'apiKey@https://ampcode.com/': 'old', 'mcp-oauth-token@x': 'here'})
    await s.write({'apiKey@https://ampcode.com/': 'new', 'mcp-oauth-token@x': 'there'}, false)
    expect(readJ(f)).toEqual({'apiKey@https://ampcode.com/': 'new', 'mcp-oauth-token@x': 'here'})
    expect(await s.read()).toEqual({'apiKey@https://ampcode.com/': 'new'})
  })

  test('opencode: rotating rows get refresh "" and expires 0; Copilot and keys as they are; other rows untouched', async () => {
    const p = parse('opencode[t]'), s = storeFor(p), f = join(p.hhome, '.local', 'share', 'opencode', 'opencode.db')
    mkdirSync(join(f, '..'), {recursive: true})
    const d = new Database(f, {create: true})
    d.exec('PRAGMA journal_mode = WAL')
    d.exec('CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT, value TEXT, active INTEGER, connector_id TEXT, method_id TEXT, time_created INTEGER, time_updated INTEGER)')
    d.query('INSERT INTO credential VALUES (?, ?, ?, ?, 1, NULL, ?, 1, 1)').run('cred_mcp', 'mcp:x', 'mcp', JSON.stringify({type: 'oauth', refresh: 'keep', access: 'a', expires: 5}), 'oauth')
    d.close()
    const rows = [
      {id: 'cred_oa', integration_id: 'openai', label: 'me', value: {type: 'oauth', methodID: 'chatgpt-browser', refresh: 'r1', access: 'a1', expires: Date.now() + 3_600_000}, active: 1, connector_id: null, method_id: 'chatgpt-browser', time_created: 2, time_updated: 2},
      {id: 'cred_gh', integration_id: 'github-copilot', label: 'gh', value: {type: 'oauth', methodID: 'device', refresh: 'gho', access: 'gho', expires: 0}, active: 1, connector_id: null, method_id: 'device', time_created: 2, time_updated: 2},
    ]
    expect(s.usable({rows})).toBe(true)
    await s.write({rows}, false)
    const got = (await s.read()).rows
    const oa = got.find((r: any) => r.id === 'cred_oa'), gh = got.find((r: any) => r.id === 'cred_gh')
    expect(oa.value).toMatchObject({refresh: '', expires: 0, access: 'a1'})
    expect(gh.value.refresh).toBe('gho')
    const db = new Database(f, {readonly: true})
    expect(JSON.parse((db.query("SELECT value FROM credential WHERE id = 'cred_mcp'").get() as any).value).refresh).toBe('keep')
    db.close()
    // a newer copy replaces the row in place
    await s.write({rows: [{...rows[0], value: {...rows[0].value, access: 'a2'}}]}, true)
    expect((await s.read()).rows.find((r: any) => r.id === 'cred_oa').value).toMatchObject({access: 'a2', refresh: 'r1'})
  })
})

describe('locks and writes', () => {
  test("flock excludes another process (as Codex's and grok's locks do)", async () => {
    const f = join(T, 'auth.lock')
    const other = Bun.spawn(['python3', '-I', '-c', `import fcntl,time,sys\nf=open(sys.argv[1],'a')\nfcntl.flock(f,fcntl.LOCK_EX)\nprint('held',flush=True)\ntime.sleep(1.5)`, f], {stdout: 'pipe'})
    const reader = other.stdout.getReader()
    await reader.read()   // 'held'
    const t = Date.now()
    await flock(f, () => {}, {wait: 10_000})
    expect(Date.now() - t).toBeGreaterThan(800)
    await other.exited
  })

  test('a directory lock waits for its holder, clears one a dead process left, and is reentrant', async () => {
    const l = join(T, 'x.lock')
    let inner = false
    await dirLock(l, () => dirLock(l, () => { inner = true }, {stale: 5_000}), {stale: 5_000})
    expect(inner).toBe(true)
    mkdirSync(l); Bun.write(`${l}.reflex-keys`, '999999')   // left by a process that's gone
    await dirLock(l, () => {}, {stale: 60_000, wait: 2_000})
    mkdirSync(l)                                              // someone else's, fresh
    await expect(dirLock(l, () => {}, {stale: 60_000, wait: 300})).rejects.toThrow('locked')
    rmSync(l, {recursive: true})
  })

  test('atomic write: private, replaces a link target, never a partial file', () => {
    const f = join(T, 'a.json')
    atomicWrite(f, '{"a":1}')
    expect(statSync(f).mode & 0o777).toBe(0o600)
    atomicWrite(f, '{"a":2}')
    expect(readJ(f)).toEqual({a: 2})
  })

  test('redact hides anything token-like', () => {
    expect(redact('failed: sk-ant-oat01-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 bad')).toBe('failed: […] bad')
    expect(redact('claude[work]: gen 3')).toBe('claude[work]: gen 3')
  })
})
