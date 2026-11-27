#!/bin/sh
# SwiftTerm inline TUI emulation regressions (pending-wrap, ECH/REP, wide cells, VS16).
set -eu
cd "$(dirname "$0")/.."
scripts/prepare-swiftterm.sh
swift test --package-path app --filter InlineEmulationTests
