import { useMemo, useState } from 'react'
import { sampleCurve } from '../lib/curve'
import { useRound } from '../lib/useRound'
import { fmtAmount, fmtPrice } from '../lib/format'
import { markerLabel } from '../lib/sine'

type YMode = 'price' | 'supply'

const W = 640
const H = 440
const PAD = { l: 64, r: 16, t: 16, b: 40 }

export default function CurveChart({
  hasTrades = true,
  entryPrice,
}: {
  /** any trade logged this round? false → dotted ghost theoretical curve (§8) */
  hasTrades?: boolean
  /** connected user's vw avg buy price (mixETH per PSP) — from the Buy log lane */
  entryPrice?: number
}) {
  const round = useRound()
  const [yMode, setYMode] = useState<YMode>('price')
  // axis default by curve family (2026-08-29): zone teeth read literally on
  // LINEAR axes; the tilted sine spans 4 decades — the staircase of plateaus
  // reads on LOG. User toggle always wins.
  const [linTouched, setLinTouched] = useState<boolean | null>(null)
  const lin = linTouched ?? !(round.sine?.active ?? false)
  const [hover, setHover] = useState<number | null>(null)

  const pts = useMemo(() => {
    if (round.sine?.active && round.sine.points.length) return round.sine.points
    return round.curve ? sampleCurve(round.curve, round.supply ?? 0n) : []
  }, [round.sine, round.curve, round.supply])

  const live = useMemo(() => {
    if (!round.reserve || !round.supply || !round.marginalPrice) return null
    return {
      reserve: Number(round.reserve) / 1e18,
      supply: Number(round.supply) / 1e18,
      price: Number(round.marginalPrice) / 1e18,
    }
  }, [round.reserve, round.supply, round.marginalPrice])

  const liveY = live ? (yMode === 'price' ? live.price : live.supply) : 0

  const { path, area, xMax, xMin, yMax, yMin, sy, sx, hoverPt } = useMemo(() => {
    if (pts.length === 0)
      return {
        path: '', area: '', xMax: 1, xMin: 0.01, yMax: 1, yMin: 1,
        sy: (_v: number) => H - PAD.b,
        sx: (_v: number) => PAD.l,
        hoverPt: null as null | { x: number; y: number },
      }
    const liveReserve = live?.reserve ?? 0
    // linear window (2026-08-23, v2): xMax = max(reserves + 1000, reserves * 1.1)
    // — 1000 mixETH of headroom early, 10% once reserves pass 10k. Rides with the round.
    const xMaxFull = Math.max(pts[pts.length - 1].reserve, liveReserve * 1.05)
    const xMax = (lin ? Math.max(liveReserve + 1000, liveReserve * 1.1) : xMaxFull) || 1
    // y fits the VISIBLE window in linear mode (price at reserve<=xMax),
    // else the whole curve (log view keeps the 4-decade ladder).
    const ysAll = pts.map((p) => (yMode === 'price' ? p.price : p.supply)).filter((v) => v > 0)
    const ys = lin
      ? pts.filter((p) => p.reserve <= xMax).map((p) => (yMode === 'price' ? p.price : p.supply)).filter((v) => v > 0)
      : ysAll
    const yMaxRaw = Math.max(...(ys.length ? ys : ysAll), liveY > 0 ? liveY : 0)
    const yMax = yMaxRaw || 1

    // scale (2026-08-23): LINEAR default — the repeating tooth (exp ramp ->
    // flip -> log runway leveling off) is a literal shape on linear axes;
    // log-log was tuned for the old cliff ladder. Toggle restores it.
    const firstBnd = pts.find((p) => p.reserve > 0)?.reserve ?? xMax / 1e4
    const xMin = lin ? 0 : Math.max(firstBnd * 0.75, xMax / 1e6)
    const sx = lin
      ? (v: number) => PAD.l + (Math.max(v, 0) / xMax) * (W - PAD.l - PAD.r)
      : (v: number) =>
          PAD.l +
          ((Math.log10(Math.max(v, xMin)) - Math.log10(xMin)) /
            (Math.log10(xMax) - Math.log10(xMin))) *
            (W - PAD.l - PAD.r)

    // price mode y: linear when lin (teeth height = literal ΔP), else log
    // decades (4 decades, 0.0001 -> 1).
    let yMin = 0
    let scaleY: (v: number) => number
    if (yMode === 'price' && !lin) {
      yMin = Math.min(...ys) * 0.9
      const lTop = Math.log10(yMax * 1.05)
      const lBot = Math.log10(yMin)
      scaleY = (v: number) =>
        H - PAD.b - ((Math.log10(Math.max(v, yMin)) - lBot) / (lTop - lBot)) * (H - PAD.t - PAD.b)
    } else {
      scaleY = (v: number) => H - PAD.b - (Math.max(v, 0) / yMax) * (H - PAD.t - PAD.b)
    }
    const sy = scaleY

    // path: window to [xMin, xMax] (linear rides with the round; log keeps
    // the full domain minus the sub-shelf seed ramp)
    const vis = pts.filter((p) => p.reserve >= xMin * 0.999 && p.reserve <= xMax * 1.001)
    let d = ''
    vis.forEach((p, i) => {
      const x = sx(p.reserve)
      const y = sy(yMode === 'price' ? p.price : p.supply)
      d += `${i === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`
    })
    const xLast = sx(vis[vis.length - 1].reserve)
    const xFirst = sx(vis[0].reserve)
    const a = `${d}L${xLast.toFixed(1)},${H - PAD.b}L${xFirst.toFixed(1)},${H - PAD.b}Z`
    const hp =
      hover !== null && pts[hover]
        ? { x: sx(pts[hover].reserve), y: sy(yMode === 'price' ? pts[hover].price : pts[hover].supply) }
        : null
    return { path: d, area: a, xMax, xMin, yMax, yMin, sy, sx, hoverPt: hp }
  }, [pts, yMode, lin, live, hover, liveY])

  const liveX = live ? sx(live.reserve) : 0
  const liveScreenY = live ? sy(liveY) : 0

  // §8 empty curve: the deterministic curve is real geometry, but no trade
  // has drawn it yet → render it as a dotted ghost with the designed copy.
  const ghost = pts.length > 0 && !hasTrades

  // y tick values: log 1-2-5 decades (log price mode), quarters otherwise
  const yTicks = useMemo(() => {
    if (yMode !== 'price' || lin || yMin <= 0) return [0.25, 0.5, 0.75, 1].map((f) => f * yMax)
    const lo = yMin
    const hi = yMax * 1.05
    const out: number[] = []
    for (let e = Math.ceil(Math.log10(lo)); e <= Math.floor(Math.log10(hi)); e++)
      for (const m of [1, 2, 5]) {
        const v = m * 10 ** e
        if (v >= lo && v <= hi) out.push(v)
      }
    return out.length >= 2 ? out : [yMin, yMax]
  }, [yMode, yMin, yMax, lin])

  // x ticks: 1-2-5 decades (log), nice ~4-step ladder (linear)
  const xTicks = useMemo(() => {
    const out: number[] = []
    if (lin) {
      const raw = xMax / 4
      const mag = 10 ** Math.floor(Math.log10(raw))
      const norm = raw / mag
      const step = (norm < 1.5 ? 1 : norm < 3.5 ? 2 : norm < 7.5 ? 5 : 10) * mag
      for (let v = step; v <= xMax * 0.999; v += step) out.push(v)
    } else {
      for (let e = Math.ceil(Math.log10(xMin)); e <= Math.floor(Math.log10(xMax)); e++)
        for (const m of [1, 2, 5]) {
          const v = m * 10 ** e
          if (v >= xMin && v <= xMax) out.push(v)
        }
    }
    return out
  }, [xMin, xMax, lin])

  // (anchor crosshairs removed 2026-08-19 — decade x-ticks carry the ladder)

  function onMove(e: React.MouseEvent<SVGSVGElement>) {
    const rect = e.currentTarget.getBoundingClientRect()
    const px = ((e.clientX - rect.left) / rect.width) * W
    const frac = (px - PAD.l) / (W - PAD.l - PAD.r)
    const r = lin
      ? frac * xMax
      : 10 ** (Math.log10(xMin) + frac * (Math.log10(xMax) - Math.log10(xMin)))
    let best = 0
    let bd = Infinity
    pts.forEach((p, i) => {
      const d = Math.abs(p.reserve - r)
      if (d < bd) {
        bd = d
        best = i
      }
    })
    setHover(best)
  }

  return (
    <div className="rounded-xl border border-line bg-bg-1 p-5 font-body">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="font-display text-lg text-text-hi">the curve</h2>
          <p className="text-xs text-text-lo">
            x: mixETH reserve ({lin ? 'linear' : 'log'}) · y:{' '}
            {yMode === 'price' ? ` price (${lin ? 'linear' : 'log'})` : ' supply (linear)'}
          </p>
        </div>
        <div className="flex gap-2">
          <div className="flex rounded-full bg-bg-2 p-1">
            {(['linear', 'log'] as const).map((m) => (
              <button
                key={m}
                onClick={() => setLinTouched(m === 'linear')}
                className={`rounded-full px-4 py-1 text-xs font-semibold transition ${
                  lin === (m === 'linear') ? 'bg-accent text-bg-0' : 'text-text-lo hover:text-text-hi'
                }`}
              >
                {m}
              </button>
            ))}
          </div>
          <div className="flex rounded-full bg-bg-2 p-1">
            {(['price', 'supply'] as YMode[]).map((m) => (
              <button
                key={m}
                onClick={() => setYMode(m)}
                className={`rounded-full px-4 py-1 text-xs font-semibold transition ${
                  yMode === m ? 'bg-accent text-bg-0' : 'text-text-lo hover:text-text-hi'
                }`}
              >
                {m === 'price' ? 'price' : 'supply'}
              </button>
            ))}
          </div>
        </div>
      </div>

      {pts.length > 0 ? (
        <svg
          viewBox={`0 0 ${W} ${H}`}
          className="mt-3 w-full touch-none select-none"
          onMouseMove={onMove}
          onMouseLeave={() => setHover(null)}
        >
          <defs>
            {/* phase accent carries the stroke (B2 §5); the clip stays —
                linear windows cut the curve mid-flight at xMax */}
            <clipPath id="plotClip">
              <rect x={PAD.l} y={PAD.t} width={W - PAD.l - PAD.r} height={H - PAD.t - PAD.b} />
            </clipPath>
          </defs>

          {/* y gridlines + labels (log decades in price mode) */}
          {yTicks.map((t) => {
            const y = sy(t)
            if (y < PAD.t - 1 || y > H - PAD.b + 1) return null
            return (
              <g key={`y-${t}`}>
                <line x1={PAD.l} x2={W - PAD.r} y1={y} y2={y} stroke="var(--chart-grid)" strokeWidth="1" />
                <text
                  x={PAD.l - 6}
                  y={y + 4}
                  textAnchor="end"
                  className="fill-text-lo"
                  fontSize="11"
                >
                  {yMode === 'price'
                    ? fmtPrice(BigInt(Math.round(t * 1e18)))
                    : fmtAmount(BigInt(Math.round(t * 1e18)))}
                </text>
              </g>
            )
          })}

          {/* tilted-sine wave markers: launch tread + quarter-wave anchors;
              tops (k=4/8/12) highlighted — the staircase of plateaus */}
          {round.sine?.active &&
            round.sine.markers.map((m, i) => {
              const x = sx(m.reserve)
              if (x < PAD.l || x > W - PAD.r) return null
              const label = markerLabel(m, fmtPrice)
              if (!label) return null
              return (
                <g key={`sm-${i}`}>
                  <line
                    x1={x} x2={x} y1={PAD.t} y2={H - PAD.b}
                    stroke={m.kind === 'top' ? '#f472b6' : '#fbbf24'}
                    strokeWidth="1" strokeDasharray="4 4" opacity="0.75"
                  />
                  <text
                    x={Math.min(x + 3, W - PAD.r - 120)}
                    y={PAD.t + 12 + (i % 3) * 13}
                    fontSize="10"
                    className={m.kind === 'top' ? 'fill-pink-400' : 'fill-amber-500'}
                  >
                    {label}
                  </text>
                </g>
              )
            })}

          {/* x gridlines + labels (1-2-5 decades, log x) */}
          {xTicks.map((t) => {
            const x = sx(t)
            return (
              <g key={`x-${t}`}>
                <line x1={x} x2={x} y1={PAD.t} y2={H - PAD.b} stroke="var(--chart-grid-minor)" strokeWidth="1" />
                <text
                  x={x}
                  y={H - PAD.b + 18}
                  textAnchor="middle"
                  className="fill-text-lo"
                  fontSize="11"
                >
                  {fmtAmount(BigInt(Math.round(t * 1e18)))}
                </text>
              </g>
            )
          })}

          <g clipPath="url(#plotClip)">
            {!ghost && <path d={area} fill="var(--accent)" fillOpacity="0.05" />}
            {/* audit r1 fix 2: the drawn curve is SOLID phase accent with a soft
                accent glow; only the ghost (no trades yet) stays gray + dashed.
                Stroke rides an inline STYLE — var() is not reliable in SVG
                presentation attributes, and this line must never fall back to
                a neutral. Scale math untouched. */}
            <path
              d={path}
              fill="none"
              strokeWidth={ghost ? 2 : 3}
              strokeDasharray={ghost ? '2 6' : undefined}
              strokeLinecap="round"
              opacity={ghost ? 0.8 : 1}
              style={{
                stroke: ghost ? 'var(--text-lo)' : 'var(--accent)',
                filter: ghost
                  ? undefined
                  : 'drop-shadow(0 0 5px color-mix(in srgb, var(--accent) 55%, transparent))',
              }}
            />
          </g>

          {ghost && (
            <text
              x={W / 2}
              y={H / 2}
              textAnchor="middle"
              className="fill-text-lo text-[13px] font-semibold"
            >
              no trades yet — the first buy draws this for real.
            </text>
          )}

          {pts.length === 0 && (
            <text x={W / 2} y={H / 2} textAnchor="middle" className="fill-text-lo text-[13px] font-semibold">
              curve data unavailable — waiting for the round
            </text>
          )}

          {/* live point — phase accent with a soft glow (B2 §5) */}
          {live && !ghost && (
            <g>
              <line
                x1={liveX}
                x2={liveX}
                y1={PAD.t}
                y2={H - PAD.b}
                stroke="var(--accent)"
                strokeDasharray="4 4"
                strokeWidth="1.5"
                opacity="0.5"
              />
              <circle cx={liveX} cy={liveScreenY} r="11" fill="var(--accent)" fillOpacity="0.12" />
              <circle cx={liveX} cy={liveScreenY} r="6" fill="var(--accent)" fillOpacity="0.25" />
              <circle
                cx={liveX}
                cy={liveScreenY}
                r="4"
                fill="var(--accent)"
                stroke="var(--text-hi)"
                strokeWidth="1.5"
              />
            </g>
          )}

          {/* your entry — vw avg buy price, Buy-log derived (B2 §5) */}
          {yMode === 'price' && entryPrice !== undefined && entryPrice > 0 && (
            <EntryMark price={entryPrice} sy={sy} />
          )}

          {/* hover crosshair */}
          {hoverPt && hover !== null && pts[hover] && (
            <g>
              <line
                x1={hoverPt.x}
                x2={hoverPt.x}
                y1={PAD.t}
                y2={H - PAD.b}
                stroke="var(--chart-hover-dash)"
                strokeDasharray="3 3"
                strokeWidth="1"
              />
              <circle cx={hoverPt.x} cy={hoverPt.y} r="5" fill="var(--accent)" stroke="var(--text-hi)" strokeWidth="1.5" />
              <g
                transform={`translate(${Math.min(hoverPt.x + 12, W - 170)},${Math.max(hoverPt.y - 44, PAD.t + 4)})`}
              >
                <rect width="158" height="40" rx="8" fill="var(--chart-panel)" stroke="var(--chart-panel-border)" />
                <text x="10" y="17" fontSize="11" className="fill-text-lo">
                  reserve {fmtAmount(BigInt(Math.round(pts[hover].reserve * 1e18)))}
                </text>
                <text x="10" y="31" fontSize="11" fontWeight="bold" className="fill-text-hi">
                  {yMode === 'price'
                    ? `price ${fmtPrice(BigInt(Math.round(pts[hover].price * 1e18)))}`
                    : `supply ${fmtAmount(BigInt(Math.round(pts[hover].supply * 1e18)))}`}
                </text>
              </g>
            </g>
          )}
        </svg>
      ) : (
        <div className="flex h-48 items-center justify-center text-sm text-text-lo">
          loading curve…
        </div>
      )}

      {live && !ghost && (
        <div className="mt-1 flex flex-wrap justify-between gap-2 text-xs font-semibold text-text-lo">
          <span className="tabular font-data">
            live:{' '}
            <span className="text-text-hi">
              {fmtAmount(round.reserve)} mix · {fmtAmount(round.supply)} PSP ·{' '}
              {fmtPrice(round.marginalPrice)}
            </span>
          </span>
          <span>● you are here</span>
        </div>
      )}
    </div>
  )
}

/// Entry mark (B2 §5): dashed pepe-green line at the connected user's vw
/// avg buy price — drawn through the SAME sy() the curve uses, so it lands
/// correctly in linear and log modes without touching scale math. Renders
/// only while the price is inside the visible y window.
function EntryMark({ price, sy }: { price: number; sy: (v: number) => number }) {
  const y = sy(price)
  if (!Number.isFinite(y) || y < PAD.t + 6 || y > H - PAD.b - 2) return null
  return (
    <g>
      <line
        x1={PAD.l}
        x2={W - PAD.r}
        y1={y}
        y2={y}
        stroke="var(--pepe)"
        strokeWidth="1.5"
        strokeDasharray="6 4"
        opacity="0.75"
      />
      <text
        x={W - PAD.r - 4}
        y={y - 6}
        textAnchor="end"
        fontSize="10"
        className="fill-pepe font-semibold"
      >
        your entry · {fmtPrice(BigInt(Math.round(price * 1e18)))}
      </text>
    </g>
  )
}
