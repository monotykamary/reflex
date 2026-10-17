# Whether a prompt Reflex sent sits typed but unsent in the agent's input, or
# never arrived (Core.prompt_typed, Core.prompt_missing), on screens shaped
# like Claude Code's: the request in the box (its Enter taken as a new line),
# sent and in the conversation, lost, collapsed into a paste, wrapped in the
# box; then a working agent and a screen with no box at all.
import Base
import ../Core.bend as Core

def ask() -> String:
  "fix the flaky test in coralbricks please"

def rule() -> String:
  "──────────────────────────────────────"

def foot() -> String:
  "  ⏵⏵ bypass permissions on (shift+tab to cycle)"

def typed() -> String:
  "⏺ Done earlier.\n\n" ++ rule() ++ "\n❯ fix the flaky test in coralbricks please\n  \n" ++ rule() ++ "\n" ++ foot()

def sent() -> String:
  "❯ fix the flaky test in coralbricks please\n\n⏺ Looking at the tests…\n\n" ++ rule() ++ "\n❯ \n" ++ rule() ++ "\n" ++ foot()

def lost() -> String:
  "⏺ Done earlier.\n\n" ++ rule() ++ "\n❯ \n" ++ rule() ++ "\n" ++ foot()

def pasted() -> String:
  "⏺ Done earlier.\n\n" ++ rule() ++ "\n❯ [Pasted text #1 +12 lines]\n" ++ rule() ++ "\n" ++ foot()

def wrapped() -> String:
  "⏺ Done earlier.\n\n" ++ rule() ++ "\n❯ fix the fla\n  ky test in coralbricks please\n" ++ rule() ++ "\n" ++ foot()

def shell() -> String:
  "$ fix the flaky test in coralbricks please\nzsh: command not found: fix"

def yes(b: Bool) -> String:
  match b:
    case True{}:
      "yes"
    case False{}:
      "no"

def line(+name: String, +status: String, +screen: String) -> String:
  name ++ ": typed " ++ yes(Core.prompt_typed(status, screen, Core.probe(ask()))) ++ ", missing " ++ yes(Core.prompt_missing(status, screen, Core.probe(ask())))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(line("typed", "idle", typed()))
    IO.print(line("sent", "idle", sent()))
    IO.print(line("lost", "idle", lost()))
    IO.print(line("lost, done", "done", lost()))
    IO.print(line("pasted", "idle", pasted()))
    IO.print(line("wrapped", "idle", wrapped()))
    IO.print(line("working", "working", typed()))
    IO.print(line("no box", "idle", shell()))
