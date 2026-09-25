#!/usr/bin/env node
// greenlist-tools — csv → greenlist-IBCO merkle tree (rules v3).
//
// The tree format is EXACTLY RoundController._greenlisted's verification:
//   leaf   = keccak256(abi.encodePacked(address))  — the 20 raw bytes
//   parent = keccak256(abi.encodePacked(left, right)), left < right
//   an odd level duplicates its last leaf
// proofs carry the sibling hash per level; the contract re-sorts each step,
// so proof element order never matters on-chain.
//
// Usage:
//   node --experimental-strip-types scripts/greenlist-tools.mjs <csv> [-o tree.json]
//
// csv rows: one address per line (a bare list) or the first address-looking
// cell of a comma-separated row; `#` comments and blank lines are skipped;
// entries are lowercased and deduped. Output JSON: {root, count, proofs}.

import fs from 'node:fs'
import { buildGreenlist, parseGreenlistCsv } from '../src/lib/greenlist.ts'

const args = process.argv.slice(2)
const outFlag = args.indexOf('-o')
const outFile = outFlag !== -1 ? args.splice(outFlag, 2)[1] : undefined
const [csvFile] = args

if (!csvFile || args.length !== 1 || outFile === '') {
  console.error('usage: node --experimental-strip-types scripts/greenlist-tools.mjs <csv> [-o tree.json]')
  process.exit(2)
}

let tree
try {
  tree = buildGreenlist(parseGreenlistCsv(fs.readFileSync(csvFile, 'utf8')))
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exit(1)
}

const json = JSON.stringify({ root: tree.root, count: tree.count, proofs: tree.proofs }, null, outFile ? 2 : 0) + '\n'
if (outFile) {
  fs.writeFileSync(outFile, json)
  console.error(`wrote ${tree.count} greenlist entries to ${outFile} (root ${tree.root})`)
} else {
  process.stdout.write(json)
}
