#!/bin/sh
# reflex-fork: answer a side question in a headless fork of an agent's session,
# leaving the agent itself untouched. The fork shares the session's prefix, so
# the provider's prompt cache stays warm; it is never saved.
#
#   reflex-fork.sh <kind> <cwd> <session> <question>
#
# <session> is the harness's session id or file when Herdr knows it (installed
# integration); empty means "the newest session for <cwd>".
# REFLEX_FORK_SAFE=1 also strips tools (pi) — safer, but the changed tool list
# misses the prompt cache.
set -eu

kind=$1
cwd=$2
session=$3
question=$4

prompt="(Side question from the user, asked through reflex while you keep working. Answer briefly from what you already know about this session. Do not edit files or run commands.)

$question"

newest() {
  ls -t "$1"/*.jsonl 2>/dev/null | head -n 1
}

cd "$cwd"

case $kind in
  pi)
    if [ -z "$session" ]; then
      enc=$(printf '%s' "$cwd" | sed -e 's#^/##' -e 's#/#-#g')
      session=$(newest "$HOME/.pi/agent/sessions/--$enc--")
    fi
    [ -n "$session" ] || { echo "no pi session found for $cwd" >&2; exit 3; }
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/reflex-fork.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT
    if [ "${REFLEX_FORK_SAFE:-0}" = 1 ]; then
      pi --fork "$session" --session-dir "$tmp" --no-tools -p "$prompt"
    else
      pi --fork "$session" --session-dir "$tmp" -p "$prompt"
    fi
    ;;
  claude)
    if [ -z "$session" ]; then
      enc=$(printf '%s' "$cwd" | sed -e 's#[/.]#-#g')
      file=$(newest "$HOME/.claude/projects/$enc")
      session=$(basename "${file:-}" .jsonl)
    fi
    [ -n "$session" ] || { echo "no claude session found for $cwd" >&2; exit 3; }
    claude -p --resume "$session" --fork-session --no-session-persistence \
      --permission-mode plan "$prompt"
    ;;
  *)
    echo "reflex-fork: no fork support for $kind" >&2
    exit 2
    ;;
esac
