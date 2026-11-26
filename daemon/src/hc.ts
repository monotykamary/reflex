// herdr-core (`hc`) socket client: JSON-RPC 2.0, one request per connection
// in plain mode. Requests are built and responses read by pure code; `call`
// is the only effect.
//
// The core runs terminals, not agents: a terminal is an agent here when its
// program reports itself through OSC 7501 (`status.app`), when Reflex
// started it (label reflex.kind) or when it runs a coding agent we know by
// name (Codex says nothing through 7501 yet). Its status is what the program
// reported — or, for a Claude whose 7501 never got going, the glyph its
// window title turns while it works (`glyphStatus`); one that said neither
// is unknown, never guessed from the screen.
//
// Terminals are addressed "t7" here and "box/t7" on a machine this core
// added; the local core answers for both, so every call goes to one socket.

import {readText, unixCall} from './host.ts'
import * as Js from './js.ts'
import type {J, Res} from './js.ts'
import type {Agent, Status} from './model.ts'
import {readStatus} from './model.ts'
import {drop, isEmpty, orElse, readU32, reverse, take, trim} from './str.ts'

export const request = (method: string, params: string): string =>
  Js.obj([Js.kv('jsonrpc', Js.str('2.0')), Js.kv('id', '1'), Js.kv('method', Js.str(method)), Js.kv('params', params)]) + '\n'

// "blocked: t3 is blocked on a question" — the stable kind first, so callers
// can tell a refusal worth retrying from a real failure.
export function answer(v: J): Res<J> {
  const res = Js.get(v, 'result')
  if (res !== undefined) return Js.done(res)
  const e = Js.get(v, 'error')
  return Js.fail(1, e === undefined ? 'herdr-core: no result' : Js.textOf(Js.path(['data', 'kind'], e)) + ': ' + Js.textAt(e, 'message'))
}

export async function call(sock: string, method: string, params: string, timeoutMs: number): Promise<Res<J>> {
  const r = await unixCall(sock, request(method, params), 8388608, timeoutMs)
  if (!r.ok) return r
  const v = Js.read(r.v)
  return v.ok ? answer(v.v) : v
}

// Reading terminals
// -----------------

// "/opt/homebrew/bin/codex" -> "codex".
export function base(path: string): string {
  const parts = path.split('/')
  return parts[parts.length - 1]!
}

// The program a terminal runs, by name: argv[0] of `v` ("argv", or the
// foreground job's).
export const argv0 = (v: J | undefined): string => {
  const xs = Js.asList(v)
  return base(xs.length === 0 ? '' : Js.textOf(xs[0]))
}

const KNOWN = ['claude', 'pi', 'codex', 'grok', 'opencode', 'agy', 'amp', 'droid', 'cursor-agent', 'copilot', 'qwen', 'aider', 'goose', 'crush', 'kimi']

// A coding agent Reflex knows by its command.
export const known = (name: string): boolean => KNOWN.includes(name)

const ifKnown = (name: string) => (known(name) ? name : '')

// The word an agent's 7501 report names itself by, as Reflex's kinds have it.
// (Antigravity's CLI, agy, reports itself as "antigravity".)
const appKind = (app: string) => (app === 'claude-code' ? 'claude' : app === 'codex-cli' ? 'codex' : app === 'antigravity' ? 'agy' : app)

export const label = (t: J, key: string): string => Js.textOf(Js.path(['labels', key], t))

const SHELLS = ['zsh', 'bash', 'sh', 'fish', 'dash', 'ksh', 'tcsh', 'nu', 'login']

// A login shell's argv[0] is "-zsh".
const unlogin = (name: string) => (name.startsWith('-') ? drop(name, 1) : name)

// The foreground job is a shell: the agent it ran has quit (Reflex starts
// agents in a login shell that stays), or none has started yet.
const atShell = (t: J) => SHELLS.includes(unlogin(argv0(Js.path(['foreground', 'argv'], t))))

const statusApp = (t: J) => Js.textOf(Js.path(['status', 'app'], t))

// What it is: the kind Reflex started it as, else what its program says it
// is, else a known agent in the foreground, else a known agent it started as.
export const kindOfAny = (t: J): string =>
  orElse(label(t, 'reflex.kind'), orElse(appKind(statusApp(t)), orElse(ifKnown(argv0(Js.path(['foreground', 'argv'], t))), ifKnown(argv0(Js.get(t, 'argv'))))))

// ...and none while a shell is in front with nothing reported: an agent that
// quit leaves the list (the core clears its status when the shell gets the
// terminal back, and it is a plain shell again).
export const kindOf = (t: J): string => (atShell(t) && isEmpty(statusApp(t)) ? '' : kindOfAny(t))

// 7501's words as Reflex's: "error" (the turn ended badly) is a finished turn
// to look at; anything unreported is unknown.
const statusWord = (s: string) => (s === 'error' ? 'done' : s)

// Claude Code (2.1.321) asks the terminal whether it listens to 7501 and,
// unanswered (as it is after `claude --resume`, though not on a fresh start),
// says nothing through it; its window title carries its state instead: "◐ "/"◑ "
// (turning) while it works, "✳ " at rest, and no glyph at all once 7501 is in
// use. So the glyph is Claude's status when nothing was reported, and leaves
// the title.
export function glyphStatus(title: string): string {
  if (title.startsWith('◐ ') || title.startsWith('◑ ') || title.startsWith('◓ ') || title.startsWith('◒ ')) return 'working'
  return title.startsWith('✳ ') ? 'idle' : ''
}

const untitle = (title: string) => (isEmpty(glyphStatus(title)) ? title : drop(title, 2))

const titleStatus = (t: J) => (kindOfAny(t) === 'claude' ? glyphStatus(Js.textAt(t, 'title')) : '')

const statusOf = (t: J): Status => readStatus(orElse(statusWord(Js.textOf(Js.path(['status', 'state'], t))), titleStatus(t)))

// Reflex's seq only has to change when the status does: the low digits of
// the time it last changed (ms since the epoch) do, and fit a U32.
const digits9 = (lex: string) => reverse(take(reverse(lex), 9))

const seqOf = (t: J) => readU32(digits9(Js.textOf(Js.get(t, 'status_ms')))) ?? 0

export const cwdOf = (t: J): string => orElse(Js.textOf(Js.path(['foreground', 'cwd'], t)), Js.textAt(t, 'cwd'))

export function agentOf(t: J): Agent {
  return {
    pane: Js.textAt(t, 'address'),
    name: orElse(Js.textAt(t, 'name'), Js.textAt(t, 'address')),
    kind: kindOf(t),
    status: statusOf(t),
    cwd: cwdOf(t),
    title: untitle(Js.textAt(t, 'title')),
    seq: seqOf(t),
    session: label(t, 'reflex.session'),
    screen: '',
    parent: Js.textAt(t, 'parent'),
    profile: label(t, 'reflex.profile'),
  }
}

// What the core listed: its agents, and the machines whose line is down right
// now (their terminals are left out, not gone: keep them a while).
export type Listed = {agents: Agent[]; down: string[]}

const downOf = (xs: J[]) => xs.filter((x) => Js.textAt(x, 'state') !== 'connected').map((x) => Js.textAt(x, 'name'))

// Sessions
// --------
// Reflex starts Claude and pi with a session id it chose (`--session-id`) and
// labels the terminal with it. A Claude started some other way names its
// session in ~/.claude/sessions/<pid>.json once it has one.

const fgPid = (t: J) => Js.textOf(Js.path(['foreground', 'pid'], t))

// A harness's own folder: yours, or a profile's (`reflex profile`: Claude's
// CLAUDE_CONFIG_DIR, pi's agent folder).
export function harnessDir(home: string, kind: 'claude' | 'pi', profile: string): string {
  if (profile) return home + '/.reflex/profiles/' + kind + '/' + profile + '/' + kind
  return kind === 'claude' ? home + '/.claude' : home + '/.pi/agent'
}

export const sessionFile = (home: string, pid: string, profile = ''): string => harnessDir(home, 'claude', profile) + '/sessions/' + pid + '.json'

function sessionIn(r: Res<string>): string {
  if (!r.ok) return ''
  const v = Js.read(r.v)
  return v.ok ? Js.textAt(v.v, 'sessionId') : ''
}

const here = (pane: string) => !pane.includes('/')

// A Claude on this Mac with no session from Reflex: its own file's.
const fillSessionWant = (a: Agent) => isEmpty(a.session) && a.kind === 'claude' && here(a.pane)

// Stopped agents
// --------------
// An agent the core lost, not one you ended: a finished terminal whose
// program a restart, a lost holder, a shutdown or a signal took (an exit or a
// kill is the end), or a kept terminal the core gave a new shell after such a
// loss. That shell looks like an agent you quit, so Reflex marks a kept
// terminal with its shell's pid (label reflex.shell) while an agent runs in
// it: the same shell back in front is an agent you quit (the mark goes);
// another one is a shell the core put there.

const keeps = (t: J) => Js.asBool(Js.get(t, 'keep'))
const shellPid = (t: J) => Js.textAt(t, 'pid')

// What reflex.shell should say now: the shell an agent runs in; nothing once
// the agent quit and its own shell is back in front; else as it was.
const shellMarkNow = (t: J) => (isEmpty(kindOf(t)) ? (label(t, 'reflex.shell') === shellPid(t) ? '' : label(t, 'reflex.shell')) : shellPid(t))

// ...only once the core says what is in front: right after a restart a kept
// terminal has no program for a moment, then its new shell before it's in
// front, and its labels alone would read as the agent still there.
export const shellMark = (t: J): string => (isEmpty(fgPid(t)) || isEmpty(shellPid(t)) ? label(t, 'reflex.shell') : shellMarkNow(t))

const pLabel = (t: string, k: string, v: string) => Js.obj([Js.kv('terminal', Js.str(t)), Js.kv('labels', Js.obj([Js.kv(k, Js.str(v))]))])

async function markShell(sock: string, t: J): Promise<void> {
  const v = shellMark(t)
  if (keeps(t) && v !== label(t, 'reflex.shell')) await call(sock, 'terminal.label', pLabel(Js.textAt(t, 'address'), 'reflex.shell', v), 3000)
}

async function fillSessions(xs: J[], sock: string, home: string): Promise<Agent[]> {
  const out: Agent[] = []
  for (const t of xs) {
    await markShell(sock, t)
    let a = agentOf(t)
    if (fillSessionWant(a)) a = {...a, session: sessionIn(await readText(sessionFile(home, fgPid(t), a.profile), 65536))}
    if (!isEmpty(kindOf(t))) out.push(a)
  }
  return out
}

// Every agent the core runs, this Mac's and its connected machines' alike.
// (8 s: the list waits on each machine, and one busy sandbox can take a few
// seconds; failing it would count the whole core as unreachable.)
export async function listAgents(sock: string, home: string): Promise<Res<Listed>> {
  const r = await call(sock, 'terminal.list', '{}', 8000)
  if (!r.ok) return r
  const agents = await fillSessions(Js.asList(Js.get(r.v, 'terminals')), sock, home)
  return Js.done({agents, down: downOf(Js.asList(Js.get(r.v, 'machines')))})
}

const LOST = ['stopped_by_restart', 'server_stop', 'holder_lost', 'host_shutdown', 'signaled']

// A kept terminal whose agent the core replaced with a shell.
const replaced = (t: J) => isEmpty(kindOf(t)) && !isEmpty(label(t, 'reflex.shell')) && label(t, 'reflex.shell') !== shellPid(t)

const finished = (t: J) => Js.textAt(t, 'state') === 'finished'

// Why the core lost it ("restart" for a replaced one), or "" if it didn't.
export const lostWhy = (t: J): string => (finished(t) ? (LOST.includes(Js.textAt(t, 'reason')) ? Js.textAt(t, 'reason') : '') : replaced(t) ? 'restart' : '')

// A pi session is its file (…/<time>_<id>.jsonl) or its id.
export const sameSession = (a: string, b: string): boolean => a === b || a.endsWith('_' + b + '.jsonl') || b.endsWith('_' + a + '.jsonl')

// Another live terminal carries it on: the same name, or the same session.
const carried = (xs: J[], addr: string, name: string, session: string) =>
  xs.some(
    (x) =>
      !finished(x) &&
      Js.textAt(x, 'address') !== addr &&
      ((!isEmpty(name) && Js.textAt(x, 'name') === name) || (!isEmpty(session) && sameSession(label(x, 'reflex.session'), session))),
  )

const stoppedWant = (all: J[], t: J) =>
  !isEmpty(lostWhy(t)) && !isEmpty(kindOfAny(t)) && !carried(all, Js.textAt(t, 'address'), Js.textAt(t, 'name'), label(t, 'reflex.session'))

const stoppedJson = (t: J) =>
  Js.obj([
    Js.kv('pane', Js.str(Js.textAt(t, 'address'))),
    Js.kv('name', Js.str(orElse(Js.textAt(t, 'name'), Js.textAt(t, 'address')))),
    Js.kv('kind', Js.str(kindOfAny(t))),
    Js.kv('cwd', Js.str(cwdOf(t))),
    Js.kv('title', Js.str(Js.textAt(t, 'title'))),
    Js.kv('session', Js.str(label(t, 'reflex.session'))),
    Js.kv('why', Js.str(lostWhy(t))),
    Js.kv('at', Js.str(Js.textAt(t, 'finished_ms'))),
    ...(isEmpty(label(t, 'reflex.profile')) ? [] : [Js.kv('profile', Js.str(label(t, 'reflex.profile')))]),
  ])

export function stoppedOf(r: Res<J>): string {
  if (!r.ok) return '{"ok":false,"stopped":[]}'
  const all = Js.asList(Js.get(r.v, 'terminals'))
  return '{"ok":true,"stopped":' + Js.arr(all.filter((t) => stoppedWant(all, t)).map(stoppedJson)) + '}'
}

// The agents the core lost, this Mac's and its connected machines', as JSON.
export async function listStopped(sock: string): Promise<string> {
  return stoppedOf(await call(sock, 'terminal.list', '{"all":true}', 3000))
}

// Requests
// --------

const pTerminal = (t: string) => Js.obj([Js.kv('terminal', Js.str(t))])

// The screen, plus `lines` of history above it. herdr's sources map onto
// that: "visible" is the screen alone, the rest a screen and some history.
export async function readPane(sock: string, pane: string, source: string, lines: number): Promise<Res<string>> {
  const r = await call(sock, 'terminal.read', Js.obj([Js.kv('terminal', Js.str(pane)), Js.kv('lines', Js.num(source === 'visible' ? 0 : lines))]), 3000)
  return r.ok ? Js.done(Js.textAt(r.v, 'text')) : r
}

// What the program last reported ("idle", "working", "blocked", "done"); ""
// when it never did, or it is gone.
export async function paneStatus(sock: string, pane: string): Promise<string> {
  const r = await call(sock, 'terminal.get', pTerminal(pane), 3000)
  return r.ok ? statusWord(Js.textOf(Js.path(['status', 'state'], r.v))) : ''
}

const reports = (kind: string) => kind === 'claude' || kind === 'pi'

// A prompt: pasted, then Enter, once nobody has typed for a moment. The core
// refuses one while the agent waits on you (kind "blocked"); an agent that
// reports its status but hasn't yet (still starting) is refused here, as
// herdr's agent_not_ready was, so the caller retries.
export async function prompt(sock: string, pane: string, text: string): Promise<Res<J>> {
  const g = await call(sock, 'terminal.get', pTerminal(pane), 3000)
  if (!g.ok) return g
  if (reports(kindOfAny(g.v)) && isEmpty(Js.textOf(Js.path(['status', 'state'], g.v)))) return Js.fail(1, 'agent_not_ready: it has not said it is ready yet')
  return call(sock, 'terminal.send', Js.obj([Js.kv('terminal', Js.str(pane)), Js.kv('text', Js.str(text))]), 20000)
}

// herdr's key names as the core's: "ctrl-c" is "ctrl+c", "escape" "esc".
const keyName = (k: string) => (k === 'escape' ? 'esc' : k === 'return' ? 'enter' : k.split('-').join('+'))

// One key, or several separated by spaces ("down down enter").
export const pKeys = (pane: string, key: string): string =>
  Js.obj([
    Js.kv('terminal', Js.str(pane)),
    Js.kv(
      'keys',
      Js.strs(
        key
          .split(' ')
          .filter((w) => w.length > 0)
          .map(keyName),
      ),
    ),
  ])

export const press = (sock: string, pane: string, key: string): Promise<Res<J>> => call(sock, 'terminal.keys', pKeys(pane, key), 10000)

// End the program (hangup, terminate, kill) and drop its record.
export async function closePane(sock: string, pane: string): Promise<Res<J>> {
  const r = await call(sock, 'terminal.kill', pTerminal(pane), 15000)
  if (!r.ok) return r
  await call(sock, 'terminal.rm', pTerminal(pane), 5000)
  return r
}

// Starting agents
// ---------------

const hex8 = (n: number) => (n >>> 0).toString(16).padStart(8, '0')

// A version-4 UUID from four random words (Claude wants a real UUID).
export function uuid(a: number, b: number, c: number, d: number): string {
  const s = hex8(a) + hex8(b) + hex8(c) + hex8(d)
  return s.slice(0, 8) + '-' + s.slice(8, 12) + '-4' + s.slice(13, 16) + '-8' + s.slice(17, 20) + '-' + s.slice(20, 32)
}

// Codex runs its commands in a shared daemon unless told not to: outside
// this terminal, unseen.
const cmdOf = (kind: string) => (kind === 'codex' ? ['codex', '--no-daemon'] : [kind])

// A first prompt on the command line. agy (1.5) takes one only after -i
// (--prompt-interactive) and refuses a bare one, leaving a shell behind.
const promptOf = (kind: string, text: string): string[] => (isEmpty(trim(text)) ? [] : kind === 'agy' ? ['-i', text] : [text])

// The agent's command line: its command, how to bring its session back (or
// the id to start one with), then the request as its first prompt.
export const argv = (kind: string, args: string[], text: string): string[] => [...cmdOf(kind), ...args, ...promptOf(kind, text)]

// Through the profile runner where the machine has one (`reflex profile run
// SPEC ARGS...`: the profile named, or for a bare kind that machine's default
// profile), else the harness itself. SPEC is "claude" or "claude[tom]"; the
// agent's kind stays its label (reflex.kind). A reflex from before profiles
// (`reflex profile ls` unknown to it) counts as none.
export const PROFILE_RUNNER =
  'if command -v reflex >/dev/null 2>&1 && reflex profile ls >/dev/null 2>&1; then exec reflex profile run "$0" "$@"; else exec "${0%%[*}" "$@"; fi'

// `pinned`: a session brought back (resumed, attached, forked) stays in the
// profile it was saved in, so one saved in your own login comes back as
// `claude[]`, never in whatever that machine's default is now.
export function profiled(kind: string, profile: string, xs: string[], pinned = false): string[] {
  const spec = isEmpty(profile) ? (pinned ? kind + '[]' : kind) : kind + '[' + profile + ']'
  return ['sh', '-c', PROFILE_RUNNER, spec, ...xs.slice(1)]
}

const labels = (kind: string, session: string, profile: string) =>
  Js.obj([
    Js.kv('reflex.kind', Js.str(kind)),
    ...(isEmpty(session) ? [] : [Js.kv('reflex.session', Js.str(session))]),
    ...(isEmpty(profile) ? [] : [Js.kv('reflex.profile', Js.str(profile))]),
  ])

// A shell that runs `"$@"` (fish and nu don't): yours, else zsh.
const posix = (shell: string) => (base(shell) === 'fish' || base(shell) === 'nu' ? '/bin/zsh' : shell)

// Never a child of whatever terminal reflexd was started from (children end
// with their parent), and kept: a program lost to a crash or reboot comes back
// as a shell in its folder.
//
// Run in your login shell (`shell`), which stays when the agent quits, as the
// Herdr app does: the agent finds what your shell sets up (PATH, keys), and
// the terminal is still yours afterwards. Elsewhere `sh` starts it the same
// way and hands over to that machine's shell.
export function wrap(shell: string, m: string, xs: string[]): string[] {
  if (isEmpty(m)) return [posix(shell), '-lic', '"$@"; exec "$0" -li', posix(shell), ...xs]
  // That machine's own login shell, found there.
  return ['sh', '-c', 's="${SHELL:-/bin/sh}"; case "${s##*/}" in fish|nu) s=/bin/sh;; esac; exec "$s" -lic \'"$@"; exec "$0" -li\' "$s" "$@"', 'sh', ...xs]
}

// PI_CLIPBOARD_OSC52: pi sends what it copies through the terminal too (OSC
// 52), not only to the clipboard of the machine it runs on: herdr-core passes
// it to Reflex's window, so a copy from another Mac's pi lands on this one.
// (Claude Code does that already; pi only does it over ssh.)
export function pRun(shell: string, name: string, m: string, cwd: string, kind: string, session: string, xs: string[], profile = ''): string {
  return Js.obj([
    Js.kv('name', Js.str(name)),
    Js.kv('cwd', Js.str(cwd)),
    Js.kv('argv', Js.arr(wrap(shell, m, xs).map(Js.str))),
    Js.kv('labels', labels(kind, session, profile)),
    Js.kv('no_parent', 'true'),
    Js.kv('keep', 'true'),
    Js.kv('env', Js.obj([Js.kv('TERM', Js.str('xterm-256color')), Js.kv('COLORTERM', Js.str('truecolor')), Js.kv('PI_CLIPBOARD_OSC52', Js.str('1'))])),
    ...(isEmpty(m) ? [] : [Js.kv('on', Js.str(m))]),
  ])
}

// Start an agent in a new terminal, on this Mac or machine m, in cwd (there):
// its address ("t7", "box/t7").
export async function run(
  sock: string,
  shell: string,
  name: string,
  m: string,
  cwd: string,
  kind: string,
  session: string,
  args: string[],
  text: string,
  profile = '',
  pinned = false,
): Promise<Res<string>> {
  const r = await call(sock, 'terminal.run', pRun(shell, name, m, cwd, kind, session, profiled(kind, profile, argv(kind, args, text), pinned), profile), 30000)
  return r.ok ? Js.done(Js.textAt(r.v, 'address')) : r
}

// Machines
// --------

// The machines this core has added, by name (only those it reaches now, when
// `connected`).
export async function machines(sock: string, connected: boolean): Promise<string[]> {
  const r = await call(sock, 'machine.list', '{}', 3000)
  if (!r.ok) return []
  return Js.asList(Js.get(r.v, 'machines'))
    .filter((x) => !connected || Js.textAt(x, 'state') === 'connected')
    .map((x) => Js.textAt(x, 'name'))
}

// Whether the core answers at all.
export async function up(sock: string): Promise<boolean> {
  return (await call(sock, 'server.status', '{}', 2000)).ok
}
