// Harness profiles (`reflex profile`, docs/profiles.md): an agent's profile
// from its label, a session's from sessions.tsv, a new or resumed session
// started in one through the profile runner, and the profile's own files.

import {expect, test} from 'bun:test'
import {chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import * as Hc from '../src/hc.ts'
import * as Js from '../src/js.ts'
import type {J} from '../src/js.ts'
import {type Cfg, Daemon} from '../src/main.ts'
import type {Agent, Folder} from '../src/model.ts'
import {agentJson} from '../src/model.ts'
import * as P from '../src/past.ts'
import * as R from '../src/route.ts'

const json = (s: string): J => {
  const r = Js.read(s)
  if (!r.ok) throw new Error(r.msg)
  return r.v
}

test('sessions.tsv: an 8th column is the profile; 7 columns are your own', () => {
  const ps = P.parse('claude\ta\t/a\tt\tl\t3\tpast\ttom\npi\tb\t/b\tt\tl\t1\tpast\ncodex\tc\t/c\tt\tl\t1\tpast\t\n')
  expect(ps.map((p) => p.profile)).toEqual(['tom', '', ''])
  expect(P.pastJson(ps[0]!)).toContain('"profile":"tom"')
  expect(P.pastJson(ps[1]!)).not.toContain('profile')
  expect(P.harness('claude', ps, 'tom').map((p) => p.id)).toEqual(['a'])
  expect(P.harness('claude', ps, 'ann')).toEqual([])
  expect(P.harness('claude', ps).map((p) => p.id)).toEqual(['a'])
})

test('an agent carries its profile from the reflex.profile label, and the agents JSON says so', () => {
  const t = json('{"address":"t3","name":"rx1-2","labels":{"reflex.kind":"claude","reflex.profile":"tom"},"status":{"app":"claude-code","state":"idle"}}')
  const a = Hc.agentOf(t)
  expect(a.profile).toBe('tom')
  expect(agentJson(a)).toEndWith(',"profile":"tom"}')
  expect(agentJson({...a, profile: ''})).not.toContain('profile')
  expect(Hc.stoppedOf(Js.done(json('{"terminals":[{"address":"t3","state":"finished","reason":"server_stop","labels":{"reflex.kind":"claude","reflex.profile":"tom"}}]}')))).toContain('"profile":"tom"')
})

test('a launch goes through the profile runner, labelled with its profile', () => {
  const run = json(Hc.pRun('/bin/zsh', 'rx1-1', '', '/w', 'claude', 's1', Hc.profiled('claude', 'tom', Hc.argv('claude', ['--session-id', 's1'], 'hi')), 'tom'))
  const argv = Js.asList(Js.get(run, 'argv')).map(Js.textOf)
  expect(argv.slice(0, 4)).toEqual(['/bin/zsh', '-lic', '"$@"; exec "$0" -li', '/bin/zsh'])
  expect(argv.slice(4)).toEqual(['sh', '-c', Hc.PROFILE_RUNNER, 'claude[tom]', '--session-id', 's1', 'hi'])
  expect(Js.textOf(Js.path(['labels', 'reflex.kind'], run))).toBe('claude')
  expect(Js.textOf(Js.path(['labels', 'reflex.profile'], run))).toBe('tom')
  // A bare kind: the machine's default profile for it, if any; codex keeps its flag.
  expect(Hc.profiled('codex', '', Hc.argv('codex', ['resume', 'x'], ''))).toEqual(['sh', '-c', Hc.PROFILE_RUNNER, 'codex', '--no-daemon', 'resume', 'x'])
  expect(Js.textOf(Js.path(['labels', 'reflex.profile'], json(Hc.pRun('/bin/zsh', 'n', '', '/w', 'pi', '', ['pi'], ''))))).toBe('')
  // On another machine, inside its own login shell.
  const far = Js.asList(Js.get(json(Hc.pRun('/bin/zsh', 'n', 'box', '/w', 'pi', '', Hc.profiled('pi', 'ann', ['pi']), 'ann')), 'argv')).map(Js.textOf)
  expect(far.slice(0, 2)).toEqual(['sh', '-c'])
  expect(far.slice(4)).toEqual(['sh', '-c', Hc.PROFILE_RUNNER, 'pi[ann]'])
})

test('the runner: reflex profile run SPEC ARGS where reflex is, else the harness itself', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'rx-runner-'))
  try {
    const out = join(dir, 'out')
    writeFileSync(join(dir, 'claude'), `#!/bin/sh\nprintf 'claude %s\\n' "$*" > "${out}"\n`)
    chmodSync(join(dir, 'claude'), 0o755)
    const go = async (path: string, specArg: string) => {
      const p = Bun.spawn(['/bin/sh', '-c', Hc.PROFILE_RUNNER, specArg, '--resume', 'x y'], {env: {PATH: path}})
      await p.exited
      return readFileSync(out, 'utf8')
    }
    expect(await go(`${dir}:/usr/bin:/bin`, 'claude[tom]')).toBe('claude --resume x y\n')
    // A reflex from before profiles: the harness itself.
    writeFileSync(join(dir, 'reflex'), `#!/bin/sh\necho "reflex: unknown command $1" >&2; exit 1\n`)
    chmodSync(join(dir, 'reflex'), 0o755)
    expect(await go(`${dir}:/usr/bin:/bin`, 'claude[tom]')).toBe('claude --resume x y\n')
    writeFileSync(join(dir, 'reflex'), `#!/bin/sh\n[ "$1 $2" = "profile ls" ] && exit 0\nprintf 'reflex %s|' "$@" > "${out}"\n`)
    chmodSync(join(dir, 'reflex'), 0o755)
    expect(await go(`${dir}:/usr/bin:/bin`, 'claude[tom]')).toBe('reflex profile|reflex run|reflex claude[tom]|reflex --resume|reflex x y|')
    expect(await go(`${dir}:/usr/bin:/bin`, 'claude')).toBe('reflex profile|reflex run|reflex claude|reflex --resume|reflex x y|')
  } finally {
    rmSync(dir, {recursive: true, force: true})
  }
})

test("a profiled agent's own files are its profile's", () => {
  expect(Hc.sessionFile('/Users/me', '42')).toBe('/Users/me/.claude/sessions/42.json')
  expect(Hc.sessionFile('/Users/me', '42', 'tom')).toBe('/Users/me/.reflex/profiles/claude/tom/claude/sessions/42.json')
  expect(Hc.harnessDir('/Users/me', 'pi', 'ann')).toBe('/Users/me/.reflex/profiles/pi/ann/pi')
})

const agent = (pane: string, kind: string, profile: string): Agent => ({pane, name: pane, kind, status: 'idle', cwd: '/Users/me/VCS/app', title: '', seq: 1, session: 's', screen: '', parent: '', profile})
const folder: Folder = {path: '/Users/me/VCS/app', name: 'app', desc: '', recent: '', branch: '', age: 1, uses: 0}

test("routing: a resume keeps its session's profile; a new session takes the default's", () => {
  const p: P.Past = {agent: 'claude', id: 'i', cwd: '/a', title: 'earlier', last: 'x', age: 1, state: 'past', profile: 'tom'}
  expect(R.resumeAction(p, 'go on')).toEqual({type: 'resume', cwd: '/a', kind: 'claude', session: 'i', mode: 'resume', text: 'go on', profile: 'tom'})
  expect(R.resumeLabel(p)).toBe('resume claude[tom] · earlier')
  const want: R.Pick = {key: 'f0', bp: 9000, all: [{key: 'f0', bp: 9000}]}
  const d = R.decide('fix it', '/Users/me', 'claude[tom]', 6000, [], [folder], undefined, want, 0)
  expect(d).toMatchObject({d: 'go', label: 'new claude[tom] in app', action: {type: 'spawn', kind: 'claude', profile: 'tom'}})
  // A harness named in the request is that harness, your own.
  const named = R.decide('fix it with pi', '/Users/me', 'claude[tom]', 6000, [], [folder], undefined, want, 0)
  expect(named).toMatchObject({d: 'go', action: {type: 'spawn', kind: 'pi'}})
  expect((named as {action: {profile?: string}}).action.profile).toBeUndefined()
  // A side question to a profiled pi forks in its profile.
  const side = R.agentDecision(true, agent('t1', 'pi', 'ann'), 'btw why', '/Users/me', 'claude')
  expect(side).toMatchObject({d: 'go', action: {type: 'fork', profile: 'ann'}, label: 'btw → fork of pi[ann] · app'})
})

test('resume arguments: opencode and amp by id; claude, pi, codex and agy as before', () => {
  expect(R.resumeArgs('opencode', 'resume', 'x')).toEqual(['--session', 'x'])
  expect(R.resumeArgs('opencode', 'continue', '')).toEqual(['--continue'])
  expect(R.resumeArgs('amp', 'resume', 'T-1')).toEqual(['threads', 'continue', 'T-1'])
  expect(R.resumeArgs('claude', 'fork', 'x')).toEqual(['--resume', 'x', '--fork-session'])
  expect(R.resumeArgs('claude', 'attach', 'x')).toEqual(['attach', 'x'])
  expect(R.resumeArgs('pi', 'fork', 'x')).toEqual(['--fork', 'x'])
  expect(R.resumeArgs('pi', 'resume', 'x')).toEqual(['--session', 'x'])
  expect(R.resumeArgs('codex', 'resume', 'x')).toEqual(['resume', 'x'])
  expect(R.resumeArgs('codex', 'continue', '')).toEqual(['resume', '--last'])
  expect(R.resumeArgs('agy', 'fork', 'x')).toEqual(['--conversation', 'x'])
  expect(R.resumeArgs('grok', 'resume', 'x')).toEqual(['--resume', 'x'])
})

test('the API: spawn and resume take a profile; candidates keep to it', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'rx-api-'))
  try {
    // A Jev that is sure of the first folder.
    const jev = join(dir, 'jev')
    writeFileSync(jev, `#!/bin/sh\ncat > "${dir}/asked"\necho banner\necho '{"ok":true,"result":{"answers":{"folder":{"choice":"f0","probabilities":{"f0":1.0}}}}}'\n`)
    chmodSync(jev, 0o755)
    writeFileSync(join(dir, 'sessions.tsv'), 'claude\ta\t/a\tmine\tl\t1\tpast\ntom-claude\tb\t/b\tt\tl\t1\tpast\nclaude\tc\t/c\ttheirs\tl\t1\tpast\ttom\n')
    const cfg: Cfg = {
      sock: join(dir, 'h.sock'),
      core: join(dir, 'c.sock'),
      shell: '/bin/zsh',
      backend: 'core',
      link: join(dir, 'l.sock'),
      bind: '127.0.0.1',
      port: 0,
      token: 't',
      jev,
      harness: 'claude',
      threshold: 6000,
      home: '/Users/me',
      data: dir,
      web: dir,
      scan: '/usr/bin/true',
      fork: '/usr/bin/true',
      undo: 100000,
      shown: false,
    }
    const d = new Daemon(cfg)
    d.post({m: 'polled', ok: true, agents: [agent('t1', 'claude', ''), agent('t2', 'claude', 'tom'), agent('t3', 'pi', '')]})
    d.post({m: 'indexed', folders: [folder]})
    const body = (o: object) => json(JSON.stringify(o))
    const call = async (path: string, o: object) => {
      const raw = String(await d.endpoint(path, {method: 'POST', path, query: [], headers: [], body: ''}, body(o)))
      return json(raw.slice(raw.indexOf('\r\n\r\n') + 4))
    }
    const sp = await call('/api/spawn', {cwd: '/Users/me/VCS/app', kind: 'claude', profile: 'tom', text: ''})
    expect(Js.textAt(sp, 'label')).toBe('new claude[tom] in app')
    expect(Js.textOf(Js.path(['action', 'profile'], sp))).toBe('tom')
    const rs = await call('/api/resume', {cwd: '/a', kind: 'claude', profile: 'tom', session: 'c', mode: 'resume', text: ''})
    expect(Js.textOf(Js.path(['action', 'profile'], rs))).toBe('tom')
    const plain = await call('/api/spawn', {cwd: '/Users/me/VCS/app', kind: 'pi', text: ''})
    expect(JSON.stringify(Js.get(plain, 'action'))).not.toContain('profile')

    await call('/api/candidates', {text: 'look', harness: 'claude', profile: 'tom'})
    let asked = readFileSync(join(dir, 'asked'), 'utf8')
    expect(asked).toContain('a0: claude[tom] agent in')
    expect(asked).not.toContain('a1:')
    expect(asked).toContain('p0: claude[tom] conversation')
    expect(asked).not.toContain('p1:')
    const cand = await call('/api/candidates', {text: 'look', harness: 'claude', profile: ''})
    asked = readFileSync(join(dir, 'asked'), 'utf8')
    expect(asked).toContain('a1:')
    expect(asked).not.toContain('a2:')
    expect(Js.textAt(cand, 'harness')).toBe('claude')
    const tomCand = await call('/api/candidates', {text: 'look', harness: 'claude', profile: 'tom'})
    expect(Js.textOf(Js.path(['decision', 'action', 'profile'], tomCand))).toBe('tom')
    expect(Js.textAt(tomCand, 'harness')).toBe('claude')
  } finally {
    rmSync(dir, {recursive: true, force: true})
  }
})
