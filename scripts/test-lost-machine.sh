#!/bin/sh
# Regression: `reflex machine resume` on a sandbox boat lost (state `error`).
# The real script against stand-ins for boat, hc and sleep; no sandbox,
# herdr-core or profile is touched.
#   1. boat can't power-cycle it: stopped to a snapshot, forced only after
#      that stop fails, then resumed at the size asked for.
#   2. boat power-cycles it: running again, nothing stopped or resumed.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd -P)
W=$(mktemp -d "${TMPDIR:-/tmp}/reflex-lost.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/data/boat/machines"
echo bx_test123 > "$W/data/boat/machines/boat-test"

cat > "$W/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$W/bin/hc" <<'EOF'
#!/bin/sh
# Connected once boat says it runs.
st=$(cat "$W/state")
case "$st" in running|idle) s=connected ;; *) s=unreachable ;; esac
printf '{"machines":[{"name":"boat-test","state":"%s","target":"boat ssh bx_test123","temporary":true}]}\n' "$s"
EOF
cat > "$W/bin/boat" <<'EOF'
#!/bin/sh
echo "$*" >> "$W/calls"
n=$(cat "$W/n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$W/n"
case $1 in
  info)
    st=$(cat "$W/state")
    # A stop pending a while, then failing (its machine never answers),
    # stopped once forced.
    if [ "$st" = stopping ]; then
      if [ -f "$W/forced" ]; then echo stopped > "$W/state"; st=stopped
      elif [ $n -gt 8 ]; then echo failing > "$W/stopst"; fi
    fi
    printf '{"sandbox":{"state":"%s","stop":{"status":"%s"}}}\n' "$st" "$(cat "$W/stopst" 2>/dev/null || echo pending)" ;;
  recover)
    if [ "$MODE" = cycle ]; then echo running > "$W/state"; echo '{}'; else echo '{"code":"recover_unsupported"}'; exit 1; fi ;;
  stop)
    case "$*" in *--force*) : > "$W/forced" ;; *) echo stopping > "$W/state" ;; esac; echo '{}' ;;
  resume)
    echo idle > "$W/state"; echo '{}' ;;
esac
EOF
chmod +x "$W/bin/"*

run() { # run MODE: the script against the stand-ins; the calls boat got
  rm -f "$W/calls" "$W/n" "$W/forced" "$W/stopst"
  echo error > "$W/state"
  W="$W" MODE="$1" REFLEX_DATA="$W/data" PATH="$W/bin:$PATH" sh "$HERE/reflex.sh" machine resume boat-test --type xlarge >/dev/null 2>"$W/err" || { cat "$W/err"; return 1; }
  grep -vE '^info ' "$W/calls" | sed 's/ --json.*//'
}

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; printf '  want: %s\n  got:  %s\n' "$2" "$3"; fail=1; fi; }

got=$(run nocycle | tr '\n' ';')
check "lost, can't power-cycle: stop, forced after it fails, resume at size" \
  "recover bx_test123;stop bx_test123;stop bx_test123 --force;resume bx_test123 --ttl 3600 --type xlarge;" "$got"
grep -q "last good snapshot" "$W/err" && echo "ok   says the forced stop keeps the last good snapshot" || { echo "FAIL no word on the forced stop"; fail=1; }

got=$(run cycle | tr '\n' ';')
check "lost, power-cycled: nothing stopped or resumed" "recover bx_test123;" "$got"

exit $fail
