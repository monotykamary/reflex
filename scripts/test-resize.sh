#!/bin/sh
# A window's view of a herdr-core terminal across resizes: a full-screen-ish
# TUI (pi by default, or the command given) in a disposable core, drawn into
# SwiftTerm as the app draws it, resized as a window is; after each settle
# the view must match the core's own screen. Never your own core.
# Needs swiftc, the app built once (for SwiftTerm), and hc (on PATH, or
# REFLEX_TEST_HC=/path/to/herdr-core).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
hc=${REFLEX_TEST_HC:-$(command -v hc || command -v herdr-core || true)}
[ -n "$hc" ] || { echo "hc not found: install herdr-core or set REFLEX_TEST_HC" >&2; exit 1; }
products="$root/app/.build/out/Products/Debug"
[ -f "$products/SwiftTerm.o" ] || { echo "build the app first (swift build in app/)" >&2; exit 1; }
work=$(mktemp -d -t reflex-resize)
run=$(mktemp -d /tmp/rxr.XXXX)   # socket paths must stay short
export HC_SESSION=rxresize XDG_RUNTIME_DIR="$run" XDG_STATE_HOME="$work/state" XDG_CONFIG_HOME="$work/config" HC_BIN="$hc"
unset HC_SOCKET HC_TERMINAL_ID
cleanup() { "$hc" server stop >/dev/null 2>&1 || true; rm -rf "$work" "$run"; }
trap cleanup EXIT

swiftc -swift-version 5 -O "$root/app/Tests/ResizeHarness/stub.swift" "$root/app/Sources/Reflex/CoreLink.swift" "$root/app/Sources/Reflex/CoreSize.swift" \
  "$root/app/Tests/ResizeHarness/main.swift" -I "$products" -o "$work/resizetest" "$products/SwiftTerm.o"

[ $# -gt 0 ] || set -- pi
"$hc" run --bg --no-parent --name tui --cwd "$work" -- "$@" >/dev/null
"$work/resizetest" tui
