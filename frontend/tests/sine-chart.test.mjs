import test from 'node:test'
import assert from 'node:assert/strict'
import { sampleSineChart } from '../src/lib/sineChart.ts'
// Materialized coefficients read from deployed Base Sepolia round 1 after its
// 500 mixETH genesis: price/supply at launch and wave seams come from the hook.
const raw = [10000000000000n,4605170185988092n,450000000000000000000n,10000000000000000000000n,
  3183333333333333333333n,79432823472428n,693946404661314n,351583251727584819n,
  9107176430886884154n,18438193604119282863623738n,18981002298175746882119151n]
const close = (a,b,t=1e-7) => assert.ok(Math.abs(a-b)/b < t, `${a} != ${b}`)

test('the active chart renders finite, increasing prices and correctly scaled PSP supply without point RPCs', () => {
  const c = sampleSineChart(raw)
  assert.ok(c.points.length > 500)
  assert.equal(c.points[0].supply, 0)
  const boot = c.points.find(p => p.reserve === 450)
  close(boot.price, Number(raw[5])/1e18, 1e-12)
  close(boot.supply, Number(raw[10])/1e18, 1e-12)
  const wave = c.points.find(p => p.reserve === c.boot + Number(raw[4])/1e18)
  close(wave.supply, Number(raw[10]+raw[9])/1e18)
  assert.ok(wave.supply > boot.supply * 1.9, 'post-boot supply must not flatten from a WAD unit error')
  for(let i=1;i<c.points.length;i++) {
    assert.ok(Number.isFinite(c.points[i].price) && Number.isFinite(c.points[i].supply))
    assert.ok(c.points[i].price >= c.points[i-1].price * (1 - 1e-12))
    assert.ok(c.points[i].supply >= c.points[i-1].supply)
  }
  close(c.markers.find(p => p.k === 12).price, 0.06)
})

test('unmaterialized chart coefficients cannot produce a misleading chart', () => {
  assert.throws(() => sampleSineChart(Array(11).fill(0n)), /not been materialized/)
})
