#!/bin/sh
# reflex-remote: the agent sessions saved on another Mac, for Reflex's resume
# list there. The app sends this script over ssh (nothing is installed on
# that Mac) and reads the sessions with the same code it reads its own with.
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
known=$(mktemp -t reflex-known)
trap 'rm -f "$known"' EXIT
sed -n '/^__KNOWN__$/,$p' "$self" | sed 1d > "$known"

list() {
  [ -d "$1" ] || return 0
  find "$1" -maxdepth "$2" -type f -name '*.jsonl' -exec stat -f "$3$tab%m$tab%N" {} + 2>/dev/null \
    | sort -t "$tab" -k2,2nr | head -n 40
}

{
  list "$HOME/.claude/projects" 2 claude
  list "$HOME/.pi/agent/sessions" 2 pi
  list "$HOME/.codex/sessions" 4 codex
} | while IFS="$tab" read -r agent m p; do
  if grep -qxF "$m$tab$p" "$known"; then
    printf 'F\t%s\t%s\t%s\t\t\n' "$agent" "$m" "$p"
    continue
  fi
  size=$(stat -f %z "$p" 2>/dev/null || echo 0)
  h=$(head -c 65536 "$p" | base64 | tr -d '\n')
  t=""
  [ "$size" -gt 65536 ] && t=$(tail -c 131072 "$p" | base64 | tr -d '\n')
  printf 'F\t%s\t%s\t%s\t%s\t%s\n' "$agent" "$m" "$p" "$h" "$t"
done

PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if command -v claude >/dev/null 2>&1; then
  printf 'A\t%s\n' "$(claude agents --json --all 2>/dev/null | tr -d '\n')"
fi
exit 0
__KNOWN__
