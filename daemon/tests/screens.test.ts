// Ported from daemon/tests/{asks,sent,machines,harness}.bend: the same cases,
// printed the same way, held to what the Bend daemon printed for them
// (tests/golden/*.txt, captured from the Bend binaries before the port).

import {expect, test} from 'bun:test'
import {readFileSync} from 'node:fs'
import * as Core from '../src/core.ts'
import * as Ix from '../src/folders.ts'
import * as Herdr from '../src/herdr.ts'
import type {Agent, Folder, Opt} from '../src/model.ts'
import {actionJson} from '../src/model.ts'
import * as P from '../src/past.ts'
import * as R from '../src/route.ts'

const golden = (name: string) => readFileSync(new URL(`./golden/${name}.txt`, import.meta.url), 'utf8')

// Which answers Reflex reads off a blocked agent's screen (Core.options), on
// screens captured from Claude Code: an arrow menu, a multi-select, the
// review step, and an idle prompt that must offer nothing.
test('asks: the answers read off captured Claude Code screens', () => {
  const show = (xs: Opt[]) => xs.map((o) => '  ' + o.key + ' ' + o.label + '  =>  ' + actionJson(o.action) + '\n').join('')
  const trust =
    " Quick safety check: Is this a project you created or one you trust?\n\n Claude Code'll be able to read, edit, and execute files here.\n\n Security guide\n\n ❯ No, exit\n   Yes, I trust this folder\n\n Enter to confirm · Esc to cancel"
  const multi =
    '←  ☒ Season  ☐ Fruits  ✔ Submit  →\n\nWhich fruits do you like?\n\n❯ 1. [✔] Apple\n         Crisp and sweet.\n  2. [ ] Banana\n         Soft.\n  3. [ ] Cherry\n  4. [ ] Type something\n     Submit\n──────\n  5. Chat about this\n\nEnter to select · Tab/Arrow keys to navigate · Esc to cancel'
  const review = 'Review your answers\n\n ● What is your favorite season?\n   → Autumn\n\nReady to submit your answers?\n\n❯ 1. Submit answers\n  2. Cancel'
  const idle = '⏺ Red\n\n✻ Brewed for 7s\n\n──────────────\n❯ \n──────────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)'
  const below = 'Pick one\n\n   Alpha\n   Beta\n ❯ Gamma\n   Delta\n'
  const out = [
    'trust:\n' + show(Core.options(trust, 'p')),
    'multi:\n' + show(Core.options(multi, 'p')),
    'review:\n' + show(Core.options(review, 'p')),
    'idle:\n' + show(Core.options(idle, 'p')),
    'below:\n' + show(Core.options(below, 'p')),
  ]
  expect(out.map((l) => l + '\n').join('')).toBe(golden('asks'))
})

// Whether a prompt Reflex sent sits typed but unsent in the agent's input, or
// never arrived (Core.promptTyped, Core.promptMissing), on screens shaped like
// Claude Code's: the request in the box (its Enter taken as a new line), sent
// and in the conversation, lost, collapsed into a paste, wrapped in the box;
// then a working agent and a screen with no box at all.
test('sent: a prompt typed but unsent, or never arrived', () => {
  const ask = 'fix the flaky test in coralbricks please'
  const rule = '──────────────────────────────────────'
  const foot = '  ⏵⏵ bypass permissions on (shift+tab to cycle)'
  const typed = '⏺ Done earlier.\n\n' + rule + '\n❯ fix the flaky test in coralbricks please\n  \n' + rule + '\n' + foot
  const sent = '❯ fix the flaky test in coralbricks please\n\n⏺ Looking at the tests…\n\n' + rule + '\n❯ \n' + rule + '\n' + foot
  const lost = '⏺ Done earlier.\n\n' + rule + '\n❯ \n' + rule + '\n' + foot
  const pasted = '⏺ Done earlier.\n\n' + rule + '\n❯ [Pasted text #1 +12 lines]\n' + rule + '\n' + foot
  const wrapped = '⏺ Done earlier.\n\n' + rule + '\n❯ fix the fla\n  ky test in coralbricks please\n' + rule + '\n' + foot
  const shell = '$ fix the flaky test in coralbricks please\nzsh: command not found: fix'
  const yes = (b: boolean) => (b ? 'yes' : 'no')
  const line = (name: string, status: string, screen: string) =>
    name + ': typed ' + yes(Core.promptTyped(status, screen, Core.probe(ask))) + ', missing ' + yes(Core.promptMissing(status, screen, Core.probe(ask)))
  const out = [
    line('typed', 'idle', typed),
    line('sent', 'idle', sent),
    line('lost', 'idle', lost),
    line('lost, done', 'done', lost),
    line('pasted', 'idle', pasted),
    line('wrapped', 'idle', wrapped),
    line('working', 'working', typed),
    line('no box', 'idle', shell),
  ]
  expect(out.map((l) => l + '\n').join('')).toBe(golden('sent'))
})

// Agents on other machines: which herdr socket a pane id goes to, the id that
// herdr knows it by, and a machine's agents kept while its tunnel is down.
// Places on them: a folder or session "work:/Users/you/VCS/app", its machine,
// its path there, how Jev reads it, and the folders a request scoped to one
// machine may start in.
test('machines: panes, places and folders on other machines', () => {
  const line = (pane: string) =>
    pane + '  =>  machine ' + Herdr.machine(pane) + ', pane ' + Herdr.bare(pane) + ', socket ' + Herdr.at('/local/herdr.sock', '/data/machines', pane)
  const agent = (pane: string): Agent => ({pane, name: 'a', kind: 'claude', status: 'idle', cwd: '/w', title: '', seq: 0, session: '', screen: '', parent: ''})
  const panes = (xs: Agent[]) => xs.map((a) => a.pane + ' ').join('')
  const place = (path: string) =>
    path +
    '  =>  machine ' +
    Ix.machineOf(path) +
    ', path ' +
    Ix.pathOn(path) +
    ', reads ' +
    R.short('/Users/me', path) +
    ', pane ' +
    Herdr.paneOn(Ix.machineOf(path), 'w3:p1')
  const folder = (path: string): Folder => ({path, name: 'f', desc: '', recent: '', branch: '', age: 0, uses: 0})
  const paths = (xs: Folder[]) => xs.map((f) => f.path + ' ').join('')
  const out = [
    line('w1:p1'),
    line('work/w1:p1'),
    line(''),
    'tagged: ' + panes(Herdr.tags('work', [agent('w1:p1'), agent('w2:p3')])),
    'kept on work: ' + panes(Herdr.on('work', [agent('w1:p1'), agent('work/w1:p1'), agent('box/w1:p1'), agent('work/w2:p3')])),
    place('/Users/me/VCS/app'),
    place('work:/Users/you/VCS/app'),
    place('work:/opt/work'),
    place(''),
    'agent pane work/w1:p2 on: ' + Ix.paneMachine('work/w1:p2') + ', w1:p2 on: [' + Ix.paneMachine('w1:p2') + ']',
    'here: ' + paths(Ix.on('', [folder('/Users/me/a'), folder('work:/Users/you/b'), folder('box:/c')])),
    'on work: ' + paths(Ix.on('work', [folder('/Users/me/a'), folder('work:/Users/you/b'), folder('box:/c'), folder('work:/d')])),
  ]
  expect(out.map((l) => l + '\n').join('')).toBe(golden('machines'))
})

test('harness: earlier sessions of one harness, on one machine', () => {
  const xs: P.Past[] = [
    {agent: 'claude', id: 'a', cwd: '/a', title: '', last: '', age: 0, state: 'past'},
    {agent: 'pi', id: 'b', cwd: '/b', title: '', last: '', age: 0, state: 'past'},
    {agent: 'claude', id: 'c', cwd: 'work:/c', title: '', last: '', age: 0, state: 'past'},
  ]
  const ids = (ps: P.Past[]) => ps.map((p) => p.id + ' ').join('')
  const out = [
    'all: ' + ids(P.harness('', xs)),
    'claude: ' + ids(P.harness('claude', xs)),
    'local claude: ' + ids(P.harness('claude', P.on('', xs))),
    'codex: ' + ids(P.harness('codex', xs)),
  ]
  expect(out.map((l) => l + '\n').join('')).toBe(golden('harness'))
})
