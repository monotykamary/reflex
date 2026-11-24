// Smoke test: one call to the default herdr socket (agent.list).
// usage: bun daemon/tests/smoke.ts. Ported from tests/smoke.bend.

import {unixCall} from '../src/host.ts'

const r = await unixCall(process.env.HOME + '/.config/herdr/herdr.sock', '{"id":"1","method":"agent.list","params":{}}\n', 1048576, 3000)
if (!r.ok) {
  console.error(r.msg)
  process.exit(1)
}
console.log(r.v)
