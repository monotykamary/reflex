#!/bin/sh
# Portable regression: the real TerminalSession core lifecycle/callbacks with
# two independent key windows and a controlled, last-active-wins core.
# No AppKit, app build, installed core, or live sessions needed.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$root/app/Sources/Reflex/AgentPopout.swift" "$work/TerminalSession.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
def between(start, end):
    assert source.count(start) == 1 and source.count(end) == 1, 'TerminalSession changed; update test extraction'
    return source.split(start, 1)[1].split(end, 1)[0]
callbacks = '        view.onInput = ' + between('        view.onInput = ', '        view.onLink = ')
state = between('    // MARK: herdr-core\n', '    /// What this view looks like')
methods = '    private func freshScreen()' + between('    private func freshScreen()', '    /// Attach, retrying quietly:')
Path(sys.argv[2]).write_text('''import Foundation
@MainActor final class TerminalSession {
    let pane = "test"
    let view: AgentTerminalView
    var attached = false, ended = false, elsewhere = false, watching = false
    init(cols: Int, rows: Int) {
        view = AgentTerminalView(cols: cols, rows: rows)
''' + callbacks + '''
    }
    func display() -> [String: Any] { [:] }
    func type(_ bytes: ArraySlice<UInt8>) { fatalError("not a legacy terminal") }
    func open() { attachCore(reason: "test") }
    func stop() {
        attached = false
        stream?.close()
        stream = nil
        endFacts()
    }
''' + state + methods + '}\n')
PY
compile() {
  swiftc -swift-version 5 -parse-as-library \
    "$root/app/Tests/SizeOwnershipHarness/stub.swift" \
    "$root/app/Sources/Reflex/CoreSize.swift" "$work/TerminalSession.swift" \
    "$root/app/Tests/SizeOwnershipHarness/main.swift" -o "$1"
}
compile "$work/size-ownership"
"$work/size-ownership"

# Keep the old failure: an own-size repaint attaches interactively. Require
# the ownership assertion (not just a crash/compiler error) to catch it.
python3 - "$work/TerminalSession.swift" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
source = p.read_text()
old = 'observe: true, display: display'
assert source.count(old) == 1, 'update passive-paint regression mutation'
p.write_text(source.replace(old, 'observe: size != nil, display: display'))
PY
compile "$work/active-paint-mutant"
if "$work/active-paint-mutant" --check-passive-paint >"$work/mutant.log" 2>&1; then
  echo 'FAIL active repaint regression was not detected' >&2
  exit 1
fi
grep -q '^FAIL own-size repaint is also read-only' "$work/mutant.log"
echo 'ok   the old active-repaint behavior is rejected by the ownership test'
