#!/bin/sh
# Native macOS matcher + AppKit renderer regressions for padded TUI links.
set -eu
cd "$(dirname "$0")/.."
scripts/prepare-swiftterm.sh
swift test --package-path app --filter TerminalLinkTests
