# Run through scripts/test-agent-status.py: its socket stub verifies that
# status polling uses agent.get {target}, which advances pending launches,
# and returns actual agent_info payloads rather than pane_info payloads.
import Base
import ../Herdr.bend as Herdr

def checked(ok: Bool, name: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "wrong agent status for " ++ name)

def check(sock: String, +target: String, want: String) -> IO(Unit):
  do IO<Unit>:
    got : String <- Herdr.pane_status(sock, target)
    checked(String.eq(got, want), target)

def main() -> IO(Unit):
  do IO<Unit>:
    +sock : String <- IO.try(String, IO.get_env("REFLEX_TEST_SOCKET"))
    check(sock, "w1:p1", "idle")
    check(sock, "w1:p2", "working")
    check(sock, "w1:p3", "blocked")
    check(sock, "named-agent", "done")
    check(sock, "w1:p5", "unknown")
    check(sock, "missing-agent", "")
    check(sock, "missing-status", "")
    check(sock, "old-pane-payload", "")
    check(sock, "failed-read", "")
    IO.print("agent status checks passed")
