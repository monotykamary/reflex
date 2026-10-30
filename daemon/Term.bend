import Base
import ./Js.bend as Js
import ./Model.bend as M
import ./Herdr.bend as Herdr
import ./Hc.bend as Hc
import ./vendor/strict-json/json.bend as J

# Where an agent lives: a herdr-core terminal or a herdr pane. Reflex runs
# on both while people move over: herdr-core is the default, herdr's agents
# stay listed and reachable until they end.
#
# The pane id says which: herdr's ids always hold a ':' ("w1:p2",
# "work/w1:p2"), herdr-core's never do ("t7", "box/t7"). Everything above
# this module treats both alike: it asks `at` for the socket, `bare` for
# the id that socket knows it by, and calls the functions below with them.
# herdr-core's own core answers for its machines' terminals too, so a core
# id goes to the local core's socket whole.

def core.of(parts: List<&2, String>) -> Bool:
  match parts:
    case Nil{}:
      True{}
    case Con{+p, t}:
      Hc.nb(String.contains(p, ":")) && core.of(t)

# A herdr-core terminal (not a herdr pane).
def core(+pane: String) -> Bool:
  Hc.nb(String.is_empty(pane)) && core.of(String.split(pane, '/'))

def at.pick(c: Bool, +herdr: String, +hc: String, +dir: String, +pane: String) -> String:
  match c:
    case True{}:
      hc
    case False{}:
      Herdr.at(herdr, dir, pane)

# The socket a pane lives behind: the core's, this Mac's herdr's, or another
# Mac's herdr's (forwarded into `dir`).
def at(+herdr: String, +hc: String, +dir: String, +pane: String) -> String:
  at.pick(core(pane), herdr, hc, dir, pane)

def bare.pick(c: Bool, +pane: String) -> String:
  match c:
    case True{}:
      pane
    case False{}:
      Herdr.bare(pane)

# The id the pane's socket knows it by.
def bare(+pane: String) -> String:
  bare.pick(core(pane), pane)

def pane_on.pick(c: Bool, +m: String, +pane: String) -> String:
  match c:
    case True{}:
      pane
    case False{}:
      Herdr.pane_on(m, pane)

# A pane started on machine m, as reflexd knows it. The core already names
# its machines' terminals "box/t7".
def pane_on(+m: String, +pane: String) -> String:
  pane_on.pick(core(pane), m, pane)

# Calls
# -----

def read_pane.pick(c: Bool, sock: String, pane: String, source: String, lines: U32) -> IO(Result<&1, &1, U32 & String, String>):
  match c:
    case True{}:
      Hc.read_pane(sock, pane, source, lines)
    case False{}:
      Herdr.read_pane(sock, pane, source, lines)

def read_pane(sock: String, +pane: String, source: String, lines: U32) -> IO(Result<&1, &1, U32 & String, String>):
  read_pane.pick(core(pane), sock, pane, source, lines)

def read_pane_ansi.pick(c: Bool, sock: String, pane: String, source: String, lines: U32) -> IO(Result<&1, &1, U32 & String, String>):
  match c:
    case True{}:
      Hc.read_pane(sock, pane, source, lines)
    case False{}:
      Herdr.read_pane_ansi(sock, pane, source, lines)

# With its colors where the backend has them (herdr's reads do; the core's
# are text: its colors come through a stream, see the app's CoreLink).
def read_pane_ansi(sock: String, +pane: String, source: String, lines: U32) -> IO(Result<&1, &1, U32 & String, String>):
  read_pane_ansi.pick(core(pane), sock, pane, source, lines)

def prompt.pick(c: Bool, sock: String, pane: String, text: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  match c:
    case True{}:
      Hc.prompt(sock, pane, text)
    case False{}:
      Herdr.prompt(sock, pane, text)

def prompt(sock: String, +pane: String, text: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  prompt.pick(core(pane), sock, pane, text)

def press.pick(c: Bool, sock: String, pane: String, key: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  match c:
    case True{}:
      Hc.press(sock, pane, key)
    case False{}:
      Herdr.press(sock, pane, key)

def press(sock: String, +pane: String, key: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  press.pick(core(pane), sock, pane, key)

def pane_status.pick(c: Bool, sock: String, pane: String) -> IO(String):
  match c:
    case True{}:
      Hc.pane_status(sock, pane)
    case False{}:
      Herdr.pane_status(sock, pane)

def pane_status(sock: String, +pane: String) -> IO(String):
  pane_status.pick(core(pane), sock, pane)

def close_pane.pick(c: Bool, sock: String, pane: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  match c:
    case True{}:
      Hc.close_pane(sock, pane)
    case False{}:
      Herdr.close_pane(sock, pane)

def close_pane(sock: String, +pane: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  close_pane.pick(core(pane), sock, pane)

def focus.pick(c: Bool, sock: String, pane: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  match c:
    case True{}:
      # The core draws nothing: there is no window of its to bring forward.
      # The app opens its own terminal on the agent instead.
      IO.pure(Result<&1, &1, U32 & String, J.JSON>, Done{J.Null{}})
    case False{}:
      Herdr.focus(sock, pane)

def focus(sock: String, +pane: String) -> IO(Result<&1, &1, U32 & String, J.JSON>):
  focus.pick(core(pane), sock, pane)
