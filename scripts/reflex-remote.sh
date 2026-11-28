#!/bin/sh
# reflex-remote: the agent sessions saved on another machine (a Mac, or a
# Linux sandbox), for Reflex's resume list there. The app sends this script
# over ssh (nothing is installed there) and reads the sessions with the same
# code it reads its own with. POSIX sh, BSD or GNU tools.
#
#   sh reflex-remote.sh <this file>
#
# Every line after __KNOWN__ at the end of this file is a session file the app
# has already read ("mtime<TAB>path"). Output, one line per session file, the
# most recent 40 of each agent's:
#
#   F  agent  mtime  path  head  tail
#
# head and tail (base64 of its first 64 KB and, past that, its last 128 KB)
# only for a file the app hasn't read at that mtime; empty otherwise. Then,
# when Claude Code is installed there, one line "A<TAB>json" with its own
# list of sessions (`claude agents --json --all`): which are open elsewhere.
# Reads only; never writes outside its own temporary file.
set -u
self=${1:-$0}
tab=$(printf '\t')
# (GNU mktemp wants the X's; BSD's -t adds its own.)
known=$(mktemp "${TMPDIR:-/tmp}/reflex-known.XXXXXX")
trap 'rm -f "$known"' EXIT
sed -n '/^__KNOWN__$/,$p' "$self" | sed 1d > "$known"

# GNU stat (Linux) or BSD stat (macOS).
if stat -c %Y / >/dev/null 2>&1; then gnu=1; else gnu=""; fi

list() {
  [ -d "$1" ] || return 0
  if [ -n "$gnu" ]; then
    find "$1" -maxdepth "$2" -type f -name '*.jsonl' -exec stat -c "$3$tab%Y$tab%n" {} + 2>/dev/null
  else
    find "$1" -maxdepth "$2" -type f -name '*.jsonl' -exec stat -f "$3$tab%m$tab%N" {} + 2>/dev/null
  fi | sort -t "$tab" -k2,2nr | head -n 40
}

{
  list "$HOME/.claude/projects" 2 claude
  list "$HOME/.pi/agent/sessions" 2 pi
  list "$HOME/.codex/sessions" 4 codex
  # Profiles' (reflex profile): which one is read off the path.
  # (An adopting profile's folder links to your own: listed there already.)
  for d in "$HOME"/.reflex/profiles/claude/*/claude/projects; do [ -L "$d" ] || list "$d" 2 claude; done
  for d in "$HOME"/.reflex/profiles/pi/*/pi/sessions; do [ -L "$d" ] || list "$d" 2 pi; done
  for d in "$HOME"/.reflex/profiles/codex/*/codex/sessions; do [ -L "$d" ] || list "$d" 4 codex; done
} | while IFS="$tab" read -r agent m p; do
  if grep -qxF "$m$tab$p" "$known"; then
    printf 'F\t%s\t%s\t%s\t\t\n' "$agent" "$m" "$p"
    continue
  fi
  if [ -n "$gnu" ]; then size=$(stat -c %s "$p" 2>/dev/null || echo 0); else size=$(stat -f %z "$p" 2>/dev/null || echo 0); fi
  h=$(head -c 65536 "$p" | base64 | tr -d '\n')
  t=""
  [ "$size" -gt 65536 ] && t=$(tail -c 131072 "$p" | base64 | tr -d '\n')
  printf 'F\t%s\t%s\t%s\t%s\t%s\n' "$agent" "$m" "$p" "$h" "$t"
done

# agy's, opencode's and amp's, read with sqlite3 (or python3's sqlite3 on boxes
# without the CLI), one line each: S agent id mtime cwd-or-uri title last profile.
sq() {
  [ -f "$1" ] || return 0
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 -readonly -cmd '.timeout 500' -separator "$tab" "$1" "$2" 2>/dev/null ||
      sqlite3 -readonly -separator "$tab" "file:$1?immutable=1" "$2" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sqlite3, sys
db, sql = sys.argv[1], sys.argv[2]
for uri in (f"file:{db}?mode=ro", f"file:{db}?immutable=1"):
    try:
        con = sqlite3.connect(uri, uri=True, timeout=0.5)
        try:
            for row in con.execute(sql):
                sys.stdout.write("\t".join("" if v is None else str(v) for v in row) + "\n")
            break
        finally:
            con.close()
    except Exception:
        pass
' "$1" "$2" 2>/dev/null
  fi
}
flat() { printf "replace(replace(replace(%s, char(9), ' '), char(10), ' '), char(13), ' ')" "$1"; }
profile_of() {
  case $1 in */.reflex/profiles/*) pr=${1%/home}; pr=${pr##*/} ;; *) pr= ;; esac
  case $pr in *[!a-z0-9._-]*) return 1 ;; esac
}
agy_fill_cwd() {
  dir=$1
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, os, sqlite3, sys
from urllib.parse import unquote, urlparse

agy_dir, fallback = sys.argv[1], sys.argv[2]
hist = None

def from_history(cid):
    global hist
    if hist is None:
        hist = {}
        p = os.path.join(agy_dir, "history.jsonl")
        if os.path.isfile(p):
            try:
                with open(p, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        try:
                            j = json.loads(line)
                        except Exception:
                            continue
                        k, ws = j.get("conversationId"), j.get("workspace")
                        if isinstance(k, str) and k and isinstance(ws, str) and ws.startswith("/"):
                            hist[k] = ws
            except Exception:
                pass
    return hist.get(cid, "")

def from_conv_db(cid):
    p = os.path.join(agy_dir, "conversations", cid + ".db")
    if not os.path.isfile(p):
        return ""
    rows = []
    for uri in (f"file:{p}?mode=ro", f"file:{p}?immutable=1"):
        try:
            con = sqlite3.connect(uri, uri=True, timeout=0.5)
            try:
                rows = con.execute("select data from executor_metadata where instr(data, X\x2766696c653a2f2f2f\x27) > 0 order by idx asc limit 3").fetchall()
                break
            finally:
                con.close()
        except Exception:
            pass
    needle = b"file:///"
    for (data,) in rows:
        if not data:
            continue
        pos = 0
        while True:
            i = data.find(needle, pos)
            if i < 0:
                break
            pos = i + len(needle)
            lens = []
            if i >= 2 and data[i - 2] >= 0x80 and data[i - 1] < 0x80:
                lens.append((data[i - 2] & 0x7F) | (data[i - 1] << 7))
            if i >= 1 and data[i - 1] < 0x80:
                lens.append(data[i - 1])
            for ln in lens:
                if ln <= len(needle) or i + ln > len(data):
                    continue
                try:
                    uri = data[i : i + ln].decode("utf-8")
                except Exception:
                    continue
                path = unquote(urlparse(uri).path)
                if path.startswith("/") and not any(x in path for x in ("/.gemini/", "/.agents/", "/.reflex/")) and os.path.isdir(path):
                    return path
    return ""

for raw in sys.stdin:
    line = raw.rstrip("\r\n")
    if not line:
        continue
    f = line.split("\t")
    if len(f) >= 8 and not f[4]:
        f[4] = from_history(f[2]) or from_conv_db(f[2]) or fallback
    sys.stdout.write("\t".join(f) + "\n")
' "$dir" "$HOME" 2>/dev/null
  else
    while IFS="$tab" read -r f1 f2 f3 f4 f5 f6 f7 f8; do
      [ -n "$f5" ] || f5="$HOME"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f1" "$f2" "$f3" "$f4" "$f5" "$f6" "$f7" "$f8"
    done
  fi
}
if command -v sqlite3 >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  for h in "$HOME" "$HOME"/.reflex/profiles/agy/*/home; do
    [ -d "$h" ] || continue
    profile_of "$h" || continue
    db="$h/.gemini/antigravity-cli/conversation_summaries.db"
    [ -f "$db" ] || continue
    sq "$db" "select 'S', 'agy', conversation_id, cast(strftime('%s', substr(last_modified_time, 1, 19)) as integer), case when json_valid(workspace_uris) then coalesce(json_extract(workspace_uris, '\$[0]'), '') else '' end, $(flat "coalesce(nullif(title, ''), preview)"), $(flat preview), '$pr' from conversation_summaries where parent_conversation_id = '' and killed = 0 and (title != '' or preview != '') and last_modified_time > '0001-01-02' order by last_modified_time desc limit 40" | agy_fill_cwd "$h/.gemini/antigravity-cli"
  done
  for h in "$HOME" "$HOME"/.reflex/profiles/opencode/*/home; do
    [ -d "$h" ] || continue
    profile_of "$h" || continue
    sq "$h/.local/share/opencode/opencode.db" "select 'S', 'opencode', id, time_updated / 1000, directory, $(flat title), '', '$pr' from session where parent_id is null and time_archived is null and directory != '/' and title not like 'New session - %' order by time_updated desc limit 40"
  done
  for h in "$HOME" "$HOME"/.reflex/profiles/amp/*/home; do
    [ -d "$h" ] || continue
    profile_of "$h" || continue
    [ -d "$h/.local/share/amp/threads" ] || continue
    ls -t "$h/.local/share/amp/threads" 2>/dev/null | grep '\.json$' | head -n 40 | while IFS= read -r f; do
      f="$h/.local/share/amp/threads/$f"
      case $f in *"'"*) continue ;; esac
      if [ -n "$gnu" ]; then m=$(stat -c %Y "$f"); else m=$(stat -f %m "$f"); fi
      if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 -separator "$tab" :memory: "select 'S', 'amp', json_extract(j, '\$.id'), $m, json_extract(j, '\$.env.initial.trees[0].uri'), $(flat "coalesce(json_extract(j, '\$.title'), '')"), '', '$pr' from (select cast(readfile('$f') as text) as j)" 2>/dev/null
      elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
f, m, pr = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    j = json.load(open(f, encoding="utf-8"))
    cid = j.get("id") or ""
    trees = ((j.get("env") or {}).get("initial") or {}).get("trees") or []
    uri = (trees[0].get("uri") if trees and isinstance(trees[0], dict) else "") or ""
    title = (j.get("title") or "").replace("\t", " ").replace("\n", " ").replace("\r", " ")
    if cid and uri:
        sys.stdout.write(f"S\tamp\t{cid}\t{m}\t{uri}\t{title}\t\t{pr}\n")
except Exception:
    pass
' "$f" "$m" "$pr" 2>/dev/null
      fi
    done
  done
fi

PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if command -v claude >/dev/null 2>&1; then
  printf 'A\t%s\n' "$(claude agents --json --all 2>/dev/null | tr -d '\n')"
fi
exit 0
__KNOWN__
