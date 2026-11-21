#!/bin/sh
# instabox boxes as Reflex machines: the real script against stand-ins for
# instabox, hc and sleep; no box, herdr-core or profile is touched.
#   1. machine new --provider instabox: the size asked for, its own idle
#      pause on, reached over `instabox ssh ID --`, an hour's time on it.
#   2. machine lapse: kept while its time runs or a window holds it, paused
#      after; boat sandboxes are never touched by it.
#   3. machine state: instabox's words as boat's (paused, a lost host).
#   4. machine resume: paused resumed, stopped started, lost restarted.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd -P)
W=$(mktemp -d "${TMPDIR:-/tmp}/reflex-ib.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/data/boat/machines" "$W/box"
echo running > "$W/state"

cat > "$W/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$W/bin/instabox" <<'EOF'
#!/bin/sh
echo "$*" >> "$W/calls"
case $1 in
  create) echo '{"id":"m_abcdefghijklmnop","name":"box-1234","state":"running"}' ;;
  get)
    st=$(cat "$W/state"); un=false
    [ "$st" = lost ] && { st=running; un=true; }
    printf '{"id":"%s","state":"%s","runtime":{"hostUnreachable":%s}}\n' "$2" "$st" "$un" ;;
  suspend) echo suspended > "$W/state" ;;
  resume|start|restart) echo running > "$W/state" ;;
  rm) : ;;
esac
EOF
cat > "$W/bin/hc" <<'EOF'
#!/bin/sh
# One machine, connected while its box runs; exec runs the line in a home here.
case "$1 $2" in
  "machine add") echo "machine add $*" >> "$W/calls"; echo '{}' ;;
  "machine ls")
    st=$(cat "$W/state"); case $st in running) s=connected ;; *) s=unreachable ;; esac
    printf '{"machines":[{"name":"instabox-abcdefgh","state":"%s","target":"instabox ssh m_abcdefghijklmnop --","temporary":true}]}\n' "$s" ;;
  "machine rm") : ;;
  exec*)
    while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
    HOME="$W/box" "$@" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$W/bin/"*

rx() { W="$W" REFLEX_DATA="$W/data" PATH="$W/bin:$PATH" sh "$HERE/reflex.sh" "$@" 2>>"$W/err"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; printf '  want: %s\n  got:  %s\n' "$2" "$3"; fail=1; fi; }
now=$(date +%s)

# 1. A new box.
name=$(rx machine new --provider instabox --type 8x16) || { cat "$W/err"; exit 1; }
check "named after its id" instabox-abcdefgh "$name"
check "the size asked for, its own idle pause on" \
  "create --json --auto-suspend 30m --meta reflex=1 --vcpus 8 --mem-mib 16384 --name reflex-" "$(grep '^create' "$W/calls" | sed 's/reflex-[0-9a-f]*$/reflex-/')"
check "reached over instabox ssh" 1 "$(grep -c 'machine add --via instabox ssh m_abcdefghijklmnop -- --name instabox-abcdefgh --temp' "$W/calls")"
check "its record" m_abcdefghijklmnop "$(sed -n 1p "$W/data/boat/machines/instabox-abcdefgh")"
u=$(cat "$W/box/.reflex/until"); left=$((u - now))
check "an hour's time on it" yes "$([ $left -ge 3590 ] && [ $left -le 3610 ] && echo yes || echo "no ($left)")"

# 2. Its time.
check "kept while its time runs" kept "$(rx machine lapse instabox-abcdefgh | cut -d' ' -f1)"
echo $((now - 10)) > "$W/box/.reflex/until"
mkdir -p "$W/box/.reflex/held"; echo t3 > "$W/box/.reflex/held/air"
check "a window open on it holds it" held "$(rx machine lapse instabox-abcdefgh)"
rm -rf "$W/box/.reflex/held"
: > "$W/calls"
check "past its time, nothing open: paused" paused "$(rx machine lapse instabox-abcdefgh)"
check "paused by instabox" "suspend m_abcdefghijklmnop" "$(cat "$W/calls")"
echo bx_test > "$W/data/boat/machines/boat-test"
check "a boat sandbox: never" kept "$(rx machine lapse boat-test)"

# 3. Its state, in boat's words.
check "paused is suspended" suspended "$(rx machine state instabox-abcdefgh)"
echo lost > "$W/state"
check "a host that stopped answering is error" error "$(rx machine state instabox-abcdefgh)"

# 4. Back up.
for st in suspended:resume stopped:start lost:restart; do
  echo "${st%%:*}" > "$W/state"; : > "$W/calls"; rm -f "$W/box/.reflex/until"
  rx machine resume instabox-abcdefgh >/dev/null || { cat "$W/err"; fail=1; }
  check "${st%%:*}: instabox ${st#*:}" "${st#*:} m_abcdefghijklmnop" "$(grep -v '^get' "$W/calls")"
  check "${st%%:*}: an hour's time again" yes "$([ -s "$W/box/.reflex/until" ] && echo yes || echo no)"
done
exit $fail
