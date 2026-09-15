import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createContext, runInContext } from 'node:vm'
import { illustrationLogMultiplier, illustrationPoint } from '../src/pages/explainer/curveIllustration.ts'

const html = readFileSync(new URL('../public/rolling-paper.html', import.meta.url), 'utf8')
const model = html.slice(html.indexOf('let exampleIBCO = 500;'), html.indexOf('const $=id=>'))
const figures = html.slice(html.indexOf('const $=id=>'), html.indexOf('function validAmount('))
const wad = 10n ** 18n

function paper() {
  const elements = new Map()
  const element = id => {
    if (!elements.has(id)) elements.set(id, {
      value: ({ 'curve-reserve': '5000', 'clock-buy': '0.005', 'clock-hours': '120', 'clock-pot-growth': '50' })[id] ?? '',
      textContent: '', innerHTML: '', validity: '',
      getBoundingClientRect: () => ({ width: 760 }),
      setAttribute() {}, removeAttribute() {},
      setCustomValidity(message) { this.validity = message },
      classList: { toggle() {} },
    })
    return elements.get(id)
  }
  const context = createContext({ document: { getElementById: element } })
  runInContext(model + figures + '\nglobalThis.model = PaperMath;', context)
  return { math: context.model, run: code => runInContext(code, context), element }
}

function near(actual, expected, tolerance = 1e-8) {
  assert.ok(Math.abs(actual - expected) <= tolerance * Math.abs(expected), `${actual} != ${expected}`)
}

test('paper and thumbnail match all specified cube-root milestones', () => {
  const { math } = paper()
  const milestones = [1, 4.33582514, 12.13284521, 27.52528847, 54.97502424,
    100.64196972, 172.82749097, 282.50117606, 443.92267925, 675.37163123, 1000]
  for (const [n, expected] of milestones.entries()) {
    near(math.price(math.boot + n * math.wavelength) / math.launchPrice, expected)
    near(Math.exp(illustrationLogMultiplier(n)), expected)
  }
  near(math.price(0), 0.000036028064, 1e-7)
  near(math.price(math.target), 0.075, 1e-12)
  assert.equal(math.boot, 450)
  assert.equal(math.wavelength, 955)
  assert.equal(math.target, 10_000)
})

test('paper scaling changes additional backing by square root across example raises', () => {
  const { math, run } = paper()
  for (const gross of [5, 50, 125, 250, 500, 1000, 2000, 5000, 50000]) {
    run(`exampleIBCO = ${gross}`)
    near(math.wavelength, 955 * Math.sqrt(gross / 500))
    near(math.target - math.boot, 9550 * Math.sqrt(gross / 500))
    near(math.price(math.target), 0.075, 1e-12)
    assert.ok(math.price(0) > 0)
    near(math.price(math.boot), math.launchPrice, 1e-12)
  }
})

test('the signed curve supports prelaunch prices and continues after wave ten', () => {
  const { math, run } = paper()
  run('exampleIBCO = 50000')
  const offset = math.wavelength * 2.3
  near(math.price(math.boot - offset) * math.price(math.boot + offset), math.launchPrice ** 2, 1e-12)
  assert.ok(math.price(math.chartEnd) > math.price(math.target))
  let last = 0
  for (let i = 0; i <= 5000; i++) {
    const price = math.price(math.chartEnd * i / 5000)
    assert.ok(price >= last)
    last = price
  }
  near(illustrationPoint(0).y, 210)
  near(illustrationPoint(2).y, 30)
  assert.ok(illustrationPoint(1).y < 120)
})

test('paper tickets round up in integer wei and retain the one-wei floor', () => {
  const { math } = paper()
  for (const [pot, price] of [[0n, 1n], [1n, 1n], [9999n, 1n], [10000n, 1n], [10001n, 2n]]) {
    assert.equal(math.ticketPrice(pot), price)
  }
  for (const gross of [50n, 125n, 250n, 500n, 1000n, 2000n]) {
    assert.equal(math.ticketPrice(gross * wad / 10n), gross * wad / 100000n)
  }
  assert.equal(math.ticketPrice((2n ** 256n) - 1n), ((2n ** 256n) - 1n) / 10000n + 1n)
})

test('paper clock rejects below the current spot and counts exact whole tickets', () => {
  const { math } = paper()
  for (const pot of [0n, 1n, 50n * wad, 150n * wad, 10n ** 15n]) {
    const q = math.ticketPrice(pot)
    assert.equal(math.clock(q - 1n, 7200, pot).valid, false)
    for (const [amount, units] of [[q, 1n], [2n*q-1n, 1n], [2n*q, 2n], [10n*q, 10n]]) {
      const result = math.clock(amount, 7200, pot)
      assert.equal(result.valid, true)
      assert.equal(result.units, units)
      assert.equal(result.added, Number(units) * 69)
    }
  }
  assert.equal(math.clock(5n * 10n ** 15n, 7200, 50n * wad).units, 1n)
  assert.equal(math.clock(wad, 0, 50n * wad).valid, false)
  assert.equal(math.clock(wad, 248660, 50n * wad).added, 0)
  assert.equal(math.clock(wad, 248650, 50n * wad).added, 10)
})

test('paper decimal entry and labels preserve sub-picounit ticket prices', () => {
  const { run } = paper()
  assert.equal(run("parseMixWei('0.000000000000000001')"), 1n)
  assert.equal(run("formatMixWei(1n)"), '0.000000000000000001')
  assert.equal(run("parseMixWei('0.0000001')"), 10n ** 11n)
  for (const value of ['', '-1', 'NaN', '1e-18', '0.0000000000000000001', '1000000001']) {
    assert.equal(run(`parseMixWei(${JSON.stringify(value)})`), null)
  }
})

test('rendered paper shows eleven wave markers and the current ticket threshold', () => {
  const { run, element } = paper()
  run('curveFigure(); clockFigure();')
  const chart = element('curve-chart').innerHTML
  assert.equal([...chart.matchAll(/data-wave="\d+"/g)].length, 11)
  assert.ok(chart.includes('wave 10'))
  assert.ok(!/NaN|Infinity/.test(chart))
  assert.equal(element('clock-status').textContent, '1 ticket · 69 seconds added')
  assert.equal(element('clock-ticket-out').textContent, '0.005 mixETH')
  element('clock-pot-growth').value = '150'
  run('clockFigure()')
  assert.equal(element('clock-status').textContent, 'Below one current ticket · purchase rejected')
  assert.equal(element('clock-ticket-out').textContent, '0.015 mixETH')
  element('clock-pot-growth').value = '0'
  element('clock-buy').value = '0.000000000000000001'
  run('clockFigure()')
  assert.equal(element('clock-status').textContent, '1 ticket · 69 seconds added')
  assert.equal(element('clock-ticket-out').textContent, '0.000000000000000001 mixETH')
})
