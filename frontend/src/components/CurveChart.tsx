import { useMemo, useState } from 'react'
import { sampleCurve } from '../lib/curve'
import { useRound } from '../lib/useRound'
import { fmtAmount, fmtPrice } from '../lib/format'

type YMode = 'price' | 'supply'

const W = 640
const H = 360
const PAD = { l: 64, r: 16, t: 16, b: 40 }

export default function CurveChart() {
  const round = useRound()
  const [yMode, setYMode] = useState<YMode>('price')
  const [hover, setHover] = useState<number | null>(null)

  const pts = useMemo(
    () => (round.curve ? sampleCurve(round.curve, round.supply ?? 0n) : []),
    [round.curve, round.supply],
  )

  const live = useMemo(() => {
    if (!round.reserve || !round.supply || !round.marginalPrice) return null
    return {
      reserve: Number(round.reserve) / 1e18,
      supply: Number(round.supply) / 1e18,
      price: Number(round.marginalPrice) / 1e18,
    }
  }, [round.reserve, round.supply, round.marginalPrice])

  const liveY = live ? (yMode === 'price' ? live.price : live.supply) : 0

  const { path, area, xMax, yMax, hoverPt } = useMemo(() => {
    if (pts.length === 0) return { path: '', area: '', xMax: 1, yMax: 1, hoverPt: null as null | { x: number; y: number } }
    const liveReserve = live?.reserve ?? 0
    const xMaxRaw = Math.max(pts[pts.length - 1].reserve, liveReserve * 1.05)
    const xMax = xMaxRaw || 1
    const yMaxRaw = Math.max(
      ...pts.map((p) => (yMode === 'price' ? p.price : p.supply)),
      liveY,
    )
    const yMax = yMaxRaw || 1

    const sx = (r: number) => PAD.l + (r / xMax) * (W - PAD.l - PAD.r)
    const sy = (v: number) => H - PAD.b - (v / yMax) * (H - PAD.t - PAD.b)

    let d = ''
    pts.forEach((p, i) => {
      const x = sx(p.reserve)
      const y = sy(yMode === 'price' ? p.price : p.supply)
      d += `${i === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`
    })
    const a = `${d}L${sx(pts[pts.length - 1].reserve).toFixed(1)},${H - PAD.b}L${sx(pts[0].reserve).toFixed(1)},${H - PAD.b}Z`
    const hp =
      hover !== null && pts[hover]
        ? { x: sx(pts[hover].reserve), y: sy(yMode === 'price' ? pts[hover].price : pts[hover].supply) }
        : null
    return { path: d, area: a, xMax, yMax, hoverPt: hp }
  }, [pts, yMode, live, hover, liveY])

  const liveX = live ? PAD.l + (live.reserve / xMax) * (W - PAD.l - PAD.r) : 0
  const liveScreenY = H - PAD.b - (liveY / yMax) * (H - PAD.t - PAD.b)

  function onMove(e: React.MouseEvent<SVGSVGElement>) {
    const rect = e.currentTarget.getBoundingClientRect()
    const px = ((e.clientX - rect.left) / rect.width) * W
    const r = ((px - PAD.l) / (W - PAD.l - PAD.r)) * xMax
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

  const fmtY = (v: number) =>
    yMode === 'price' ? fmtPrice(BigInt(Math.round(v * 1e18))) : fmtAmount(BigInt(Math.round(v * 1e18)))

  return (
    <div className="card p-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-lg font-black text-slate-900">the curve</h2>
          <p className="text-xs text-slate-400">
            x: mixETH reserve · y: {yMode === 'price' ? 'PSP price' : 'PSP supply'}
          </p>
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
          </defs>

          {/* gridlines */}
          {[0.25, 0.5, 0.75, 1].map((f) => (
            <g key={f}>
              <line
                x1={PAD.l}
                x2={W - PAD.r}
                y1={H - PAD.b - f * (H - PAD.t - PAD.b)}
                y2={H - PAD.b - f * (H - PAD.t - PAD.b)}
                stroke="#e0f2fe"
                strokeWidth="1"
              />
              <text
                x={PAD.l - 6}
                y={H - PAD.b - f * (H - PAD.t - PAD.b) + 4}
                textAnchor="end"
                className="fill-slate-400"
                fontSize="11"
              >
                {fmtY(f * yMax)}
              </text>
              <line
                y1={PAD.t}
                y2={H - PAD.b}
                x1={PAD.l + f * (W - PAD.l - PAD.r)}
                x2={PAD.l + f * (W - PAD.l - PAD.r)}
                stroke="#f0fdfa"
                strokeWidth="1"
              />
              <text
                x={PAD.l + f * (W - PAD.l - PAD.r)}
                y={H - PAD.b + 18}
                textAnchor="middle"
                className="fill-slate-400"
                fontSize="11"
              >
                {fmtAmount(BigInt(Math.round(f * xMax * 1e18)))}
              </text>
            </g>
          ))}

          <path d={area} fill="url(#curveFill)" />
          <path d={path} fill="none" stroke="url(#curveStroke)" strokeWidth="3" strokeLinecap="round" />

          {/* live point */}
          {live && (
            <g>
              <line
                x1={liveX}
                x2={liveX}
                y1={PAD.t}
                y2={H - PAD.b}
                stroke="#0369a1"
                strokeDasharray="4 4"
                strokeWidth="1.5"
                opacity="0.5"
              />
              <circle cx={liveX} cy={liveScreenY} r="7" fill="#0369a1" fillOpacity="0.2" />
              <circle cx={liveX} cy={liveScreenY} r="4" fill="#0369a1" stroke="white" strokeWidth="2" />
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
                stroke="#94a3b8"
                strokeDasharray="3 3"
                strokeWidth="1"
              />
              <circle cx={hoverPt.x} cy={hoverPt.y} r="5" fill="#38bdf8" stroke="white" strokeWidth="2" />
              <g
                transform={`translate(${Math.min(hoverPt.x + 12, W - 170)},${Math.max(hoverPt.y - 44, PAD.t + 4)})`}
              >
                <rect width="158" height="40" rx="10" fill="white" stroke="#bae6fd" />
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
