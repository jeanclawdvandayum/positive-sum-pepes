import test from 'node:test'
import assert from 'node:assert/strict'
import { buildSync } from '../node_modules/esbuild/lib/main.js'

// pepeRender.ts imports its JSON art tables, which node's strip-types runner
// cannot resolve directly — bundle it first (same trick as
// script/expanded-art-fixtures.mjs, the Solidity parity fixtures).
const entry = new URL('../src/lib/pepeRender.ts', import.meta.url).pathname
const bundled = buildSync({ entryPoints: [entry], bundle: true, write: false, format: 'esm', platform: 'node' }).outputFiles[0].text
const { renderPepeSvg, decodeDna, DECORATIVE_ART_VERSION } = await import('data:text/javascript;base64,' + Buffer.from(bundled).toString('base64'))

// 4-bit fields: expr | eyes<<4 | hat<<8 | wear<<12 | item<<16 | skin<<20 | iris<<24 | bg<<28
const rasta = (11n << 8n) | (10n << 20n) | (11n << 28n) // Rasta Tam + Purp skin + Purple Haze bg
const joint = (1n << 16n) | (10n << 24n) // Joint item + Redeye iris

test('release 3 decodes the 420 trait axes', () => {
  assert.deepEqual(decodeDna(rasta, 3n), { expr: 0, eye: 0, hat: 11, wear: 0, item: 0, skin: 10, iris: 0, bg: 11 })
  assert.deepEqual(decodeDna(joint, 3n), { expr: 0, eye: 0, hat: 0, wear: 0, item: 1, skin: 0, iris: 10, bg: 0 })
  // out-of-range fields wrap modulo the wider 420 axes (14 expressions)
  assert.equal(decodeDna(15n, 3n).expr, 1)
})

test('a 420 pepe renders the new palette colors', () => {
  const tam = renderPepeSvg(rasta, 3n)
  assert.ok(tam.includes('#2C9A40'), 'rasta tam shows the leaf green')
  assert.ok(tam.includes('#966EC8'), 'purp skin ramp')
  assert.ok(tam.includes('fill="#9672BC"'), 'purple haze background')
  const smoke = renderPepeSvg(joint, 3n)
  assert.ok(smoke.includes('#8C6A1D'), 'joint wrap')
  assert.ok(smoke.includes('#D0483E'), 'glowing cherry')
  assert.ok(smoke.includes('#C42630'), 'redeye iris')
})

test('decorative art follows release 3 while old rounds keep their renderer', () => {
  assert.equal(DECORATIVE_ART_VERSION, 3n)
  // The same dna renders on every release; the 420 palette exists only in v3.
  assert.ok(!renderPepeSvg(rasta, 2n).includes('#2C9A40'))
  assert.ok(!renderPepeSvg(rasta, 1n).includes('#2C9A40'))
  for (const version of [1n, 2n, 3n]) assert.match(renderPepeSvg(rasta, version), /^<svg[^>]*viewBox="0 0 69 69"/)
})
