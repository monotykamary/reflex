// reflexd: the IO shell around core.step.
//
//   actor   one owner of the State; every change is core.step
//   ticker  posts tick so the undo window can expire
//   poller  posts the agents (with a screen for agents that changed)
//   indexer runs reflex-scan.sh and posts the folder index
//   http    one task per connection: the JSON API and the web remote
//   exec    one task per dispatch that leaves its undo window

import {createServer, type Socket} from 'node:net'
import * as Core from './core.ts'
import * as Ix from './folders.ts'
import * as Hc from './hc.ts'
import * as Herdr from './herdr.ts'
import * as Host from './host.ts'
import * as Http from './http.ts'
import * as Js from './js.ts'
import type {J, Res} from './js.ts'
import * as Link from './link.ts'
import type {Action, Agent, Dispatch, Folder, Msg, Opt, Reply, State} from './model.ts'
import {emptyState, showStatus, spec} from './model.ts'
import * as P from './past.ts'
import * as R from './route.ts'
import {isEmpty, lines, orElse, readU32, showU32, trim} from './str.ts'
import * as Term from './term.ts'

// Config
// ------

export type Cfg = {
  sock: string
  core: string
  shell: string
  backend: string
  link: string
  bind: string
  port: number
  token: string
  jev: string
  harness: string
  threshold: number
  home: string
  data: string
  web: string
  scan: string
  fork: string
  undo: number
  shown: boolean
}

const u32Env = (name: string, dflt: number) => readU32(Host.env(name, '')) ?? dflt

export function load(): Cfg {
  const env = Host.env
  const home = env('HOME', '/tmp')
  const session = env('HERDR_SESSION', '')
  const sock = env('REFLEX_HERDR_SOCKET', isEmpty(session) ? home + '/.config/herdr/herdr.sock' : home + '/.config/herdr/sessions/' + session + '/herdr.sock')
  const hcSession = env('HC_SESSION', 'default')
  // herdr-core's socket on macOS when nothing moves it (HC_SOCKET, its config
  // or XDG_RUNTIME_DIR do: the app works that out and passes REFLEX_CORE_SOCKET).
  const core = env('REFLEX_CORE_SOCKET', home + '/.local/state/herdr-core/' + hcSession + '/' + hcSession + '.sock')
  const given = env('REFLEX_TOKEN', '')
  const data = env('REFLEX_DATA', home + '/Library/Application Support/Reflex')
  return {
    sock,
    core,
    shell: env('SHELL', '/bin/zsh'),
    backend: env('REFLEX_BACKEND', 'core'),
    bind: env('REFLEX_BIND', '127.0.0.1'),
    port: u32Env('REFLEX_PORT', 47823),
    token: isEmpty(given) ? 'rx' + showU32(Host.randomU32()) + showU32(Host.randomU32()) : given,
    jev: env('REFLEX_JEV', 'jev-fabric'),
    harness: env('REFLEX_HARNESS', 'claude'),
    threshold: u32Env('REFLEX_THRESHOLD', 6000),
    home,
    data,
    web: env('REFLEX_WEB', 'web'),
    scan: env('REFLEX_SCAN', 'reflex-scan.sh'),
    fork: env('REFLEX_FORK', 'reflex-fork.sh'),
    undo: u32Env('REFLEX_UNDO_MS', 0),
    link: env('REFLEX_LINK_SOCKET', data + '/link.sock'),
    shown: isEmpty(given),
  }
}

// Where the app forwards other machines' herdr sockets, and `list` there
// names the machines it keeps a tunnel to.
const machinesDir = (c: Cfg) => c.data + '/machines'

// The socket a pane lives behind: herdr-core's, or a herdr's (see term.ts).
const at = (c: Cfg, pane: string) => Term.at(c.sock, c.core, machinesDir(c), pane)

// A token the daemon made up is printed once so it can be used; one given in
// REFLEX_TOKEN never reaches the log.
export const readyLine = (c: Cfg): string =>
  Js.obj([
    Js.kv(
      'ready',
      Js.obj([
        Js.kv('url', Js.str('http://' + c.bind + ':' + showU32(c.port))),
        Js.kv('port', Js.num(c.port)),
        Js.kv('token', Js.str(c.shown ? c.token : '(from REFLEX_TOKEN)')),
        Js.kv('herdr', Js.str(c.sock)),
        Js.kv('core', Js.str(c.core)),
        Js.kv('backend', Js.str(c.backend)),
        Js.kv('harness', Js.str(c.harness)),
        Js.kv('data', Js.str(c.data)),
      ]),
    ),
  ])

const print = (s: string) => process.stdout.write(s + '\n')

// The actor
// ---------
// One owner of the State. Every change goes through core.step, one message
// at a time, in the order they were sent; the dispatches a step releases run
// after it, each on its own.

class Actor {
  private state: State
  private queue: Msg[] = []
  private busy = false
  constructor(
    undo: number,
    private readonly run: (d: Dispatch) => void,
  ) {
    this.state = emptyState(undo)
  }
  // Send a message and take the actor's reply.
  ask(msg: Msg): Reply {
    // A message sent while a step runs (never, as dispatches start after it)
    // would wait its turn; asks never come from inside a step.
    const out = Core.step(this.state, msg)
    this.state = out.state
    for (const d of out.run) queueMicrotask(() => this.run(d))
    return out.reply
  }
  post(msg: Msg): void {
    this.queue.push(msg)
    if (this.busy) return
    this.busy = true
    try {
      while (this.queue.length > 0) this.ask(this.queue.shift()!)
    } finally {
      this.busy = false
    }
  }
}

const textOf = (r: Reply) => (r.r === 'text' ? r.json : '{}')

// Running dispatches
// ------------------

const okDetail = <T>(r: Res<T>, detail: string): Res<string> => (r.ok ? Js.done(detail) : r)

function stdoutOf(r: Res<Host.Ran>): Res<string> {
  if (!r.ok) return r
  return r.v.status === 0 ? Js.done(r.v.out) : Js.fail(r.v.status, orElse(trim(r.v.err), trim(r.v.out)))
}

const textOr = (r: Res<string>, prev: string) => (r.ok ? r.v : prev)

export class Daemon {
  readonly actor: Actor
  constructor(readonly cfg: Cfg) {
    this.actor = new Actor(cfg.undo, (d) => void this.exec(d))
  }

  post(msg: Msg) {
    this.actor.post(msg)
  }
  askText(msg: Msg): string {
    return textOf(this.actor.ask(msg))
  }

  // Waiting for a TUI to finish answering: read the pane until two reads agree.
  async settle(sock: string, pane: string): Promise<string> {
    let text = ''
    let calm = 0
    for (let fuel = 30; fuel > 0; fuel--) {
      if (calm >= 2) break
      await Host.sleep(1500)
      const cur = textOr(await Term.readPane(sock, pane, 'visible', 80), text)
      calm = cur === text ? calm + 1 : 0
      text = cur
    }
    return text
  }

  // After a native /btw, collect what the agent showed and post it as a reply.
  async captureBtw(pane: string, label: string) {
    await Host.sleep(2500)
    const text = await this.settle(at(this.cfg, pane), Term.bare(pane))
    this.post({m: 'post', kind: 'reply', pane, agent: label, title: 'btw answer', body: Core.tailLines(text, 30), opts: []})
  }

  // A freshly started agent refuses prompts (agent_not_ready) until it is
  // ready: a moment while it registers — or as long as it waits on you, like
  // Claude's "Do you trust this folder?" in a new folder. Retry that, and only
  // that, for up to ten minutes, so the request goes in once you answer.
  async promptRetry(sock: string, pane: string, text: string): Promise<{ok: boolean; detail: string}> {
    let settled = false
    let ok = false
    let detail = ''
    const now = async () => {
      const r = await Term.prompt(sock, pane, text)
      if (r.ok) {
        settled = true
        ok = true
        detail = 'sent'
      } else {
        settled = !retryable(r.msg)
        ok = false
        detail = r.msg
      }
    }
    for (let fuel = 860; fuel > 0 && !settled; fuel--) {
      await Host.sleep(700)
      // Refused before (it was not ready, or waiting on you): send only once
      // it has been idle for a moment. Right after a dialog closes it may take
      // a prompt the agent's input never sees.
      if (isEmpty(detail)) await now()
      else if (readyStatus(await Term.paneStatus(sock, pane))) {
        await Host.sleep(1500)
        if (readyStatus(await Term.paneStatus(sock, pane))) await now()
      }
    }
    return {ok, detail}
  }

  // A prompt taken as typing, or never taken
  // ----------------------------------------
  // A TUI that is busy (just started, or on a Mac under load) can read a
  // pasted prompt and its Enter as one paste, and in a paste Enter is a new
  // line: the words sit in its input and nothing runs. Or the paste lands
  // before its input is listening and is lost: an idle, empty agent. So after
  // each prompt, in the background, while the agent stays idle (at most six
  // looks, 2.5 s apart): the request in its input box gets an Enter; the
  // request nowhere on screen, twice running (a slow paste is not a lost
  // one), is sent once more.
  async confirm(sock: string, pane: string, text: string) {
    const probe = Core.probe(text)
    let missing = false
    let resent = false
    for (let fuel = 6; fuel > 0; fuel--) {
      await Host.sleep(2500)
      const s = await Term.paneStatus(sock, pane)
      const r = await Term.readPane(sock, pane, 'visible', 60)
      const screen = r.ok ? r.v : ''
      if (Core.promptTyped(s, screen, probe)) {
        await Term.press(sock, pane, 'enter')
        print('prompt in ' + pane + ' was typed but not sent: pressed Enter')
        missing = false
      } else if (Core.promptMissing(s, screen, probe)) {
        if (missing && !resent) {
          await Term.prompt(sock, pane, text)
          print('prompt in ' + pane + ' never arrived: sent it again')
          missing = false
          resent = true
        } else missing = true
      } else return
    }
  }

  confirmStart(go: boolean, sock: string, pane: string, text: string) {
    if (go) void this.confirm(sock, pane, text)
  }

  async recordUse(ok: boolean, cwd: string) {
    if (ok) await Host.put(this.cfg.data + '/usage.tsv', 'a', cwd + '\n')
  }

  // A session starts in the herdr of the Mac its folder is on: `sock` is that
  // herdr's socket, `m` the machine ("" for this Mac) and `pane` herdr's own id
  // there; the receipt names the pane as reflexd knows it ("work/w3:p1").
  async spawned(sock: string, m: string, cwd: string, name: string, pane: string, text: string, r: Res<J>): Promise<Res<string>> {
    if (!r.ok) return r
    const st = isEmpty(trim(text)) ? {ok: true, detail: ''} : await this.promptRetry(sock, pane, text)
    await this.recordUse(st.ok, cwd)
    this.confirmStart(st.ok && !isEmpty(trim(text)), sock, pane, text)
    const shown = Term.paneOn(m, pane)
    return st.ok
      ? Js.done('started ' + name + ' in ' + shown)
      : Js.fail(1, 'started ' + name + ' but could not give it your request (' + st.detail + ') — is it still waiting on you?')
  }

  // Started: prompt it when there is a request, else it is simply back.
  async resumed(empty: boolean, sock: string, m: string, cwd: string, name: string, pane: string, text: string, r: Res<J>): Promise<Res<string>> {
    if (empty) return r.ok ? Js.done('resumed ' + name + ' in ' + Term.paneOn(m, pane)) : r
    return this.spawned(sock, m, cwd, name, pane, text, r)
  }

  // A headless fork runs where the session's files are: on this Mac. One on
  // another machine isn't forked (yet): its own terminal can take the question.
  async sideFork(pane: string, label: string, kind: string, cwd: string, session: string, text: string, profile: string): Promise<Res<string>> {
    if (!isEmpty(Herdr.machine(pane)))
      return Js.fail(1, 'a side question for an agent on ' + Herdr.machine(pane) + ' needs it free to take /btw: ask in its terminal')
    // An agent in a profile is forked in it: its sessions are the profile's
    // (where this Mac's reflex knows profiles).
    const found = isEmpty(profile) ? null : Bun.which('reflex')
    const knows = found ? await Host.run(found, ['profile', 'ls'], '', 1048576, 5000) : null
    const reflex = knows?.ok && knows.v.status === 0 ? found : null
    const [cmd, args] = reflex
      ? [reflex, ['profile', 'exec', spec(kind, profile), this.cfg.fork, kind, cwd, session, text]]
      : [this.cfg.fork, [kind, cwd, session, text]]
    const r = stdoutOf(await Host.run(cmd, args, '', 4194304, 300000))
    if (!r.ok) return r
    this.post({m: 'post', kind: 'reply', pane, agent: label, title: 'btw answer (forked session)', body: trim(r.v), opts: []})
    return Js.done('answered in a fork')
  }

  readMachines = async (): Promise<string[]> =>
    lines(textOr(await Host.readText(machinesDir(this.cfg) + '/list', 65536), ''))
      .map(trim)
      .filter((x) => !isEmpty(x))

  // Where a new session starts: herdr-core, unless you chose herdr
  // (REFLEX_BACKEND=herdr) or the core can't take it: it isn't running here,
  // or the folder is on a machine the core doesn't reach now while herdr's
  // tunnel does (or hasn't added at all).
  async useCore(m: string): Promise<boolean> {
    if (this.cfg.backend === 'herdr' || isEmpty(this.cfg.core)) return false
    if (isEmpty(m)) return Hc.up(this.cfg.core)
    const up = await Hc.machines(this.cfg.core, true)
    const known = await Hc.machines(this.cfg.core, false)
    const hs = await this.readMachines()
    return up.includes(m) || (known.includes(m) && !hs.includes(m))
  }

  // Started in the core with the request as its first prompt (the agent's own
  // argument: nothing to type in, nothing to wait for).
  async coreRun(id: number, m: string, cwd: string, kind: string, session: string, args: string[], text: string, profile: string): Promise<Res<string>> {
    const name = agentName(id, Host.randomU32())
    const a = await Hc.run(this.cfg.core, this.cfg.shell, name, m, Ix.pathOn(cwd), kind, session, args, text, profile)
    if (!a.ok) return a
    // A request that went in counts as using its folder.
    await this.recordUse(!isEmpty(trim(text)), cwd)
    return Js.done('started ' + name + ' in ' + a.v)
  }

  // (A profile is the core's: herdr starts its own agents by kind.)
  async spawnOn(c: boolean, id: number, m: string, cwd: string, kind: string, text: string, profile: string): Promise<Res<string>> {
    if (c) {
      const s = freshSession(kind)
      return this.coreRun(id, m, cwd, kind, s, isEmpty(s) ? [] : ['--session-id', s], text, profile)
    }
    const sock = Herdr.atOf(this.cfg.sock, machinesDir(this.cfg), m)
    const w = await Herdr.newWorkspace(sock, Ix.pathOn(cwd), Core.baseName(cwd))
    if (!w.ok) return w
    const name = agentName(id, Host.randomU32())
    const st = await Herdr.startAgent(sock, name, kind, w.v)
    return this.spawned(sock, m, cwd, name, w.v, text, st)
  }

  // Attaching to a running background session takes no first prompt: the
  // request is sent once it is up, as to any live session.
  async resumeOn(c: boolean, id: number, m: string, cwd: string, kind: string, session: string, mode: string, text: string, profile: string): Promise<Res<string>> {
    const args = R.resumeArgs(kind, mode, session)
    if (c) {
      // A resumed (or attached) session keeps its id; a fork's is new and
      // comes to light later (Claude's own session file).
      if (mode !== 'attach') return this.coreRun(id, m, cwd, kind, mode === 'fork' ? '' : session, args, text, profile)
      const name = agentName(id, Host.randomU32())
      const a = await Hc.run(this.cfg.core, this.cfg.shell, name, m, Ix.pathOn(cwd), kind, session, args, '', profile)
      if (!a.ok) return a
      return this.resumed(isEmpty(text), this.cfg.core, m, cwd, name, a.v, text, Js.done(Js.NULL))
    }
    const sock = Herdr.atOf(this.cfg.sock, machinesDir(this.cfg), m)
    const w = await Herdr.newWorkspace(sock, Ix.pathOn(cwd), Core.baseName(cwd))
    if (!w.ok) return w
    const name = agentName(id, Host.randomU32())
    const st = await Herdr.startAgentArgs(sock, name, kind, w.v, args)
    return this.resumed(isEmpty(text), sock, m, cwd, name, w.v, text, st)
  }

  async perform(id: number, label: string, a: Action): Promise<Res<string>> {
    const c = this.cfg
    switch (a.type) {
      case 'prompt': {
        // A prompt to a live session: delivered, then watched until it runs.
        const r = await Term.prompt(at(c, a.pane), Term.bare(a.pane), a.text)
        if (r.ok) this.confirmStart(true, at(c, a.pane), Term.bare(a.pane), a.text)
        return okDetail(r, 'sent')
      }
      case 'press':
        return okDetail(await Term.press(at(c, a.pane), Term.bare(a.pane), a.key), 'pressed ' + a.key)
      case 'btw': {
        const r = await Term.prompt(at(c, a.pane), Term.bare(a.pane), '/btw ' + a.text)
        void this.captureBtw(a.pane, label)
        return okDetail(r, 'asked with /btw')
      }
      case 'fork':
        return this.sideFork(a.pane, label, a.kind, a.cwd, a.session, a.text, a.profile ?? '')
      // A folder on another Mac ("work:/Users/you/VCS/app") starts there.
      case 'resume': {
        const m = Ix.machineOf(a.cwd)
        return this.resumeOn(await this.useCore(m), id, m, a.cwd, a.kind, a.session, a.mode, a.text, a.profile ?? '')
      }
      case 'spawn': {
        const m = Ix.machineOf(a.cwd)
        // A new project folder may not exist yet; on another Mac the folder
        // comes from its own index: it is there.
        if (isEmpty(m)) await Host.run('/bin/mkdir', ['-p', a.cwd], '', 4096, 5000)
        return this.spawnOn(await this.useCore(m), id, m, a.cwd, a.kind, a.text, a.profile ?? '')
      }
    }
  }

  async exec(d: Dispatch) {
    let r: Res<string>
    try {
      r = await this.perform(d.id, d.label, d.action)
    } catch (err) {
      r = Js.fail(1, String((err as Error)?.message ?? err))
    }
    this.post(r.ok ? {m: 'receipted', id: d.id, label: d.label, ok: true, detail: r.v} : {m: 'receipted', id: d.id, label: d.label, ok: false, detail: r.msg})
  }

  // Ticker, poller, indexer
  // -----------------------

  async ticker(start: number) {
    for (;;) {
      await Host.sleep(150)
      this.post({m: 'tick', now: (Host.nowMs() - start) >>> 0})
    }
  }

  // Claude's own word on its sessions: ~/.claude/sessions/<pid>.json says
  // "busy" while a turn runs and "shell" while a shell it started in the
  // background still runs after the turn — which is reported as done (Claude
  // wakes and carries on when the shell finishes). Only files of live
  // processes count. pi reports the same way through Reflex's pi extension
  // (integrations/pi): ~/.pi/agent/reflex/sessions/<pid>.json while
  // pi-fabric's background shells run.
  async readBusy(): Promise<string[]> {
    const out = await Host.run('/bin/sh', ['-c', BUSY], '', 1048576, 3000)
    return lines(textOr(stdoutOf(out), ''))
      .map(busyOf)
      .filter((s) => !isEmpty(s))
  }

  async screens(cur: Agent[], prev: Agent[]): Promise<Agent[]> {
    const out: Agent[] = []
    for (const a of cur) {
      if (!wantsScreen(Core.findAgent(prev, a.pane), a)) {
        out.push(a)
        continue
      }
      const r = await Term.readPane(at(this.cfg, a.pane), Term.bare(a.pane), a.status === 'blocked' ? 'detection' : 'recent_unwrapped', 40)
      out.push({...a, screen: textOr(r, '')})
    }
    return out
  }

  // herdr-core's agents (this Mac's and its machines'), this Mac's herdr's,
  // then herdr's other Macs'. `ok`: whether your agents can be reached; the
  // app keeps the core running by itself. `cm` and `hm` count the polls each
  // backend hasn't answered.
  async poller() {
    let prev: Agent[] = []
    let cm = 0
    let hm = 0
    for (;;) {
      try {
        const c = await Hc.listAgents(this.cfg.core, this.cfg.home)
        const h = await Herdr.listAgents(this.cfg.sock)
        const ms = await this.readMachines()
        const remote: Agent[] = []
        for (const m of ms) {
          const r = await Herdr.listAgents(Herdr.machineSock(machinesDir(this.cfg), m))
          // A machine that didn't answer (its tunnel is reconnecting, it
          // sleeps) keeps the agents it had, so coming back isn't a burst of
          // new agents.
          remote.push(...(r.ok ? Herdr.tags(m, r.v) : Herdr.on(m, prev).filter((a) => !Term.core(a.pane))))
        }
        const busy = await this.readBusy()
        const cs = c.ok ? [...marks(c.v.agents, busy), ...onDown(c.v.down, kept(true, prev))] : keptIf(cm, true, prev)
        const hs = h.ok ? marks(h.v, busy) : keptIf(hm, false, prev)
        const xs = await this.screens([...cs, ...hs, ...remote], prev)
        // Your agents can be reached: through the core or herdr (sessions
        // start in herdr while the core isn't there), or through herdr when you
        // chose it. The core counts as unreachable only once it has missed a
        // few polls in a row: one slow answer isn't your agents gone.
        const ok = this.cfg.backend !== 'herdr' ? c.ok || cm < UNREACHABLE_AFTER || h.ok : h.ok
        this.post({m: 'polled', ok, agents: xs})
        prev = xs
        cm = c.ok ? 0 : Math.min(cm + 1, 1000000)
        hm = h.ok ? 0 : Math.min(hm + 1, 1000000)
      } catch (err) {
        process.stderr.write('reflexd: poll failed: ' + String(err) + '\n')
      }
      await Host.sleep(700)
    }
  }

  // The index is this Mac's scan (kept in folders.tsv) and, for each machine
  // with a tunnel or added to herdr-core, the folders the app scanned there
  // (machines/<m>.folders, paths written "<m>:<path>"). A machine's folders
  // changing re-reads them without scanning this Mac again.
  async merge(here: string) {
    const hs = await this.readMachines()
    const cs = await Hc.machines(this.cfg.core, false)
    let there = ''
    const ms = [...hs, ...cs]
    const parts: string[] = []
    for (const m of ms) parts.push(textOr(await Host.readText(machinesDir(this.cfg) + '/' + m + '.folders', 8388608), ''))
    there = parts.map((p) => p + '\n').join('')
    this.post({m: 'indexed', folders: Ix.parse(here + '\n' + there)})
  }

  async reindex() {
    const r = await Host.run(this.cfg.scan, [], '', 33554432, 180000)
    const here = textOr(stdoutOf(r), '')
    await Host.put(this.cfg.data + '/folders.tsv', 'w', here)
    await this.merge(here)
  }

  // Only the other Macs' folders changed: this Mac's from its last scan.
  async remerge() {
    await this.merge(textOr(await Host.readText(this.cfg.data + '/folders.tsv', 33554432), ''))
  }

  async indexer() {
    for (;;) {
      try {
        await this.reindex()
      } catch (err) {
        process.stderr.write('reflexd: index failed: ' + String(err) + '\n')
      }
      await Host.sleep(900000)
    }
  }

  // Routing a request
  // -----------------

  async readSeen(xs: Agent[]): Promise<R.Seen[]> {
    const out: R.Seen[] = []
    for (const a of xs) out.push({agent: a, recent: textOr(await Term.readPane(at(this.cfg, a.pane), Term.bare(a.pane), 'recent_unwrapped', 40), '')})
    return out
  }

  // Earlier sessions the app found (sessions.tsv), the most relevant few.
  async readPasts(): Promise<P.Past[]> {
    return P.parse(textOr(await Host.readText(this.cfg.data + '/sessions.tsv', 8388608), ''))
  }

  jev = async (line: string, max: number, timeoutMs: number): Promise<string> => textOr(stdoutOf(await Host.run(this.cfg.jev, JEV_ARGS, line, max, timeoutMs)), '')

  act(dry: boolean, text: string, d: R.Decision): string {
    if (dry) return routeJson(R.decisionJson(d), '')
    switch (d.d) {
      case 'go':
        return routeJson(R.decisionJson(d), ',"dispatch":' + this.askText({m: 'enqueue', action: d.action, label: d.label, item: 0}))
      case 'choose':
        return routeJson(R.decisionJson(d), ',"posted":' + this.askText({m: 'post', kind: 'route', pane: '', agent: 'reflex', title: d.title, body: text, opts: d.opts}))
      case 'broke':
        this.askText({m: 'post', kind: 'note', pane: '', agent: 'reflex', title: 'could not route', body: d.message, opts: []})
        return routeJson(R.decisionJson(d), '')
    }
  }

  context(): {agents: Agent[]; folders: Folder[]} | undefined {
    const r = this.actor.ask({m: 'context'})
    return r.r === 'context' ? r : undefined
  }

  // What a request may go to. No machine named: every live session, and this
  // Mac's folders and earlier sessions (new work starts here). "@work" in the
  // bar: only work's sessions, folders and earlier sessions.
  async route(dry: boolean, text: string, harness: string, memory: string, machine: string): Promise<string> {
    const ctx = this.context()
    if (!ctx) return '{"ok":false,"error":"no context"}'
    const c = this.cfg
    const seen = await this.readSeen(scopeAgents(machine, ctx.agents).slice(0, 12))
    const cands = Ix.rank(text, Ix.on(machine, ctx.folders), 8)
    const pasts = P.rank(text, P.on(machine, await this.readPasts()), 5)
    const line = R.request(text, c.home, seen, cands, pasts, memory)
    let d = R.decideOutput(await this.jev(line, 4194304, 65000), text, c.home, harness, c.threshold, seen, cands, pasts)
    // Jev's transport failed (network, interruption): worth one retry.
    if (R.transient(d)) {
      await Host.sleep(300)
      d = R.decideOutput(await this.jev(line, 4194304, 65000), text, c.home, harness, c.threshold, seen, cands, pasts)
    }
    return this.act(dry, text, d)
  }

  // Jev's ranking of every candidate, live, for the Ask bar's list. Dry.
  // A harness with a profile: only that profile's agents and sessions; a
  // bare harness: any of the harness's.
  async candidates(text: string, harness: string, memory: string, machine: string, profile: string): Promise<string> {
    const ctx = this.context()
    if (!ctx) return '{"ok":false,"error":"no context"}'
    const c = this.cfg
    const mine = (a: Agent) => isEmpty(harness) || (harness === a.kind && (isEmpty(profile) || profile === a.profile))
    const seen = await this.readSeen(scopeAgents(machine, ctx.agents).filter(mine).slice(0, 12))
    const cands = Ix.rank(text, Ix.on(machine, ctx.folders), 8)
    const pasts = P.rank(text, P.harness(harness, P.on(machine, await this.readPasts()), profile), 5)
    const line = R.request(text, c.home, seen, cands, pasts, memory)
    const t0 = Host.nowMs()
    const out = await this.jev(line, 4194304, 65000)
    const t1 = Host.nowMs()
    return R.candidatesOutput(out, text, c.home, spec(orElse(harness, c.harness), profile), c.threshold, seen, cands, pasts, (t1 - t0) >>> 0)
  }

  // The JSON request for the candidates routing would show Jev (for a UI or a
  // debugging session), without calling Jev.
  async explain(text: string, memory: string, machine: string): Promise<string> {
    const ctx = this.context()
    if (!ctx) return '{"ok":false}'
    const seen = await this.readSeen(scopeAgents(machine, ctx.agents).slice(0, 12))
    const all = await this.readPasts()
    return (
      '{"ok":true,"jev":' +
      trim(R.request(text, this.cfg.home, seen, Ix.rank(text, Ix.on(machine, ctx.folders), 8), P.rank(text, P.on(machine, all), 5), memory)) +
      '}'
    )
  }

  // A side question for one specific agent (from its popout), routed by the
  // same per-harness rules as a routed "btw".
  side(pane: string, text: string): string {
    const ctx = this.context()
    if (!ctx) return '{"ok":false}'
    const a = Core.findAgent(ctx.agents, pane)
    if (!a) return '{"ok":false,"error":"no agent in that pane"}'
    return this.act(false, text, R.agentDecision(true, a, text, this.cfg.home, this.cfg.harness))
  }

  // One tiny typed Jev call, to prove the credentials and measure latency.
  async jevPing(): Promise<string> {
    const t0 = Host.nowMs()
    const out = await this.jev(PING, 1048576, 45000)
    const ms = (Host.nowMs() - t0) >>> 0
    const r = R.response(out)
    return r.ok
      ? Js.obj([Js.kv('ok', 'true'), Js.kv('ms', Js.num(ms))])
      : Js.obj([Js.kv('ok', 'false'), Js.kv('ms', Js.num(ms)), Js.kv('error', Js.str(r.msg))])
  }

  folders(q: string, machine: string): string {
    const ctx = this.context()
    if (!ctx) return '{"ok":false}'
    return '{"ok":true,"folders":' + Js.arr(Ix.rank(q, folderScope(machine, ctx.folders), 12).map((f) => folderJson(this.cfg.home, f))) + '}'
  }

  // HTTP
  // ----

  // Pairing a phone: the app writes a one-time code to pair.txt (and wipes it
  // after ten minutes); the phone trades it for its token here, once — the
  // file is wiped as the token goes out. The QR never carries the token.
  async pair(given: string): Promise<string> {
    const file = this.cfg.data + '/pair.txt'
    const code = trim(textOr(await Host.readText(file, 4096), ''))
    if (!(code === given && !isEmpty(code))) return Http.json(403, '{"ok":false,"error":"used or expired"}')
    await Host.put(file, 'w', '')
    return Http.json(200, Js.obj([Js.kv('ok', 'true'), Js.kv('token', Js.str(this.cfg.token))]))
  }

  async serveStatic(name: string): Promise<string | Buffer> {
    if (!(safeName(name) && !name.startsWith('.'))) return Http.response(404, 'text/plain', 'not found')
    const r = await Host.readText(this.cfg.web + '/' + name, 8388608)
    if (!r.ok) return Http.response(404, 'text/plain', 'not found')
    // The phone's terminal (xterm.js) is vendored with its version in each
    // file's name, so the phone keeps it; the page itself is always fresh.
    return Http.responseWith(200, Http.contentType(name), name.startsWith('xterm-') ? 'public, max-age=31536000, immutable' : 'no-store', r.v)
  }

  // The phone reads a terminal it sized as it shows (`visible`, scrolled where
  // herdr is); otherwise its recent rows. A herdr-core terminal's screen with
  // its colors comes from the app's viewer; everything else from the pane's
  // own backend.
  async paneRead(id: string, format: string, source: string, lines: number): Promise<Res<string>> {
    const ansi = format === 'ansi'
    if (Term.core(id) && ansi) return Link.screen(this.cfg.link, id)
    if (ansi) return Term.readPaneAnsi(at(this.cfg, id), Term.bare(id), source === 'visible' ? 'visible' : 'recent', lines)
    return Term.readPane(at(this.cfg, id), Term.bare(id), 'recent_unwrapped', lines)
  }

  // The phone's size and scrolling: herdr's `terminal session control`, or
  // the app's viewer of a herdr-core terminal (see link.ts).
  async termControl(body: J): Promise<string> {
    const pane = Js.textAt(body, 'pane')
    const cols = Js.asU32(Js.get(body, 'cols'), 0)
    const rows = Js.asU32(Js.get(body, 'rows'), 0)
    const take = isTrue(Js.textAt(body, 'take'))
    const scroll = Js.textAt(body, 'scroll')
    const n = Js.asU32(Js.get(body, 'n'), 0)
    if (Term.core(pane)) return Link.control(this.cfg.link, pane, cols, rows, take, scroll, n)
    // One short-lived `herdr terminal session control` at the phone's columns
    // and rows, carrying a scroll per notch. A terminal another client holds
    // (the Mac's window) is left as it is unless `take`, and the reply says it
    // is held.
    const args = [
      '-u',
      'HERDR_SESSION',
      'HERDR_SOCKET_PATH=' + at(this.cfg, pane),
      'herdr',
      'terminal',
      'session',
      'control',
      Term.bare(pane),
      '--cols',
      showU32(Math.max(20, Math.min(cols, 400))),
      '--rows',
      showU32(Math.max(5, Math.min(rows, 200))),
      ...(take ? ['--takeover'] : []),
    ]
    const input = scroll === 'up' || scroll === 'down' ? ('{"type":"terminal.scroll","lines":3,"direction":"' + scroll + '"}\n').repeat(Math.min(n, 40)) : ''
    const r = await Host.run('/usr/bin/env', args, input, 1048576, 8000)
    if (!r.ok) return Js.obj([Js.kv('ok', 'false'), Js.kv('error', Js.str(r.msg))])
    return Js.obj([
      Js.kv('ok', Js.bool(r.v.status === 0)),
      Js.kv('held', Js.bool(r.v.out.includes('already has an attached client'))),
      Js.kv('error', Js.str(trim(r.v.err))),
    ])
  }

  // Literal text into a pane, no Enter: herdr's pane.send_text, or typed into
  // the app's viewer of a herdr-core terminal.
  sendText = (pane: string, text: string): Promise<Res<J>> =>
    Term.core(pane) ? Link.typed(this.cfg.link, pane, text) : Herdr.sendText(at(this.cfg, pane), Term.bare(pane), text)

  async endpoint(ep: string, req: Http.Req, body: J): Promise<string | Buffer> {
    const c = this.cfg
    const t = (k: string) => Js.textAt(body, k)
    const ok = (json: string) => Http.json(200, json)
    const paneJson = (r: Res<string>) =>
      r.ok ? Js.obj([Js.kv('ok', 'true'), Js.kv('text', Js.str(r.v))]) : Js.obj([Js.kv('ok', 'false'), Js.kv('error', Js.str(r.msg))])
    switch (ep) {
      case '/api/state':
        return ok(this.askText({m: 'query'}))
      case '/api/route':
        return ok(await this.route(isTrue(t('dry')), t('text'), spec(orElse(t('harness'), c.harness), t('profile')), t('memory'), t('machine')))
      case '/api/candidates':
        return ok(await this.candidates(t('text'), t('harness'), t('memory'), t('machine'), t('profile')))
      case '/api/explain':
        return ok(await this.explain(t('text'), t('memory'), t('machine')))
      case '/api/send':
        return ok(this.askText({m: 'enqueue', action: {type: 'prompt', pane: t('pane'), text: t('text')}, label: '→ ' + orElse(t('label'), t('pane')), item: 0}))
      // `profile`: the harness profile to start it in ("" or none: your own,
      // or the machine's default for that harness).
      case '/api/spawn': {
        const kind = orElse(t('kind'), c.harness)
        const profile = t('profile')
        const action: Action = profile ? {type: 'spawn', cwd: t('cwd'), kind, text: t('text'), profile} : {type: 'spawn', cwd: t('cwd'), kind, text: t('text')}
        return ok(this.askText({m: 'enqueue', action, label: 'new ' + spec(kind, profile) + ' in ' + R.leaf(t('cwd')), item: 0}))
      }
      case '/api/cancel':
        return ok(this.askText({m: 'cancel', id: Js.asU32(Js.get(body, 'id'), 0)}))
      case '/api/answer': {
        const item = Js.asU32(Js.get(body, 'item'), 0)
        print('answer item ' + showU32(item) + ' key ' + t('key') + ' from ' + Http.header(req, 'user-agent'))
        return ok(this.askText({m: 'answer', item, key: t('key')}))
      }
      case '/api/dismiss':
        return ok(this.askText({m: 'dismiss', item: Js.asU32(Js.get(body, 'item'), 0)}))
      case '/api/pane': {
        const q = (k: string) => Http.query(req, k)
        return ok(paneJson(await this.paneRead(q('id'), q('format'), q('source'), readU32(q('lines')) ?? 120)))
      }
      case '/api/folders':
        return ok(this.folders(Http.query(req, 'q'), Http.query(req, 'machine')))
      case '/api/reindex':
        void (isTrue(t('machines')) ? this.remerge() : this.reindex()).catch(() => {})
        return ok('{"ok":true}')
      case '/api/health':
        return ok('{"ok":true,"service":"reflexd"}')
      case '/api/pair':
        return this.pair(t('code'))
      case '/api/side':
        return ok(this.side(t('pane'), t('text')))
      case '/api/jev/ping':
        return ok(await this.jevPing())
      case '/api/focus':
        return ok(paneJson(okDetail(await Term.focus(at(c, t('pane')), Term.bare(t('pane'))), 'focused')))
      // A note from the app (a background session finished or needs you): an
      // inbox item that stays until you open or clear it.
      case '/api/note':
        return ok(this.askText({m: 'post', kind: 'note', pane: t('pane'), agent: t('agent'), title: t('title'), body: t('body'), opts: []}))
      case '/api/keys':
        return ok(paneJson(okDetail(await Term.press(at(c, t('pane')), Term.bare(t('pane')), t('key')), 'pressed')))
      case '/api/text':
        return ok(paneJson(okDetail(await this.sendText(t('pane'), t('text')), 'typed')))
      case '/api/term':
        return ok(await this.termControl(body))
      case '/api/close':
        return ok(paneJson(okDetail(await Term.closePane(at(c, t('pane')), Term.bare(t('pane'))), 'closed')))
      case '/api/sessions':
        return ok(Js.obj([Js.kv('ok', 'true'), Js.kv('sessions', Js.arr((await this.readPasts()).map(P.pastJson)))]))
      case '/api/resume': {
        const action: Action = {type: 'resume', cwd: t('cwd'), kind: orElse(t('kind'), 'claude'), session: t('session'), mode: orElse(t('mode'), 'resume'), text: t('text')}
        if (t('profile')) action.profile = t('profile')
        return ok(this.askText({m: 'enqueue', action, label: 'resume ' + orElse(t('label'), R.leaf(t('cwd'))), item: 0}))
      }
      // The agents the core lost (a restart, a lost holder): shown to bring back.
      case '/api/stopped':
        return ok(await Hc.listStopped(c.core))
      case 'static':
        return this.serveStatic(req.path === '/' || req.path === '' ? 'index.html' : req.path.slice(1))
      default:
        return Http.json(404, '{"ok":false,"error":"no such endpoint"}')
    }
  }

  async dispatch(req: Http.Req): Promise<string | Buffer> {
    const ep = ENDPOINTS.has(req.path) ? req.path : req.path.startsWith('/api/') ? 'missing' : 'static'
    const open = ep === 'static' || ep === '/api/health' || ep === '/api/pair'
    if (!open && Http.token(req) !== this.cfg.token) return Http.json(401, '{"ok":false,"error":"bad token"}')
    const b = Js.read(req.body)
    return this.endpoint(ep, req, b.ok ? b.v : Js.EMPTY_OBJ)
  }

  conn(s: Socket) {
    readRequest(s, 1048576, 10000).then(
      async (raw) => {
        if (raw === null) return s.destroy()
        let resp: string | Buffer
        try {
          resp = await this.dispatch(Http.parse(raw))
        } catch (err) {
          resp = Http.json(500, Js.obj([Js.kv('ok', 'false'), Js.kv('error', Js.str(String((err as Error)?.message ?? err)))]))
        }
        s.end(resp)
      },
      () => s.destroy(),
    )
  }
}

// One HTTP/1.1 request from an accepted socket: the head through "\r\n\r\n"
// plus Content-Length body bytes (null on a timeout, an error or past `max`).
function readRequest(s: Socket, max: number, timeoutMs: number): Promise<string | null> {
  return new Promise((resolve) => {
    let buf = Buffer.alloc(0)
    let need = -1
    let finished = false
    const end = (v: string | null) => {
      if (finished) return
      finished = true
      clearTimeout(timer)
      s.removeAllListeners('data')
      resolve(v)
    }
    const timer = setTimeout(() => end(null), timeoutMs)
    s.on('data', (b: Buffer) => {
      buf = Buffer.concat([buf, b])
      if (buf.length > max) return end(null)
      if (need < 0) {
        const at = buf.indexOf('\r\n\r\n')
        if (at >= 0) {
          const hlen = at + 4
          need = hlen + contentLength(buf.subarray(0, hlen).toString('latin1'))
          if (need > max) return end(null)
        }
      }
      if (need >= 0 && buf.length >= need) end(buf.toString('utf8'))
    })
    s.on('end', () => end(buf.toString('utf8')))
    s.on('error', () => end(null))
  })
}

function contentLength(head: string): number {
  const at = head.toLowerCase().indexOf('\r\ncontent-length:')
  if (at < 0) return 0
  let j = at + '\r\ncontent-length:'.length
  while (head[j] === ' ') j++
  let v = 0
  while (j < head.length && head.charCodeAt(j) >= 48 && head.charCodeAt(j) <= 57) v = v * 10 + (head.charCodeAt(j++) - 48)
  return v
}

const ENDPOINTS = new Set([
  '/api/state',
  '/api/route',
  '/api/candidates',
  '/api/explain',
  '/api/send',
  '/api/spawn',
  '/api/cancel',
  '/api/answer',
  '/api/dismiss',
  '/api/pane',
  '/api/folders',
  '/api/reindex',
  '/api/health',
  '/api/side',
  '/api/focus',
  '/api/pair',
  '/api/note',
  '/api/keys',
  '/api/text',
  '/api/term',
  '/api/close',
  '/api/sessions',
  '/api/resume',
  '/api/stopped',
  '/api/jev/ping',
])

const isTrue = (s: string) => s === 'true' || s === '1'

const safeName = (s: string) => /^[a-zA-Z0-9._-]*$/.test(s)

const routeJson = (d: string, extra: string) => '{"ok":true,"route":' + d + extra + '}'

const JEV_ARGS = ['--', 'serve', '--timeout-ms', '60000', '1', '60000']

const PING = '{"id":1,"op":"jev","request":{"state":"Reflex setup check.","questions":{"ready":{"type":"noul","instructions":"Is this a setup check?"}}}}\n'

// Profiles' too (`reflex profile`: ~/.reflex/profiles/claude/<name>/claude is
// a profile's CLAUDE_CONFIG_DIR, …/pi/<name>/pi its pi agent folder).
const BUSY =
  'for f in "$HOME"/.claude/sessions/*.json "$HOME"/.pi/agent/reflex/sessions/*.json "$HOME"/.reflex/profiles/claude/*/claude/sessions/*.json "$HOME"/.reflex/profiles/pi/*/pi/reflex/sessions/*.json; do [ -f "$f" ] || continue; p=${f##*/}; p=${p%.json}; kill -0 "$p" 2>/dev/null && { cat "$f"; echo; }; done'

// herdr's refusals, and herdr-core's: "blocked: …" (waiting on you),
// "unavailable: …" (starting, or a lost terminal waiting for its new shell).
const retryable = (msg: string) =>
  msg.includes('agent_not_ready') || msg.includes('not an active') || msg.includes('agent_blocked') || msg.startsWith('blocked:') || msg.startsWith('unavailable:')

const readyStatus = (s: string) => s === 'idle' || s === 'done'

// Ids restart with reflexd but the backends keep agent names, so a random
// suffix keeps a fresh "rx1" from colliding with one an earlier run started.
const agentName = (id: number, r: number) => 'rx' + showU32(id) + '-' + showU32(r % 10000)

// Claude and pi take a session id to start with: Reflex chooses it, so the
// agent's session is known from its first moment (its question cards, the
// earlier sessions it stops being one of).
function freshSession(kind: string): string {
  const [a, b, c, d] = [Host.randomU32(), Host.randomU32(), Host.randomU32(), Host.randomU32()]
  return kind === 'claude' || kind === 'pi' ? Hc.uuid(a, b, c, d) : ''
}

// "busy" during a turn; "shell" after it, while a background shell runs. A
// session parked into a background job (parkedJobId) keeps the "busy" it had
// when it was parked — its work runs in that job, which reports itself — so
// its own "busy" is not believed.
function busyOf(line: string): string {
  const r = Js.read(line)
  if (!r.ok) return ''
  const v = r.v
  const status = Js.textAt(v, 'status')
  return (status === 'busy' && isEmpty(Js.textAt(v, 'parkedJobId'))) || status === 'shell' ? Js.textAt(v, 'sessionId') : ''
}

// An agent's session is its id (Claude) or its session file (pi, as herdr
// reports it: …/<time>_<id>.jsonl); the status files carry the id.
const sameSession = (session: string, id: string) => session === id || session.endsWith('_' + id + '.jsonl')

// Done or idle, but its shell still runs: still working.
const marks = (xs: Agent[], busy: string[]): Agent[] =>
  xs.map((a) =>
    (a.kind === 'claude' || a.kind === 'pi') && !isEmpty(a.session) && busy.some((h) => sameSession(a.session, h)) && (a.status === 'finished' || a.status === 'idle')
      ? {...a, status: 'working'}
      : a,
  )

// The agents in `xs` that one backend reports here: herdr-core's (all its
// machines') or this Mac's herdr's.
const kept = (core: boolean, xs: Agent[]) => xs.filter((a) => (core ? Term.core(a.pane) : !Term.core(a.pane) && isEmpty(Herdr.machine(a.pane))))

// How many polls (about a minute) a backend that stopped answering keeps its
// agents: a blip isn't agents vanishing and coming back as new, and one that
// was stopped doesn't leave them behind for good.
const GRACE = 90
const UNREACHABLE_AFTER = 4

const keptIf = (misses: number, core: boolean, prev: Agent[]) => (misses < GRACE ? kept(core, prev) : [])

// The core's agents on machines whose line is down: kept as they were.
const onDown = (down: string[], xs: Agent[]) => xs.filter((a) => down.includes(Herdr.machine(a.pane)))

// A blocked agent's screen is read every poll: its question can change while
// it stays blocked (the next question, a ticked box, the review).
function wantsScreen(prev: Agent | undefined, a: Agent): boolean {
  if (!prev) return Core.isBlocked(a.status) || Core.isReady(a.status)
  return Core.isBlocked(a.status) || ((prev.seq !== a.seq || showStatus(prev.status) !== showStatus(a.status)) && Core.isReady(a.status))
}

const scopeAgents = (m: string, xs: Agent[]) => (isEmpty(m) ? xs : Herdr.on(m, xs))

// The Ask bar's folders: every Mac's (no machine), this Mac's ("."), or one
// machine's.
const folderScope = (m: string, fs: Folder[]) => (isEmpty(m) ? fs : m === '.' ? Ix.on('', fs) : Ix.on(m, fs))

const folderJson = (home: string, f: Folder) =>
  Js.obj([
    Js.kv('path', Js.str(f.path)),
    Js.kv('short', Js.str(R.short(home, f.path))),
    Js.kv('name', Js.str(f.name)),
    Js.kv('desc', Js.str(f.desc)),
    Js.kv('branch', Js.str(f.branch)),
    Js.kv('ageHours', Js.num(f.age)),
  ])

export type {Opt}

// main
// ----

async function main() {
  // A task that fails is logged, never the end of the daemon: the actor, the
  // poller and every other task go on.
  process.on('unhandledRejection', (err) => process.stderr.write('reflexd: ' + String((err as Error)?.stack ?? err) + '\n'))
  process.on('uncaughtException', (err) => process.stderr.write('reflexd: ' + String(err?.stack ?? err) + '\n'))
  const cfg = load()
  await Host.mkdirP(cfg.data)
  const d = new Daemon(cfg)
  const server = createServer({allowHalfOpen: true}, (s) => d.conn(s))
  await new Promise<void>((resolve) => {
    server.once('error', (err) => {
      process.stderr.write('reflexd: cannot listen on ' + cfg.bind + ':' + showU32(cfg.port) + ': ' + String((err as Error).message) + '\n')
      process.exit(1)
    })
    server.listen({port: cfg.port, host: cfg.bind, backlog: 512}, () => resolve())
  })
  const start = Host.nowMs()
  print(readyLine(cfg))
  void d.ticker(start)
  void d.poller()
  void d.indexer()
  // With REFLEX_EXIT_WITH_PARENT=1 (the app sets it), reflexd exits once its
  // parent is gone, so a crashed app never leaves a daemon holding the port.
  if (Host.env('REFLEX_EXIT_WITH_PARENT', '') === '1') {
    const parent = Host.ppid()
    setInterval(() => {
      if (Host.ppid() !== parent) {
        process.stderr.write('reflexd: parent exited\n')
        process.exit(0)
      }
    }, 2000)
  }
}

if (import.meta.main) void main()
