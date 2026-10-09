import Base

# The OS boundary of reflexd: two effects implemented in host.c. Everything
# else in the daemon is Base IO or pure code.

# One newline-delimited request/response over a Unix stream socket.
def Host.unix_call(path: String, line: String, max: U32, timeout_ms: U32) -> IO(Result<&1, &1, U32 & String, String>):
  import "./host.c"

# One HTTP/1.1 request (head plus Content-Length body) from an accepted socket.
def Host.http_read(sock: Socket, max: U32, timeout_ms: U32) -> IO(Socket & Result<&1, &1, U32 & String, String>):
  import "./host.c"

# The parent process id (to exit when the app that started reflexd is gone).
def Host.ppid() -> IO(U32):
  import "./host.c"
