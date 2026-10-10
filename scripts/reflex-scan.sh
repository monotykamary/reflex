#!/bin/sh
# reflex-scan: list the folders a new agent session could start in, with the
# facts routing needs. One line per folder, fields separated by a tab:
#
#   path  name  age_hours  branch  uses  description  recent_commits
#
# Roots come from REFLEX_ROOTS (colon-separated, default ~/VCS); git
# repositories whose .git is up to REFLEX_SCAN_DEPTH (default 6) levels below
# a root are listed — deep enough for root/host/org/group/repo layouts
# (~/VCS/work/acme/studio/app). Dependency and build folders are skipped. REFLEX_FOLDERS (colon-separated) adds folders that are not
# repositories, and REFLEX_FOLDERS_FILE names a file of more, one per line
# (folders added from the Ask bar). REFLEX_USAGE names a file of past spawn paths, one per line,
# counted into `uses`. Reads only; never fetches, never writes.
set -u

roots=${REFLEX_ROOTS:-$HOME/VCS}
depth=${REFLEX_SCAN_DEPTH:-6}
usage=${REFLEX_USAGE:-}
now=$(date +%s)

clean() {
  # one line, no tabs, at most $1 characters
  tr '\t\r\n' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c "1-$1"
}

describe() {
  d=$1
  for f in package.json Cargo.toml pyproject.toml; do
    if [ -f "$d/$f" ]; then
      v=$(grep -m1 -E '^[[:space:]]*"?description"?[[:space:]]*[:=]' "$d/$f" 2>/dev/null \
        | sed -E 's/^[^:=]*[:=][[:space:]]*//; s/^"//; s/",?[[:space:]]*$//')
      if [ -n "$v" ]; then
        printf '%s' "$v" | clean 200
        return
      fi
    fi
  done
  for f in README.md readme.md README README.rst; do
    if [ -f "$d/$f" ]; then
      # first prose line: skip headings, badges, html, blank lines
      awk 'NR<=60 && !/^[[:space:]]*($|#|!\[|<|\[!\[|---|===|```|>)/ { print; exit }' "$d/$f" \
        | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g; s/[*_`]//g' | clean 200
      return
    fi
  done
}

scan_one() {
  d=${1%/.git}
  d=${d%/}
  name=$(basename "$d")
  ct=$(git -C "$d" log -1 --format=%ct 2>/dev/null || true)
  if [ -n "$ct" ]; then
    age=$(( (now - ct) / 3600 ))
  else
    m=$(stat -f %m "$d" 2>/dev/null || echo "$now")
    age=$(( (now - m) / 3600 ))
  fi
  head=$(cat "$d/.git/HEAD" 2>/dev/null || true)
  case $head in
    ref:*) branch=${head##*/} ;;
    *) branch="" ;;
  esac
  uses=0
  if [ -n "$usage" ] && [ -f "$usage" ]; then
    uses=$(grep -cxF "$d" "$usage" 2>/dev/null || true)
    uses=${uses:-0}
  fi
  desc=$(describe "$d")
  recent=$(git -C "$d" log -3 --format='%s;' 2>/dev/null | clean 240)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$name" "$age" "$branch" "$uses" "$desc" "$recent"
}

if [ "${1:-}" = "--one" ]; then
  scan_one "$2"
  exit 0
fi

{
  old_ifs=$IFS
  IFS=:
  for r in $roots; do
    IFS=$old_ifs
    [ -d "$r" ] || continue
    find "$r" -maxdepth "$depth" \( -name node_modules -o -name .build -o -name vendor -o -name target \
      -o -name dist -o -name build -o -name .venv -o -name Pods -o -name DerivedData \) -prune \
      -o -name .git -print -prune 2>/dev/null
  done
  IFS=:
  for f in ${REFLEX_FOLDERS:-}; do
    [ -d "$f" ] && printf '%s\n' "$f"
  done
  IFS=$old_ifs
  if [ -n "${REFLEX_FOLDERS_FILE:-}" ] && [ -f "$REFLEX_FOLDERS_FILE" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && [ -d "$f" ] && printf '%s\n' "$f"
    done < "$REFLEX_FOLDERS_FILE"
  fi
} | sort -u | xargs -P 8 -I{} "$0" --one {}
