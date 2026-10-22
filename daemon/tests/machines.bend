# Agents on other machines: which herdr socket a pane id goes to, the id that
# herdr knows it by, and a machine's agents kept while its tunnel is down.
# Places on them: a folder or session "work:/Users/you/VCS/app", its machine,
# its path there, how Jev reads it, and the folders a request scoped to one
# machine may start in.
import Base
import ../Model.bend as M
import ../Herdr.bend as Herdr
import ../Index.bend as Ix
import ../Route.bend as R

def line(+pane: String) -> String:
  pane ++ "  =>  machine " ++ Herdr.machine(pane) ++ ", pane " ++ Herdr.bare(pane) ++ ", socket " ++ Herdr.at("/local/herdr.sock", "/data/machines", pane)

def agent(pane: String) -> M.Agent:
  M.Agent{pane, "a", "claude", M.Idle{}, "/w", "", 0, "", ""}

def panes(xs: List<&2, M.Agent>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{M.Agent{pane, name, kind, status, cwd, title, seq, session, screen}, t}:
      pane ++ " " ++ panes(t)

def place(+path: String) -> String:
  path ++ "  =>  machine " ++ Ix.machine_of(path) ++ ", path " ++ Ix.path_on(path) ++ ", reads " ++ R.short("/Users/me", path) ++ ", pane " ++ Herdr.pane_on(Ix.machine_of(path), "w3:p1")

def folder(path: String) -> M.Folder:
  M.Folder{path, "f", "", "", "", 0, 0}

def paths(xs: List<&2, M.Folder>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{M.Folder{path, name, desc, recent, branch, age, uses}, t}:
      path ++ " " ++ paths(t)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(line("w1:p1"))
    IO.print(line("work/w1:p1"))
    IO.print(line(""))
    IO.print("tagged: " ++ panes(Herdr.tags("work", [agent("w1:p1"), agent("w2:p3")])))
    IO.print("kept on work: " ++ panes(Herdr.on("work", [agent("w1:p1"), agent("work/w1:p1"), agent("box/w1:p1"), agent("work/w2:p3")])))
    IO.print(place("/Users/me/VCS/app"))
    IO.print(place("work:/Users/you/VCS/app"))
    IO.print(place("work:/opt/work"))
    IO.print(place(""))
    IO.print("agent pane work/w1:p2 on: " ++ Ix.pane_machine("work/w1:p2") ++ ", w1:p2 on: [" ++ Ix.pane_machine("w1:p2") ++ "]")
    IO.print("here: " ++ paths(Ix.on("", [folder("/Users/me/a"), folder("work:/Users/you/b"), folder("box:/c")])))
    IO.print("on work: " ++ paths(Ix.on("work", [folder("/Users/me/a"), folder("work:/Users/you/b"), folder("box:/c"), folder("work:/d")])))
