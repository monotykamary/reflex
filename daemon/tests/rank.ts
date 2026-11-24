// The folders routing would offer for a few requests, from a scan.
// usage: scripts/reflex-scan.sh > scan.tsv && bun daemon/tests/rank.ts scan.tsv
// Ported from tests/rank.bend.

import {readFileSync} from 'node:fs'
import * as Ix from '../src/folders.ts'
import type {Folder} from '../src/model.ts'

const show = (fs: Folder[]) => fs.map((f) => f.name + ' (' + f.age + 'h)\n').join('')
const fs = Ix.parse(readFileSync(process.argv[2] ?? 'scan.tsv', 'utf8'))
console.log('folders: ' + fs.length)
for (const [q, k] of [
  ['fix the flaky follow test in jev fabric', 8],
  ['add a quicklook keybinding to herdr', 8],
  ['fix the issues listed for pi-fabric after #237, then bun publish', 8],
  ['localterm browser theme bug', 5],
] as const) {
  console.log('--- ' + q)
  console.log(show(Ix.rank(q, fs, k)))
}
