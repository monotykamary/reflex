#!/bin/sh
# Regression tests for agy session discovery (local SessionArchive.swift and
# remote scripts/reflex-remote.sh): cleared workspace_uris recovery via
# history.jsonl, conversations/<id>.db executor_metadata, real-home fallback,
# WAL visibility, whole-second timestamps, and empty stub filtering.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT

HOME_DIR="$d/home"
AGY_PROF="$HOME_DIR/.reflex/profiles/agy/work/home/.gemini/antigravity-cli"
mkdir -p \
  "$HOME_DIR/proj-direct" \
  "$HOME_DIR/proj-hist" \
  "$HOME_DIR/proj-meta" \
  "$HOME_DIR/proj-wal" \
  "$AGY_PROF/conversations" \
  "$HOME_DIR/.local/share/amp/threads"
ln -s "$HOME_DIR/.local" "$HOME_DIR/.reflex/profiles/agy/work/home/.local"

# Seed an amp thread in real home to ensure agy profile home doesn't duplicate it.
cat > "$HOME_DIR/.local/share/amp/threads/T-1.json" <<EOF
{"id":"T-1","title":"Amp thread","env":{"initial":{"trees":[{"uri":"file://$HOME_DIR/proj-direct"}]}},"messages":[]}
EOF

# Seed history.jsonl with a workspace for s-hist.
printf '{"display":"hi","timestamp":1,"workspace":"%s","conversationId":"s-hist"}\n' "$HOME_DIR/proj-hist" > "$AGY_PROF/history.jsonl"

# Build Swift test runner against the real SessionArchive.agy implementation.
cat > "$d/stub.swift" <<'SWIFT'
import Foundation
struct AgentInfo { var session: String = "" }
struct AppState { var agents: [AgentInfo] = [] }
@MainActor final class Store { static let shared = Store(); var state = AppState() }
@MainActor final class Daemon { static let shared = Daemon(); func childEnvironment() -> [String: String] { [:] } }
enum Blocking { static func run<T: Sendable>(_ f: @escaping @Sendable () -> T) async -> T { f() } }
enum Client { static let local = Local(); struct Local { func reindex() async {} } }
enum Settings { static var supportDir: URL { URL(fileURLWithPath: NSTemporaryDirectory()) } }
enum Profiles {
    static func spec(_ kind: String, _ profile: String?) -> String { (profile ?? "").isEmpty ? kind : "\(kind)[\(profile!)]" }
    static func matches(_ wanted: String, kind: String, profile: String?) -> Bool { true }
}
enum Place {
    static func machine(_ p: String) -> String { p.isEmpty || p.hasPrefix("/") ? "" : String(p.prefix { $0 != ":" }) }
    static func path(_ p: String) -> String { let m = machine(p); return m.isEmpty ? p : String(p.dropFirst(m.count + 1)) }
}
SWIFT

cat > "$d/main.swift" <<'SWIFT'
import Foundation
let args = CommandLine.arguments
let db = args[1]
let home = args[2]
let sessions = SessionArchive.agy(db, fallbackCwd: home)
let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
let wantIds: Set<String> = ["s-direct", "s-hist", "s-meta", "s-home", "s-wal"]
precondition(Set(byId.keys) == wantIds, "unexpected swift agy ids: \(Array(byId.keys))")
precondition(byId["s-direct"]?.cwd == "\(home)/proj-direct", "s-direct cwd: \(byId["s-direct"]?.cwd ?? "")")
precondition(byId["s-hist"]?.cwd == "\(home)/proj-hist", "s-hist cwd: \(byId["s-hist"]?.cwd ?? "")")
precondition(byId["s-meta"]?.cwd == "\(home)/proj-meta", "s-meta cwd: \(byId["s-meta"]?.cwd ?? "")")
precondition(byId["s-home"]?.cwd == home, "s-home cwd: \(byId["s-home"]?.cwd ?? "")")
precondition(byId["s-wal"]?.cwd == "\(home)/proj-wal", "s-wal cwd: \(byId["s-wal"]?.cwd ?? "")")
precondition(byId["s-hist"]!.modified > Date(timeIntervalSince1970: 1_700_000_000), "whole-second ISO timestamp failed to parse")
for (id, s) in byId {
    precondition(s.profile == "work", "profile mismatch for \(id): \(s.profile ?? "nil")")
}
// Verify profileHomes scoping: amp has no profiles, agy has one.
let profRoot = "\(home)/.reflex/profiles"
precondition(SessionArchive.profileHomes(profRoot, for: "agy").count == 1)
precondition(SessionArchive.profileHomes(profRoot, for: "amp").isEmpty)
print("SessionArchive.swift agy scan: ok")
SWIFT

# Compile SessionArchive.swift + stubs (drop @MainActor ObservableObject SwiftUI/AppKit bits not needed? No, AppKit/Foundation are available on macOS!).
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$d/clang-cache}" \
  swiftc -parse-as-library -o "$d/agy-test" "$d/stub.swift" "$root/app/Sources/Reflex/SessionArchive.swift" "$d/main.swift" 2>/dev/null || \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$d/clang-cache}" \
  swiftc -o "$d/agy-test" "$d/stub.swift" "$root/app/Sources/Reflex/SessionArchive.swift" "$d/main.swift"

# Build SQLite fixtures (conversation_summaries.db in WAL mode + conversations/s-meta.db)
# and run both Swift SessionArchive.agy and scripts/reflex-remote.sh (with and without sqlite3)
# while the WAL remains uncheckpointed.
python3 - "$AGY_PROF" "$HOME_DIR" "$d" <<'PY'
import json, os, shutil, sqlite3, subprocess, sys

agy_dir, home, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
db = os.path.join(agy_dir, "conversation_summaries.db")
con = sqlite3.connect(db)
con.execute("pragma journal_mode=wal")
con.execute("""
CREATE TABLE conversation_summaries (
  conversation_id text primary key,
  title text not null default "",
  preview text not null default "",
  step_count integer not null default 0,
  last_modified_time datetime not null,
  workspace_uris text not null,
  parent_conversation_id text not null default "",
  killed numeric not null default false
)
""")
rows = [
    ("s-direct", "Direct workspace", "Direct preview", 5, "2026-11-28 20:00:00.123456+00:00", json.dumps([f"file://{home}/proj-direct"]), "", 0),
    ("s-hist", "Cleared recovered from history", "Hist preview", 20, "2026-11-28 19:00:00+00:00", "", "", 0),
    ("s-meta", "Cleared recovered from meta", "Meta preview", 40, "2026-11-28 18:00:00.5+00:00", "", "", 0),
    ("s-home", "Cleared fallback to home", "Home preview", 15, "2026-11-28 17:00:00.5+00:00", "", "", 0),
    ("s-stub", "", "", 0, "0001-01-01 00:00:00+00:00", json.dumps([f"file://{home}"]), "", 0),
    ("s-sub", "Subagent", "Sub", 5, "2026-11-28 16:00:00.5+00:00", json.dumps([f"file://{home}/proj-direct"]), "s-direct", 0),
    ("s-killed", "Killed", "Killed", 5, "2026-11-28 15:00:00.5+00:00", json.dumps([f"file://{home}/proj-direct"]), "", 1),
]
con.executemany("insert into conversation_summaries values (?,?,?,?,?,?,?,?)", rows)
con.commit()
con.execute("pragma wal_checkpoint(truncate)")

# Keep an uncheckpointed row in -wal to verify WAL visibility.
con.execute(
    "insert into conversation_summaries values (?,?,?,?,?,?,?,?)",
    ("s-wal", "In WAL", "WAL preview", 3, "2026-11-28 21:00:00.1+00:00", json.dumps([f"file://{home}/proj-wal"]), "", 0),
)
con.commit()

# Build conversations/s-meta.db with protobuf-framed file:/// URI in executor_metadata
# followed immediately by 0x6a ('j') to guard against greedy regex over-matching.
meta_db = os.path.join(agy_dir, "conversations", "s-meta.db")
mcon = sqlite3.connect(meta_db)
mcon.execute("create table executor_metadata (idx integer primary key, data blob)")
uri = f"file://{home}/proj-meta".encode("utf-8")
def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)
blob = b"\x0a\x04test\x12" + varint(len(uri)) + uri + b"j\x04next"
mcon.execute("insert into executor_metadata values (0, ?)", (b"no uri here",))
mcon.execute("insert into executor_metadata values (1, ?)", (blob,))
mcon.commit()
mcon.close()

def check_remote(label, env):
    out = subprocess.check_output(
        ["/bin/sh", "scripts/reflex-remote.sh", "scripts/reflex-remote.sh"],
        env=env,
        text=True,
    )
    got = {}
    amp_count = 0
    for line in out.splitlines():
        f = line.split("\t")
        if f[0] == "S" and f[1] == "agy":
            got[f[2]] = (f[4], f[5], f[7])
        elif f[0] == "S" and f[1] == "amp":
            amp_count += 1
    assert amp_count == 1, f"{label}: expected 1 amp row, got {amp_count}"
    assert set(got.keys()) == {"s-direct", "s-hist", "s-meta", "s-home", "s-wal"}, f"{label}: unexpected agy ids: {got}"
    assert got["s-direct"][0] == f"file://{home}/proj-direct", got["s-direct"]
    assert got["s-hist"][0] == f"{home}/proj-hist", got["s-hist"]
    assert got["s-meta"][0] == f"{home}/proj-meta", got["s-meta"]
    assert got["s-home"][0] == home, got["s-home"]
    assert got["s-wal"][0] == f"file://{home}/proj-wal", got["s-wal"]
    for k, v in got.items():
        assert v[2] == "work", f"{label}: expected profile work for {k}, got {v}"
    print(f"reflex-remote.sh ({label}): ok")

# 1. Swift SessionArchive.agy while WAL is live.
print(subprocess.check_output([os.path.join(tmp, "agy-test"), db, home], text=True).strip())

# 2. Remote script with sqlite3 CLI.
check_remote("sqlite3", {**os.environ, "HOME": home})

# 3. Remote script without sqlite3 CLI (python3 fallback, as on minimal Linux boxes).
nosq = os.path.join(tmp, "bin")
os.makedirs(nosq, exist_ok=True)
for tool in ("sh", "sed", "mktemp", "rm", "stat", "find", "sort", "head", "grep", "base64", "tr", "ls", "python3", "printf"):
    p = shutil.which(tool)
    if p:
        os.symlink(p, os.path.join(nosq, tool))
check_remote("python3-only", {"HOME": home, "PATH": nosq, "TMPDIR": tmp})

con.close()
PY
