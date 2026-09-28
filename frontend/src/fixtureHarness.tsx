// Isolated visual-verification harness entry — mounts the REAL app unchanged.
// Data comes from src/fixtureRpc.ts via the vite.fixture.config alias:
// an ACTIVE round with a 10-seat ladder and a 137.5 mixETH pot. Read-only
// fixtures; no chain, no signing. Served on port 4181 only.
//
// #chart-fixture mounts CurveChartView directly with hasTrades=true: the live
// marker + YOU ARE HERE stamp only render once trades exist, which the
// read-only harness's empty tape can't produce.
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { CurveChartView } from './components/CurveChart'
import { sampleSineChart } from './lib/sineChart'
import './index.css'

// the seven-field v3 shape pinned by tests/sine-chart.test.mjs (the address
// field is a string — cast for the sampler's readonly bigint[] signature)
const V3 = [3n, 75000000000000n, 450n * 10n ** 18n, 955n * 10n ** 18n,
  10000n * 10n ** 18n, 7711482365186207164818799n, '0x0000000000000000000000000000000000000001'] as unknown as readonly bigint[]
function ChartFixture() {
  const sine = sampleSineChart(V3, 4200, 3)
  // one sampled point drives reserve/price/supply together so the live dot
  // sits ON the curve
  const mid = sine.points[Math.floor(sine.points.length / 2)]
  const round = {
    mode: 1,
    reserve: BigInt(Math.round(mid.reserve * 1e18)),
    supply: BigInt(Math.round(mid.supply * 1e18)),
    marginalPrice: BigInt(Math.round(mid.price * 1e18)),
    swapFeeBps: 250,
    sine,
  }
  return <div className="alt-shell"><div className="alt-play">
    {['style', 'theme', 'live'].map(n => <link key={n} rel="stylesheet" href={`/alt/${n}.css`} />)}
    <section className="actual-curve" style={{ padding: 40 }}>
      <div className="curve-fill"><CurveChartView round={round as never} hasTrades fillBand variant="alt" /></div>
    </section></div>
  </div>
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {location.hash === '#chart-fixture' ? <ChartFixture /> : <App />}
  </StrictMode>,
)
