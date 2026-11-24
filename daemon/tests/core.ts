// The herdr-core adapter against a real, disposable core (scripts/test-core.py
// starts it with fake agents): which terminals are agents and what they are,
// a prompt typed in and answered, keys, reads, a start and a close — and
// which backend each kind of pane id goes to. Ported from tests/core.bend.

import * as Hc from '../src/hc.ts'
import * as Js from '../src/js.ts'
import type {J, Res} from '../src/js.ts'
import type {Agent} from '../src/model.ts'
import {showStatus} from '../src/model.ts'
import * as Term from '../src/term.ts'

const print = (s: string) => process.stdout.write(s + '\n')
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

const agents = (xs: Agent[]) =>
  xs
    .map((a) => 'agent ' + a.name + ' kind=' + a.kind + ' status=' + showStatus(a.status) + ' session=' + a.session + ' title=' + a.title + ' parent=' + a.parent + '\n')
    .join('')
const listed = (r: Res<Hc.Listed>) => (r.ok ? agents(r.v.agents) : 'list failed: ' + r.msg + '\n')
const res = (r: Res<J>) => (r.ok ? 'ok' : 'fail ' + r.msg)
const txt = (r: Res<string>) => (r.ok ? r.v : 'fail ' + r.msg)
const has = (r: Res<string>, probe: string) => (r.ok ? (r.v.includes(probe) ? 'yes' : 'no: ' + r.v) : 'fail ' + r.msg)
const yes = (b: boolean) => (b ? 'yes' : 'no')

const route = (p: string) =>
  p + ' core=' + yes(Term.core(p)) + ' at=' + Term.at('/herdr.sock', '/core.sock', '/m', p) + ' bare=' + Term.bare(p) + ' on=' + Term.paneOn('work', p) + '\n'

const gotLabels = (r: Res<J>) => (r.ok ? Hc.label(r.v, 'reflex.kind') + ',' + Hc.label(r.v, 'reflex.session') + ' argv0=' + Hc.argv0(Js.get(r.v, 'argv')) : 'fail ' + r.msg)

async function before(s: string, home: string) {
  print(route('t7') + route('box/t12') + route('wBE:p1') + route('work/wBE:p1') + route(''))
  print('uuid ' + Hc.uuid(305419896, 2596069104, 4294967295, 0))
  print(listed(await Hc.listAgents(s, home)))
  print('echo status ' + (await Hc.paneStatus(s, 'echo')))
  print('prompt ' + res(await Hc.prompt(s, 'echo', 'hello there')))
  print('prompt before ready ' + res(await Hc.prompt(s, 'slow', 'too soon')))
  print('prompt while blocked ' + res(await Hc.prompt(s, 'asks', 'over a question')))
  await sleep(4500)
  print('echo answered ' + has(await Hc.readPane(s, 'echo', 'recent_unwrapped', 20), 'got:hello there'))
  const k = await Hc.press(s, 'echo', 'k e y s enter')
  await sleep(4000)
  print('keys ' + res(k) + ' ' + has(await Hc.readPane(s, 'echo', 'visible', 20), 'got:keys'))
  print('run ' + txt(await Hc.run(s, '/bin/sh', 'rx9-1', '', '/tmp', 'pi', 'sess-1', ['--version'], '')))
  await sleep(1500)
  print('run labels ' + gotLabels(await Hc.call(s, 'terminal.get', '{"terminal":"rx9-1"}', 3000)))
  print('close ' + res(await Hc.closePane(s, 'rx9-1')))
  print('closed status [' + (await Hc.paneStatus(s, 'rx9-1')) + ']')
  print('up ' + yes(await Hc.up(s)) + ' ' + yes(await Hc.up('/nonexistent/core.sock')))
}

// After the test restarted the core: the agents it lost, as /api/stopped has them.
async function after(s: string) {
  print('stopped-json ' + (await Hc.listStopped(s)))
}

const s = process.env.REFLEX_TEST_CORE ?? ''
const home = process.env.REFLEX_TEST_HOME ?? ''
if (process.env.REFLEX_TEST_PHASE === 'after') await after(s)
else await before(s, home)
