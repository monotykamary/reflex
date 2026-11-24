// Fake claude, codex and pi: just the commands reflex-keys runs, against the fake server.
//   claude auth login            (CLAUDE_CODE_OAUTH_REFRESH_TOKEN, CLAUDE_CODE_OAUTH_SCOPES)
//   codex app-server             (initialize, initialized, account/read {refreshToken: true})
//   pi auth print-bearer-token --provider X --min-expiry Nm
import {mkdirSync, readFileSync, renameSync, writeFileSync} from 'node:fs'
import {dirname, join} from 'node:path'
import {jwt, refresh} from './server'

const [tool, ...args] = process.argv.slice(2)
const home = process.env.HOME!
const readJ = (f: string) => { try { return JSON.parse(readFileSync(f, 'utf8')) } catch { return null } }
const writeJ = (f: string, v: unknown) => { mkdirSync(dirname(f), {recursive: true}); writeFileSync(`${f}.tmp`, JSON.stringify(v)); renameSync(`${f}.tmp`, f) }
const die = (m: string) => { process.stderr.write(m + '\n'); process.exit(1) }
const log = (m: string) => { if (process.env.FAKE_LOG) writeFileSync(process.env.FAKE_LOG, m + '\n', {flag: 'a'}) }

if (tool === 'claude') {
  if (args[0] !== 'auth' || args[1] !== 'login') die('fake claude: only auth login')
  const rt = process.env.CLAUDE_CODE_OAUTH_REFRESH_TOKEN ?? die('no refresh token')
  if (!process.env.CLAUDE_CODE_OAUTH_SCOPES) die('CLAUDE_CODE_OAUTH_SCOPES is required')
  const f = join(process.env.CLAUDE_CONFIG_DIR ?? join(home, '.claude'), '.credentials.json')
  const got = refresh(rt as string) ?? die("Couldn't log in: invalid_grant")
  const all = readJ(f) ?? {}
  // as the real one: a sign-in, which drops the login's end unless the server sends one
  const {refreshTokenExpiresAt: _, ...o} = all.claudeAiOauth ?? {}
  writeJ(f, {...all, claudeAiOauth: {...o, accessToken: got!.access, refreshToken: got!.refresh, expiresAt: Date.now() + 8 * 3_600_000, scopes: process.env.CLAUDE_CODE_OAUTH_SCOPES!.split(' ')}})
  log(`claude refreshed ${f}`)
} else if (tool === 'codex') {
  if (args[0] !== 'app-server') die('fake codex: only app-server')
  const f = join(process.env.CODEX_HOME ?? join(home, '.codex'), 'auth.json')
  let buf = ''
  const answer = (m: object) => process.stdout.write(JSON.stringify(m) + '\n')
  process.stdin.on('data', d => {
    buf += d
    let nl
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl); buf = buf.slice(nl + 1)
      const m = JSON.parse(line)
      if (m.method === 'initialize') answer({id: m.id, result: {userAgent: 'fake'}})
      else if (m.method === 'account/read') {
        if (m.params?.refreshToken) {
          const a = readJ(f)
          const got = a?.tokens && refresh(a.tokens.refresh_token)
          if (got) { a.tokens.refresh_token = got.refresh; a.tokens.access_token = jwt(Date.now() + 3 * 86_400_000); a.last_refresh = new Date().toISOString(); writeJ(f, a); log(`codex refreshed ${f}`) }
        }
        answer({id: m.id, result: {account: {type: 'chatgpt', email: null, planType: 'pro'}, requiresOpenaiAuth: true}})
        process.stdout.write('{"method":"account/updated","params":{}}\n')
      }
    }
  })
  process.stdin.on('end', () => process.exit(0))
} else if (tool === 'pi') {
  if (args[0] !== 'auth' || args[1] !== 'print-bearer-token') die('fake pi: only auth print-bearer-token')
  const provider = args[args.indexOf('--provider') + 1]
  const min = Number(args[args.indexOf('--min-expiry') + 1].replace(/m$/, '')) * 60_000
  const f = join(process.env.PI_CODING_AGENT_DIR ?? join(home, '.pi', 'agent'), 'auth.json')
  const a = readJ(f) ?? die('no auth.json')
  const e = a[provider] ?? die(`no ${provider}`)
  if (e.expires - Date.now() < min) {
    const got = refresh(e.refresh) ?? die('Token refresh failed: run /login')
    a[provider] = {...e, refresh: got!.refresh, access: got!.access, expires: Date.now() + 8 * 3_600_000}
    writeJ(f, a)
    log(`pi refreshed ${provider}`)
  }
  process.stdout.write(a[provider].access + '\n')
} else die(`fake: no ${tool}`)
