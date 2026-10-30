import Base
import ../Past.bend as P

def ids(xs: List<&2, P.Past>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{P.Past{agent, id, cwd, title, last, age, state}, t}:
      id ++ " " ++ ids(t)

def main() -> IO(Unit):
  do IO<Unit>:
    +xs : List<&2, P.Past> = [P.Past{"claude", "a", "/a", "", "", 0, "past"}, P.Past{"pi", "b", "/b", "", "", 0, "past"}, P.Past{"claude", "c", "work:/c", "", "", 0, "past"}]
    IO.print("all: " ++ ids(P.harness("", xs)))
    IO.print("claude: " ++ ids(P.harness("claude", xs)))
    IO.print("local claude: " ++ ids(P.harness("claude", P.on("", xs))))
    IO.print("codex: " ++ ids(P.harness("codex", xs)))
