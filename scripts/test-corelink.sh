#!/bin/sh
# The app's herdr-core stream client (CoreLink.swift) against a real,
# disposable core: framed calls, a first paint, keys typed down the stream,
# a resize, flow control past the first 256 KiB, and a reattach. Then the
# phone's viewer (PhoneLink.swift) asked as reflexd asks it: a colored
# screen, typing, the phone's size. Never your own core.
# Needs swiftc, the app built once (for SwiftTerm), and hc (on PATH, or
# REFLEX_TEST_HC=/path/to/herdr-core).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
hc=${REFLEX_TEST_HC:-$(command -v hc || command -v herdr-core || true)}
[ -n "$hc" ] || { echo "hc not found: install herdr-core or set REFLEX_TEST_HC" >&2; exit 1; }
# PhoneLink draws its screens with SwiftTerm: the one the app's build made.
products="$root/app/.build/out/Products/Debug"
[ -f "$products/SwiftTerm.o" ] || { echo "build the app first (swift build in app/)" >&2; exit 1; }
work=$(mktemp -d -t reflex-corelink)
run=$(mktemp -d /tmp/rxl.XXXX)   # socket paths must stay short
export HC_SESSION=rxlink XDG_RUNTIME_DIR="$run" XDG_STATE_HOME="$work/state" XDG_CONFIG_HOME="$work/config" HC_BIN="$hc"
unset HC_SOCKET HC_TERMINAL_ID
cleanup() { "$hc" server stop >/dev/null 2>&1 || true; rm -rf "$work" "$run"; }
trap cleanup EXIT

swiftc -swift-version 5 -O "$root/app/Tests/CoreLinkHarness/stub.swift" "$root/app/Sources/Reflex/CoreLink.swift" \
  "$root/app/Tests/CoreLinkHarness/main.swift" -o "$work/linktest"
swiftc -swift-version 5 -O "$root/app/Tests/PhoneLinkHarness/stub.swift" "$root/app/Sources/Reflex/CoreLink.swift" \
  "$root/app/Sources/Reflex/PhoneLink.swift" "$root/app/Tests/PhoneLinkHarness/main.swift" \
  -I "$products" -o "$work/phonetest" "$products/SwiftTerm.o"

"$hc" run --bg --no-parent --name echo -- sh -c 'echo ready; stty -echo; while read -r l; do if [ "$l" = big ]; then yes 0123456789abcdef0123456789abcdef0123456789abcdef0123456789 | head -c 800000; echo; else echo "got:$l"; fi; done' >/dev/null
"$work/linktest"
"$hc" kill echo >/dev/null

"$hc" run --bg --no-parent --name color -- sh -c 'printf "\033[31mred here\033[0m plain\n"; stty -echo; while read -r l; do echo "got:$l"; done' >/dev/null
mkdir -p "$work/data"
REFLEX_DATA="$work/data" "$work/phonetest" 2>/dev/null
