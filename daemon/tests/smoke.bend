# Smoke test: Host.unix_call against the default herdr socket (agent.list).
import Base
import ../Host.bend as H
import ../vendor/strict-json/json.bend as J

def main() -> IO(Unit):
  do IO<Unit>:
    home : String <- IO.try(String, IO.get_env("HOME"))
    r : Result<&1, &1, U32 & String, String> <- H.Host.unix_call(home ++ "/.config/herdr/herdr.sock", "{\"id\":\"1\",\"method\":\"agent.list\",\"params\":{}}\n", 1048576, 3000)
    line : String <- IO.pass(String, r)
    IO.print(line)
