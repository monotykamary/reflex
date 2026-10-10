# Which answers Reflex reads off a blocked agent's screen (Core.options), on
# screens captured from Claude Code: an arrow menu, a multi-select, the
# review step, and an idle prompt that must offer nothing.
import Base
import ../Model.bend as M
import ../Core.bend as Core

def show(xs: List<&2, M.Opt>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{M.Opt{key, label, action}, t}:
      "  " ++ key ++ " " ++ label ++ "  =>  " ++ M.Action.json(action) ++ "\n" ++ show(t)

def trust() -> String:
  " Quick safety check: Is this a project you created or one you trust?\n\n Claude Code'll be able to read, edit, and execute files here.\n\n Security guide\n\n ❯ No, exit\n   Yes, I trust this folder\n\n Enter to confirm · Esc to cancel"

def multi() -> String:
  "←  ☒ Season  ☐ Fruits  ✔ Submit  →\n\nWhich fruits do you like?\n\n❯ 1. [✔] Apple\n         Crisp and sweet.\n  2. [ ] Banana\n         Soft.\n  3. [ ] Cherry\n  4. [ ] Type something\n     Submit\n──────\n  5. Chat about this\n\nEnter to select · Tab/Arrow keys to navigate · Esc to cancel"

def review() -> String:
  "Review your answers\n\n ● What is your favorite season?\n   → Autumn\n\nReady to submit your answers?\n\n❯ 1. Submit answers\n  2. Cancel"

def idle() -> String:
  "⏺ Red\n\n✻ Brewed for 7s\n\n──────────────\n❯ \n──────────────\n  ⏵⏵ bypass permissions on (shift+tab to cycle)"

def below() -> String:
  "Pick one\n\n   Alpha\n   Beta\n ❯ Gamma\n   Delta\n"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("trust:\n" ++ show(Core.options(trust(), "p")))
    IO.print("multi:\n" ++ show(Core.options(multi(), "p")))
    IO.print("review:\n" ++ show(Core.options(review(), "p")))
    IO.print("idle:\n" ++ show(Core.options(idle(), "p")))
    IO.print("below:\n" ++ show(Core.options(below(), "p")))
