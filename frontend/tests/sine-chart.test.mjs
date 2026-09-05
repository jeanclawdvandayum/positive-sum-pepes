import test from 'node:test'
import assert from 'node:assert/strict'
import { sampleSineChart, sineChartHeadroom } from '../src/lib/sineChart.ts'
import { logTicks } from '../src/lib/chartTicks.ts'
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

test('chart geometry grows past the old four-wave end and keeps headroom beyond 10k', () => {
  const wavelength = Number(raw[4]) / 1e18
  let previousEnd = sampleSineChart(raw).points.at(-1).reserve
  for (const reserve of [10_001, 20_000, 50_000, 100_000]) {
    const c = sampleSineChart(raw, reserve)
    const end = c.points.at(-1)
    assert.ok(end.reserve > previousEnd)
    assert.ok(end.reserve >= sineChartHeadroom(reserve, wavelength))
    assert.ok(c.points.some(p => p.reserve < reserve) && c.points.some(p => p.reserve > reserve))
    assert.ok(c.points.every(p => Number.isFinite(p.price * 1e18) && Number.isFinite(p.supply)))
    const expected = Number(raw[5]) / 1e18 * Math.exp(Number(raw[6]) / 1e18 * (end.reserve - c.boot))
    close(end.price, expected, 1e-10) // expanded endpoint is a full wave seam
    previousEnd = end.reserve
  }
})

test('expansion preserves the original curve and launch supply', () => {
  const original = sampleSineChart(raw)
  const expanded = sampleSineChart(raw, 50_000)
  for (const p of original.points.filter(p => p.reserve > 0)) {
    const match = expanded.points.find(q => Math.abs(q.reserve - p.reserve) < 1e-8)
    assert.ok(match, `missing original reserve ${p.reserve}`)
    close(match.price, p.price, 1e-10)
    close(match.supply, p.supply, 1e-10)
  }
  assert.throws(() => sampleSineChart(raw, Infinity), /Invalid live reserve/)
})

test('expanded logarithmic axes use bounded, ordered ticks inside the visible range', () => {
  assert.deepEqual(logTicks(0.02, 1), [0.02, 0.05, 0.1, 0.2, 0.5, 1])
  assert.equal(logTicks(6, 25_000, 10).at(-1), 20_000)
  for (const [min, max, budget] of [[6, 120_000, 10], [1e-5, 1e30, 12]]) {
    const ticks = logTicks(min, max, budget)
    assert.ok(ticks.length >= 2 && ticks.length <= budget)
    ticks.forEach((v, i) => assert.ok(v >= min && v <= max && (!i || v > ticks[i - 1])))
  }
})
