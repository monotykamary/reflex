// Every law of reflexd's pure core, proven with gdp-wired, each with the bug
// it rules out refused and its rule held to the real code. `bun run laws`
// prints the table and ALL LAWS PROVEN only when every row holds.

import {entries as inbox} from './inbox.ts'
import type {Row} from './kit.ts'
import {run} from './kit.ts'
import {entries as routing} from './routing.ts'
import {entries as undo} from './undo.ts'

export function allRows(): Row[] {
  return [...undo, ...inbox, ...routing].flatMap(run)
}

if (import.meta.main) {
  const t0 = performance.now()
  const rows = allRows()
  let area = ''
  for (const r of rows) {
    if (r.area !== area) {
      area = r.area
      console.log(`\n${area}`)
    }
    console.log(`  ${r.ok ? 'ok  ' : 'FAIL'} ${r.law}\n         ${r.how}: ${r.verdict}`)
  }
  const bad = rows.filter((r) => !r.ok)
  console.log(`\n${rows.length} rows in ${Math.round(performance.now() - t0)} ms`)
  console.log(bad.length === 0 ? 'ALL LAWS PROVEN' : `${bad.length} ROWS FAILED`)
  process.exit(bad.length === 0 ? 0 : 1)
}
