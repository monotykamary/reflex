import Base

# Whole-file helpers over Base's File effects.

def Res() -> Type:
  Result<&1, &1, U32 & String, String>

def read_close(m: File & Result<&1, &1, U32 & String, String>) -> IO(Result<&1, &1, U32 & String, String>):
  (f, r) = m
  do IO<Result<&1, &1, U32 & String, String>>:
    File.close(f)
    return r

def read_opened(r: Result<&1, &1, U32 & String, File>, max: U32) -> IO(Result<&1, &1, U32 & String, String>):
  match r:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, String>, Fail{e})
    case Done{f}:
      do IO<Result<&1, &1, U32 & String, String>>:
        m : File & Result<&1, &1, U32 & String, String> <- File.read(f, max)
        read_close(m)

# The whole file, up to `max` bytes.
def read(path: String, max: U32) -> IO(Result<&1, &1, U32 & String, String>):
  do IO<Result<&1, &1, U32 & String, String>>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    read_opened(r, max)

def write_close(m: File & Result<&1, &1, U32 & String, Unit>) -> IO(Result<&1, &1, U32 & String, Unit>):
  (f, r) = m
  do IO<Result<&1, &1, U32 & String, Unit>>:
    File.close(f)
    return r

def write_opened(r: Result<&1, &1, U32 & String, File>, data: String) -> IO(Result<&1, &1, U32 & String, Unit>):
  match r:
    case Fail{e}:
      IO.pure(Result<&1, &1, U32 & String, Unit>, Fail{e})
    case Done{f}:
      do IO<Result<&1, &1, U32 & String, Unit>>:
        m : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, data)
        write_close(m)

# Write ("w") or append ("a") text to a file.
def put(path: String, mode: String, data: String) -> IO(Result<&1, &1, U32 & String, Unit>):
  do IO<Result<&1, &1, U32 & String, Unit>>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, mode)
    write_opened(r, data)
