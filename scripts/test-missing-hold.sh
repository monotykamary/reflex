#!/bin/sh
# Another machine's agents a slow herdr-core answer left out are kept a while
# (MissingHold): the real code, with a stub agent
# (app/Tests/MissingHoldHarness/main.swift).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 6 -o "$work/hold" "$root/app/Sources/Reflex/MissingHold.swift" "$root/app/Tests/MissingHoldHarness/main.swift"
"$work/hold"
