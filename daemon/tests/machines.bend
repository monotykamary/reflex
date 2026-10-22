# Agents on other machines: which herdr socket a pane id goes to, the id that
# herdr knows it by, and a machine's agents kept while its tunnel is down.
import Base
import ../Model.bend as M
import ../Herdr.bend as Herdr

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

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(line("w1:p1"))
    IO.print(line("anh/w1:p1"))
    IO.print(line(""))
    IO.print("tagged: " ++ panes(Herdr.tags("anh", [agent("w1:p1"), agent("w2:p3")])))
    IO.print("kept on anh: " ++ panes(Herdr.on("anh", [agent("w1:p1"), agent("anh/w1:p1"), agent("box/w1:p1"), agent("anh/w2:p3")])))
