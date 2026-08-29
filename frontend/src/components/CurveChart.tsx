import { useMemo, useState } from 'react'
import { sampleCurve } from '../lib/curve'
import { useRound } from '../lib/useRound'
import { fmtAmount, fmtPrice } from '../lib/format'
import { markerLabel } from '../lib/sine'

type YMode = 'price' | 'supply'

const W = 640
const H = 440
const PAD = { l: 64, r: 16, t: 16, b: 40 }

export default function CurveChart() {
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
    <div className="card p-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-lg font-black text-slate-900">the curve</h2>
          <p className="text-xs text-slate-400">
            x: mixETH reserve ({lin ? 'linear' : 'log'}) · y:{' '}
            {yMode === 'price' ? ` price (${lin ? 'linear' : 'log'})` : ' supply (linear)'}
          </p>
        </div>
        <div className="flex gap-2">
          <div className="flex rounded-full bg-sky-50 p-1">
            {(['linear', 'log'] as const).map((m) => (
              <button
                key={m}
                onClick={() => setLinTouched(m === 'linear')}
                className={`rounded-full px-4 py-1 text-xs font-bold transition ${
                  lin === (m === 'linear') ? 'bg-white text-psp-deep shadow' : 'text-slate-400'
                }`}
              >
                {m}
              </button>
            ))}
          </div>
          <div className="flex rounded-full bg-sky-50 p-1">
            {(['price', 'supply'] as YMode[]).map((m) => (
              <button
                key={m}
                onClick={() => setYMode(m)}
                className={`rounded-full px-4 py-1 text-xs font-bold transition ${
                  yMode === m ? 'bg-white text-psp-deep shadow' : 'text-slate-400'
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
            <linearGradient id="curveStroke" x1="0" y1="0" x2="1" y2="0">
              <stop offset="0%" stopColor="#38bdf8" />
              <stop offset="100%" stopColor="#4ade80" />
            </linearGradient>
            <linearGradient id="curveFill" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="#4ade80" stopOpacity="0.25" />
              <stop offset="100%" stopColor="#38bdf8" stopOpacity="0.03" />
            </linearGradient>
            {/* clip: linear window cuts the curve mid-flight at xMax */}
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
                  className="fill-slate-400"
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
                  className="fill-slate-400"
                  fontSize="11"
                >
                  {fmtAmount(BigInt(Math.round(t * 1e18)))}
                </text>
              </g>
            )
          })}

          <g clipPath="url(#plotClip)">
            <path d={area} fill="url(#curveFill)" />
            <path d={path} fill="none" stroke="url(#curveStroke)" strokeWidth="3" strokeLinecap="round" />
          </g>

          {pts.length === 0 && (
            <text x={W / 2} y={H / 2} textAnchor="middle" className="fill-slate-400 text-[13px] font-bold">
              curve data unavailable — waiting for the round
            </text>
          )}

          {/* live point */}
          {live && (
            <g>
              <line
                x1={liveX}
                x2={liveX}
                y1={PAD.t}
                y2={H - PAD.b}
                stroke="var(--chart-live)"
                strokeDasharray="4 4"
                strokeWidth="1.5"
                opacity="0.5"
              />
              <circle cx={liveX} cy={liveScreenY} r="7" fill="var(--chart-live)" fillOpacity="0.2" />
              <circle cx={liveX} cy={liveScreenY} r="4" fill="var(--chart-live)" stroke="white" strokeWidth="2" />
            </g>
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
              <circle cx={hoverPt.x} cy={hoverPt.y} r="5" fill="#38bdf8" stroke="white" strokeWidth="2" />
              <g
                transform={`translate(${Math.min(hoverPt.x + 12, W - 170)},${Math.max(hoverPt.y - 44, PAD.t + 4)})`}
              >
                <rect width="158" height="40" rx="10" fill="var(--chart-panel)" stroke="var(--chart-panel-border)" />
                <text x="10" y="17" fontSize="11" className="fill-slate-500">
                  reserve {fmtAmount(BigInt(Math.round(pts[hover].reserve * 1e18)))}
                </text>
                <text x="10" y="31" fontSize="11" fontWeight="bold" className="fill-psp-deep">
                  {yMode === 'price'
                    ? `price ${fmtPrice(BigInt(Math.round(pts[hover].price * 1e18)))}`
                    : `supply ${fmtAmount(BigInt(Math.round(pts[hover].supply * 1e18)))}`}
                </text>
              </g>
            </g>
          )}
        </svg>
      ) : (
        <div className="flex h-48 items-center justify-center text-sm text-slate-400">
          loading curve…
        </div>
      )}

      {live && (
        <div className="mt-1 flex flex-wrap justify-between gap-2 text-xs font-bold text-slate-400">
          <span>
            live:{' '}
            <span className="text-psp-deep">
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
