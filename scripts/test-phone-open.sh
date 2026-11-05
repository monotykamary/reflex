#!/bin/sh
# macOS main-actor regression. Compile PhoneViewer's actual lifecycle methods
# with a controlled core and inert terminal; no app build or live core needed.
# The full terminal implementation is covered by test-corelink.sh.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d -t reflex-phone-open)
trap 'rm -rf "$work"' EXIT
python3 - "$root/app/Sources/Reflex/PhoneLink.swift" "$work/PhoneViewer.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = "final class PhoneViewer: TerminalDelegate {"
end = "    func type(_ text: String) {"
assert source.count(start) == 1 and source.count(end) == 1, "PhoneViewer structure changed; update the lifecycle test extraction"
viewer = source.split(start, 1)[1].split(end, 1)[0]
Path(sys.argv[2]).write_text("import Foundation\n@MainActor\n" + start + viewer + "}\n")
PY
swiftc -swift-version 5 -O "$root/app/Tests/PhoneOpenHarness/stub.swift" \
  "$work/PhoneViewer.swift" "$root/app/Tests/PhoneOpenHarness/main.swift" \
  -o "$work/phone-open"
"$work/phone-open"
