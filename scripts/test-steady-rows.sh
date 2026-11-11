#!/bin/sh
# The open session list keeps its rows where they are (SteadyRows): the real
# code from EdgeStrip.swift, compiled with stubs for an agent and the rail's
# order (app/Tests/SteadyRowsHarness/main.swift).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
{
  echo 'import Foundation'
  awk '/^struct SteadyRows \{/{on=1} on&&/^struct AgentList: View \{/{exit} on{print}' "$root/app/Sources/Reflex/EdgeStrip.swift"
} > "$work/steady.swift"
grep -q 'struct SteadyRows' "$work/steady.swift" || { echo "SteadyRows not found in EdgeStrip.swift" >&2; exit 1; }
swiftc -swift-version 6 -o "$work/steady" "$work/steady.swift" "$root/app/Tests/SteadyRowsHarness/main.swift"
"$work/steady"
