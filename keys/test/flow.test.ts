// End to end: three machines (two Macs, a Linux box) through a fake hc, the real CLI on
// each, fake harnesses refreshing against a fake server whose refresh tokens work once.
import {afterAll, describe, expect, test} from 'bun:test'
import {account, jwt, refresh, signIn} from './fakes/server'
import {readJ, world, writeJ, type World} from './world'

const H = 3_600_000
const worlds: World[] = []
afterAll(() => { for (const w of worlds) w.done() })

function setup() {
  const w = world({work: 'darwin', studio: 'darwin', box: 'linux'})
  worlds.push(w)
  process.env.WORLD = w.root   // the fake server, read from this process too
  return w
}
const ok = (r: {code: number | null; out: string; err: string}) => { if (r.code !== 0) throw new Error(`exit ${r.code}: ${r.err}${r.out}`); return r }
const status = (w: World, m: string) => JSON.parse(ok(w.run(m, ['status', '--json'])).out) as any[]
const noSecrets = (w: World) => expect(w.transcript()).not.toMatch(/rt:[a-z]+:\d|at:[a-z]+:\d/)

describe('claude[work]', () => {
  const claudeFile = (w: World, m: string) => w.path(m, '.reflex', 'profiles', 'claude', 'work', 'claude', '.credentials.json')
  const signInClaude = (w: World, m: string, acct: string, expiresIn = 8 * H) => writeJ(claudeFile(w, m), {
    claudeAiOauth: {accessToken: `at:${acct}:0`, refreshToken: signIn(acct), expiresAt: Date.now() + expiresIn, refreshTokenExpiresAt: Date.now() + 30 * 24 * H,
      scopes: ['user:inference', 'user:profile'], subscriptionType: 'max'},
    designOauth: {keep: true},
  })

  test('seed, refresh early, push; a handover; a box away catches up; no token spent twice', () => {
    const w = setup()
    // An old copy of the login on the box (as `reflex creds` left it).
    signInClaude(w, 'work', 'ann')
    writeJ(claudeFile(w, 'box'), readJ(claudeFile(w, 'work')))

    ok(w.run('work', ['seed', 'claude[work]']))
    for (const m of ['studio', 'box']) {
      const c = readJ(claudeFile(w, m))
      expect(c.claudeAiOauth.accessToken).toBe('at:ann:0')
      expect('refreshToken' in c.claudeAiOauth).toBe(false)   // a placeholder: no usable token, never ""
    }
    expect(status(w, 'work')[0]).toMatchObject({profile: 'claude[work]', here: 'holder', epoch: 1, gen: 1, login: 'usable', current: ['box', 'studio']})
    expect(w.run('work', ['seed', 'claude[work]']).err).toContain('already held by this machine')
  })

  test('a second seed anywhere is refused', () => {
    const w = setup()
    signInClaude(w, 'work', 'bob')
    ok(w.run('work', ['seed', 'claude[work]']))
    signInClaude(w, 'studio', 'bob2')
    const r = w.run('studio', ['seed', 'claude[work]'])
    expect(r.code).toBe(1)
    expect(r.err).toContain('already held by work')
  })

  // What Claude's daemon does on the holder: refresh, keeping everything else.
  const daemonRefresh = (w: World, m: string) => {
    const all = readJ(claudeFile(w, m)), got = refresh(all.claudeAiOauth.refreshToken)!
    writeJ(claudeFile(w, m), {...all, claudeAiOauth: {...all.claudeAiOauth, accessToken: got.access, refreshToken: got.refresh, expiresAt: Date.now() + 8 * H}})
  }

  test("a refresh on the holder is a new generation, pushed; tick never makes Claude refresh; a box away catches up", () => {
    const w = setup()
    signInClaude(w, 'work', 'cat', 1 * H)
    ok(w.run('work', ['seed', 'claude[work]']))
    w.down('box')
    ok(w.run('studio', ['tick']))
    ok(w.run('work', ['tick']))
    expect(account('cat').refreshes).toBe(0)     // Claude refreshes itself (its daemon); tick doesn't
    daemonRefresh(w, 'work')
    const t = ok(w.run('work', ['tick']))
    expect(t.err).toContain('the login changed here: gen 2')
    const held = readJ(claudeFile(w, 'work')).claudeAiOauth
    expect(readJ(claudeFile(w, 'work')).designOauth).toEqual({keep: true})
    expect(readJ(claudeFile(w, 'studio')).claudeAiOauth.accessToken).toBe(held.accessToken)
    expect('refreshToken' in readJ(claudeFile(w, 'studio')).claudeAiOauth).toBe(false)
    // the box was away: on the next tick it catches up
    expect(readJ(claudeFile(w, 'box')).claudeAiOauth.accessToken).toBe('at:cat:0')
    w.up('box')
    ok(w.run('work', ['tick']))
    expect(readJ(claudeFile(w, 'box')).claudeAiOauth.accessToken).toBe(held.accessToken)
    expect(status(w, 'work')[0]).toMatchObject({gen: 2, current: ['box', 'studio']})
    expect(account('cat')).toMatchObject({refreshes: 1, spent: 0})
    noSecrets(w)
  })

  test('hold --on hands over: the old holder stops first, the new one has the newest copy and refreshes', () => {
    const w = setup()
    signInClaude(w, 'work', 'dan')
    ok(w.run('work', ['seed', 'claude[work]']))
    const r = ok(w.run('box', ['hold', 'claude[work]', '--on', 'studio']))   // run from anywhere
    expect(r.err).toContain('handed to studio')
    expect('refreshToken' in readJ(claudeFile(w, 'work')).claudeAiOauth).toBe(false)
    expect(readJ(claudeFile(w, 'studio')).claudeAiOauth.refreshToken).toBe(account('dan').current)
    expect(status(w, 'studio')[0]).toMatchObject({here: 'holder', epoch: 2, gen: 1, login: 'usable'})
    expect(status(w, 'work')[0]).toMatchObject({here: 'receiver', epoch: 2, holder: 'studio'})
    // the new holder's refresh works (it has the newest token) and reaches the old holder
    daemonRefresh(w, 'studio')
    ok(w.run('studio', ['tick']))
    expect(account('dan')).toMatchObject({refreshes: 1, spent: 0})
    expect(readJ(claudeFile(w, 'work')).claudeAiOauth.accessToken).toBe(readJ(claudeFile(w, 'studio')).claudeAiOauth.accessToken)
    noSecrets(w)
  })

  test('a holder away: hold without --force is refused; --force after a fresh sign-in, and the old holder stops when it returns', () => {
    const w = setup()
    signInClaude(w, 'work', 'eve')
    ok(w.run('work', ['seed', 'claude[work]']))
    w.down('work')
    const r = w.run('studio', ['hold', 'claude[work]', '--on', 'here'])
    expect(r.code).toBe(1)
    expect(r.err).toContain("isn't reachable")
    // --force wants a fresh sign-in there
    expect(w.run('studio', ['hold', 'claude[work]', '--on', 'here', '--force']).err).toContain('sign in here first')
    signInClaude(w, 'studio', 'eve')   // a new login (the old one's token on work is now stale)
    ok(w.run('studio', ['hold', 'claude[work]', '--on', 'here', '--force']))
    expect(status(w, 'studio')[0]).toMatchObject({here: 'holder', epoch: 2})
    w.up('work')
    // work comes back due for a refresh: it sees epoch 2 first and stops, spending nothing
    const t = ok(w.run('work', ['tick']))
    expect(t.err).toContain('took')
    expect(status(w, 'work')[0]).toMatchObject({here: 'receiver', epoch: 2, login: 'placeholder'})
    expect(account('eve').spent).toBe(0)
  })

  test('receive never replaces a newer copy with an older one, and refuses a token not addressed to it', () => {
    const w = setup()
    signInClaude(w, 'work', 'fay', 1 * H)
    ok(w.run('work', ['seed', 'claude[work]']))
    const old = JSON.parse(ok(w.run('work', ['export', 'claude[work]'])).out)
    expect(JSON.stringify(old)).not.toContain('rt:')   // an export carries no refresh token
    daemonRefresh(w, 'work'); ok(w.run('work', ['tick']))   // gen 2
    const res = JSON.parse(ok(w.run('box', ['receive'], JSON.stringify(old))).out)
    expect(res).toMatchObject({kind: 'ignore', lease: {gen: 2}})
    expect(readJ(claudeFile(w, 'box')).claudeAiOauth.accessToken).not.toBe('at:fay:0')
    const forged = {...old, kind: 'copy', stamp: {...old.stamp, full: true}}
    expect(w.run('box', ['receive'], JSON.stringify(forged)).code).toBe(1)
  })

  test('a usable login on a machine that is not the holder is replaced by a placeholder', () => {
    const w = setup()
    signInClaude(w, 'work', 'gus')
    ok(w.run('work', ['seed', 'claude[work]']))
    writeJ(claudeFile(w, 'studio'), readJ(claudeFile(w, 'work')))   // copied by hand
    expect(status(w, 'studio')[0].warnings.join()).toContain('not the holder')
    ok(w.run('studio', ['tick']))
    expect('refreshToken' in readJ(claudeFile(w, 'studio')).claudeAiOauth).toBe(false)
  })
})

describe('codex[w] and pi[w]', () => {
  test('codex: seed, a forced early refresh through the app server, a handover', () => {
    const w = setup()
    const f = (m: string) => w.path(m, '.reflex', 'profiles', 'codex', 'w', 'codex', 'auth.json')
    writeJ(f('work'), {auth_mode: 'chatgpt', OPENAI_API_KEY: null, tokens: {id_token: 'x', access_token: jwt(Date.now() + 3 * 24 * H), refresh_token: signIn('hal'), account_id: 'acct-1'}, last_refresh: new Date().toISOString()})
    ok(w.run('work', ['seed', 'codex[w]']))
    expect(readJ(f('box')).tokens.refresh_token).toBe('')
    ok(w.run('work', ['tick']))
    expect(account('hal').refreshes).toBe(0)                       // not due
    ok(w.run('work', ['tick'], undefined, {REFLEX_KEYS_MARGIN_CODEX: String(4 * 24 * 3600)}))
    expect(account('hal')).toMatchObject({refreshes: 1, spent: 0})
    expect(readJ(f('box')).tokens.access_token).toBe(readJ(f('work')).tokens.access_token)
    expect(readJ(f('box')).tokens.refresh_token).toBe('')
    ok(w.run('work', ['hold', 'codex[w]', '--on', 'studio']))
    expect(readJ(f('studio')).tokens.refresh_token).toBe(account('hal').current)
    expect(readJ(f('work')).tokens.refresh_token).toBe('')
    // another account's auth.json is never replaced
    writeJ(f('box'), {tokens: {access_token: 'a', refresh_token: '', account_id: 'other'}})
    ok(w.run('studio', ['tick']))
    expect(readJ(f('box')).tokens.account_id).toBe('other')
    expect(w.transcript()).toContain('another account')
    noSecrets(w)
  })

  test('pi: rotating providers get a placeholder, Copilot is copied as is; pi refreshes on the holder only', () => {
    const w = setup()
    const f = (m: string) => w.path(m, '.reflex', 'profiles', 'pi', 'w', 'pi', 'auth.json')
    writeJ(f('work'), {
      anthropic: {type: 'oauth', refresh: signIn('ivy'), access: 'at:ivy:0', expires: Date.now() + 1 * H},
      'github-copilot': {type: 'oauth', refresh: 'gho_static', access: 'cop', expires: Date.now() + 1 * H},
    })
    writeJ(f('box'), {openai: {type: 'api_key', key: 'mine'}})
    ok(w.run('work', ['seed', 'pi[w]']))
    const box = readJ(f('box'))
    expect(box.anthropic.refresh).toBe('reflex-keys:not-the-holder')
    expect(box['github-copilot'].refresh).toBe('gho_static')
    expect(box.openai).toEqual({type: 'api_key', key: 'mine'})     // the box's own entry stays
    ok(w.run('work', ['tick']))
    expect(account('ivy')).toMatchObject({refreshes: 1, spent: 0})
    expect(readJ(f('box')).anthropic.access).toBe(readJ(f('work')).anthropic.access)
    noSecrets(w)
  })
})
