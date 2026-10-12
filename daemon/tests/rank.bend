import Base
import ../Fs.bend as Fs
import ../Index.bend as Ix
import ../Model.bend as M

def show(fs: List<&2, M.Folder>) -> String:
  match fs:
    case Nil{}:
      ""
    case Con{M.Folder{path, name, desc, recent, branch, age, uses}, t}:
      name ++ " (" ++ U32.show(age) ++ "h)\n" ++ show(t)

# usage: scripts/reflex-scan.sh > scan.tsv && build/rank scan.tsv
def path_of(args: List<String>) -> String:
  match args:
    case Con{prog, Con{p, rest}}:
      p
    case other:
      "scan.tsv"

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    tsv : String <- IO.try(String, Fs.read(path_of(args), 16777216))
    +fs : List<&2, M.Folder> = Ix.parse(tsv)
    IO.print("folders: " ++ Nat.show(List.length(&2, M.Folder, fs)))
    IO.print("--- fix the flaky follow test in jev fabric")
    IO.print(show(Ix.rank("fix the flaky follow test in jev fabric", fs, 8n)))
    IO.print("--- add a quicklook keybinding to herdr")
    IO.print(show(Ix.rank("add a quicklook keybinding to herdr", fs, 8n)))
    IO.print("--- fix the issues listed for pi-fabric after #237, then bun publish")
    IO.print(show(Ix.rank("fix the issues listed for pi-fabric after #237, then bun publish", fs, 8n)))
    IO.print("--- localterm browser theme bug")
    IO.print(show(Ix.rank("localterm browser theme bug", fs, 5n)))
