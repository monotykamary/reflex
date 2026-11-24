// Run through scripts/test-agent-status.py: its socket stub verifies that
// status polling uses agent.get {target}, which advances pending launches,
// and returns actual agent_info payloads rather than pane_info payloads.
// Ported from tests/status.bend.

import * as Herdr from '../src/herdr.ts'

const sock = process.env.REFLEX_TEST_SOCKET
if (!sock) {
  process.stderr.write('REFLEX_TEST_SOCKET is not set\n')
  process.exit(1)
}

const cases: [string, string][] = [
  ['w1:p1', 'idle'],
  ['w1:p2', 'working'],
  ['w1:p3', 'blocked'],
  ['named-agent', 'done'],
  ['w1:p5', 'unknown'],
  ['missing-agent', ''],
  ['missing-status', ''],
  ['old-pane-payload', ''],
  ['failed-read', ''],
]
for (const [target, want] of cases) {
  if ((await Herdr.paneStatus(sock, target)) !== want) {
    process.stderr.write('wrong agent status for ' + target + '\n')
    process.exit(1)
  }
}
process.stdout.write('agent status checks passed\n')
