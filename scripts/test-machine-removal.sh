#!/bin/sh
# Portable regression: real removal/cache/tunnel code, disposable CLI state.
# No installed herdr, core, SSH connection, or user's profile is touched.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$root" "$work" <<'PY'
from pathlib import Path
import sys
root, work = map(Path, sys.argv[1:])
source = (root / 'app/Sources/Reflex/Machines.swift').read_text()
source += '\n' + (root / 'app/Tests/MachineRemovalHarness/fixtures.swift').read_text()
(work / 'Machines.swift').write_text(source)
core = (root / 'app/Sources/Reflex/HerdrCore.swift').read_text()
assert core.count('enum CoreMachines {') == 1
(work / 'CoreMachines.swift').write_text('import Foundation\n' + 'enum CoreMachines {' + core.split('enum CoreMachines {', 1)[1])
setup = (root / 'app/Sources/Reflex/MachineSetup.swift').read_text()
start = '    nonisolated static func run('
end = '\n}\n\n/// Host field'
assert setup.count(start) == 1 and setup.count(end) == 1
runner = setup.split(start, 1)[1].split(end, 1)[0]
(work / 'MachineSetup.swift').write_text('import Foundation\nenum MachineSetup {\n' + start + runner + '\n}\n')
(work / 'herdr').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['MACHINE_TEST_ROOT'])
kind = pathlib.Path(sys.argv[0]).name
state = root / (kind + '.json')
args = sys.argv[1:]
(root / (kind + '.args')).write_text(json.dumps(args))
if args == ['machine', 'list', '--json']:
    print(state.read_text())
elif len(args) >= 3 and args[:2] == ['machine', 'remove' if kind == 'herdr' else 'rm']:
    if (root / 'fail').exists():
        print('test removal refused', file=sys.stderr)
        sys.exit(1)
    key = 'id' if kind == 'herdr' else 'name'
    rows = json.loads(state.read_text())
    state.write_text(json.dumps([r for r in rows if r[key] != args[2]]))
else:
    print('unexpected command: ' + repr(args), file=sys.stderr)
    sys.exit(2)
''')
(work / 'herdr').chmod(0o755)
(work / 'hc').symlink_to(work / 'herdr')
PY
swiftc -swift-version 5 -parse-as-library \
  "$root/app/Tests/MachineRemovalHarness/stub.swift" \
  "$work/MachineSetup.swift" "$work/Machines.swift" "$work/CoreMachines.swift" \
  "$root/app/Sources/Reflex/Blocking.swift" \
  "$root/app/Tests/MachineRemovalHarness/main.swift" -o "$work/test-removal"
MACHINE_TEST_ROOT="$work" "$work/test-removal"
