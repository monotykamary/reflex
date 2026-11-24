// Where an agent lives: a herdr-core terminal or a herdr pane. Reflex runs on
// both while people move over: herdr-core is the default, herdr's agents stay
// listed and reachable until they end.
//
// The pane id says which: herdr's ids always hold a ':' ("w1:p2",
// "work/w1:p2"), herdr-core's never do ("t7", "box/t7"). Everything above
// this module treats both alike: it asks `at` for the socket, `bare` for the
// id that socket knows it by, and calls the functions below with them.
// herdr-core's own core answers for its machines' terminals too, so a core id
// goes to the local core's socket whole.

import * as Hc from './hc.ts'
import * as Herdr from './herdr.ts'
import * as Js from './js.ts'
import type {J, Res} from './js.ts'

// A herdr-core terminal (not a herdr pane).
export const core = (pane: string): boolean => pane.length > 0 && pane.split('/').every((p) => !p.includes(':'))

// The socket a pane lives behind: the core's, this Mac's herdr's, or another
// Mac's herdr's (forwarded into `dir`).
export const at = (herdr: string, hc: string, dir: string, pane: string): string => (core(pane) ? hc : Herdr.at(herdr, dir, pane))

// The id the pane's socket knows it by.
export const bare = (pane: string): string => (core(pane) ? pane : Herdr.bare(pane))

// A pane started on machine m, as reflexd knows it. The core already names its
// machines' terminals "box/t7".
export const paneOn = (m: string, pane: string): string => (core(pane) ? pane : Herdr.paneOn(m, pane))

// Calls
// -----

export const readPane = (sock: string, pane: string, source: string, lines: number): Promise<Res<string>> =>
  core(pane) ? Hc.readPane(sock, pane, source, lines) : Herdr.readPane(sock, pane, source, lines)

// With its colors where the backend has them (herdr's reads do; the core's are
// text: its colors come through a stream, see the app's CoreLink).
export const readPaneAnsi = (sock: string, pane: string, source: string, lines: number): Promise<Res<string>> =>
  core(pane) ? Hc.readPane(sock, pane, source, lines) : Herdr.readPaneAnsi(sock, pane, source, lines)

export const prompt = (sock: string, pane: string, text: string): Promise<Res<J>> => (core(pane) ? Hc.prompt(sock, pane, text) : Herdr.prompt(sock, pane, text))

export const press = (sock: string, pane: string, key: string): Promise<Res<J>> => (core(pane) ? Hc.press(sock, pane, key) : Herdr.press(sock, pane, key))

export const paneStatus = (sock: string, pane: string): Promise<string> => (core(pane) ? Hc.paneStatus(sock, pane) : Herdr.paneStatus(sock, pane))

export const closePane = (sock: string, pane: string): Promise<Res<J>> => (core(pane) ? Hc.closePane(sock, pane) : Herdr.closePane(sock, pane))

// The core draws nothing: there is no window of its to bring forward. The app
// opens its own terminal on the agent instead.
export const focus = (sock: string, pane: string): Promise<Res<J>> => (core(pane) ? Promise.resolve(Js.done(Js.NULL)) : Herdr.focus(sock, pane))
