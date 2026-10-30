#!/bin/sh
# reflex-scan: list the folders a new agent session could start in, with the
# facts routing needs. One line per folder, fields separated by a tab:
#
#   path  name  age_hours  branch  uses  description  recent_commits
#
# Roots come from REFLEX_ROOTS (colon-separated, default ~/VCS); git
# repositories whose .git is up to REFLEX_SCAN_DEPTH (default 6) levels below
# a root are listed — deep enough for root/host/org/group/repo layouts
# (~/VCS/work/acme/studio/app). Dependency and build folders, hidden folders
# and archive/archived folders are skipped.
#
# Parents are listed too: a folder that is not a repository itself but holds
# two or more (~/VCS/work/acme with web, mobile, …), for work that spans repos.
# Its description says what it holds; one holding more than twelve is "a
# collection" (~/VCS/open-source), which routing offers only when you name it
# or your words match it. Never a root itself, never your home folder.
#
# REFLEX_FOLDERS (colon-separated) adds folders that are not repositories, and
# REFLEX_FOLDERS_FILE names a file of more, one per line (folders added from
# the Ask bar). REFLEX_USAGE names a file of past spawn paths, one per line,
# counted into `uses`. Existing local session folders in REFLEX_DATA/sessions.tsv
# are also candidates, including non-git folders. Reads only; never writes.
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
  ct=""
  if [ -e "$d/.git" ]; then ct=$(git -C "$d" log -1 --format=%ct 2>/dev/null || true); fi
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
  recent=""
  if [ -e "$d/.git" ]; then recent=$(git -C "$d" log -3 --format='%s;' 2>/dev/null | clean 240); fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$name" "$age" "$branch" "$uses" "$desc" "$recent"
}

# A parent: the repositories it holds ($2 lists every repository found), the
# newest of their activity, and how often sessions started here.
scan_parent() {
  d=$1
  held=$(grep -F "$d/" "$2")
  n=$(printf '%s\n' "$held" | grep -c .)
  names=$(printf '%s\n' "$held" | sed 's#.*/##' | sort -u | head -8 | paste -sd, - | sed 's/,/, /g')
  [ "$n" -gt 8 ] && names="$names and $((n - 8)) more"
  newest=0
  newest=$(printf '%s\n' "$held" | while IFS= read -r r; do git -C "$r" log -1 --format=%ct 2>/dev/null; done | sort -n | tail -1)
  newest=${newest:-0}
  [ "$newest" -eq 0 ] && newest=$(stat -f %m "$d" 2>/dev/null || echo "$now")
  uses=0
  if [ -n "$usage" ] && [ -f "$usage" ]; then
    uses=$(grep -cxF "$d" "$usage" 2>/dev/null || true)
    uses=${uses:-0}
  fi
  if [ "$n" -gt 12 ]; then desc="A collection of $n repositories: $names."; else desc="Holds $n repositories: $names."; fi
  printf '%s\t%s\t%s\t\t%s\t%s\t\n' "$d" "$(basename "$d")" $(( (now - newest) / 3600 )) "$uses" "$desc"
}

case "${1:-}" in
  --one) scan_one "$2"; exit 0 ;;
  --parent) scan_parent "$2" "$3"; exit 0 ;;
esac

repos=$(mktemp)
trap 'rm -f "$repos"' EXIT
old_ifs=$IFS
IFS=:
for r in $roots; do
  IFS=$old_ifs
  [ -d "$r" ] || continue
  find "$r" -maxdepth "$depth" \( -name node_modules -o -name .build -o -name vendor -o -name target \
    -o -name dist -o -name build -o -name .venv -o -name Pods -o -name DerivedData \
    -o -name archive -o -name archived -o \( -name '.?*' ! -name .git ! -path "$r" \) \) -prune \
    -o -name .git -print -prune 2>/dev/null
done | sed 's#/\.git$##' | sort -u > "$repos"
IFS=$old_ifs

{
# The parents: every folder between a root and a repository, counted.
awk -v roots="$roots" -v home="$HOME" '
  BEGIN { nr = split(roots, R, ":") }
  { repo[$0] = 1; paths[++n] = $0 }
  END {
    for (i = 1; i <= n; i++) {
      p = paths[i]; root = ""
      for (j = 1; j <= nr; j++) { r = R[j]; sub(/\/$/, "", r); if (index(p, r "/") == 1 && length(r) > length(root)) root = r }
      if (root == "") continue
      d = p
      while (1) {
        sub(/\/[^\/]*$/, "", d)
        if (length(d) <= length(root) || d == home) break
        count[d]++
      }
    }
    for (d in count) if (count[d] >= 2 && !(d in repo)) cand[d] = 1
    # A folder holding exactly what its parent holds is the same project:
    # list the parent (acme, not acme/packages).
    for (d in cand) { up = d; sub(/\/[^\/]*$/, "", up); if (!(up in cand) || count[up] != count[d]) print d }
  }' "$repos" | sort | xargs -P 8 -I{} "$0" --parent {} "$repos"

{
  cat "$repos"
  if [ -n "${REFLEX_DATA:-}" ] && [ -f "$REFLEX_DATA/sessions.tsv" ]; then
    cut -f3 "$REFLEX_DATA/sessions.tsv" | while IFS= read -r f; do
      case "$f" in /*) [ -d "$f" ] && printf '%s\n' "$f" ;; esac
    done
  fi
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
} | awk -F '\t' '!seen[$1]++'   # a folder once: as a parent when it is one
