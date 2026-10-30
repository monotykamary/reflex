#!/bin/sh
# Historical local folders are indexed even when they are not repositories.
set -eu
cd "$(dirname "$0")/.."
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/roots/random folder" "$d/roots/repo" "$d/data"
git -C "$d/roots/repo" init -q
printf 'claude\ta\t%s\ttitle\tlast\t0\tpast\npi\tb\t%s\ttitle\tlast\t0\tpast\nclaude\tc\t%s\ttitle\tlast\t0\tpast\ncodex\td\twork:/missing\ttitle\tlast\t0\tpast\n' "$d/roots/random folder" "$d/roots/random folder" "$d/missing" > "$d/data/sessions.tsv"
REFLEX_DATA="$d/data" REFLEX_ROOTS="$d/roots" scripts/reflex-scan.sh > "$d/out"
[ "$(grep -cF "$d/roots/random folder" "$d/out")" -eq 1 ]
grep -qF "$d/roots/repo" "$d/out"
! grep -qF "$d/missing" "$d/out"
! grep -qF 'work:/missing' "$d/out"
echo 'session folder scan: ok'
