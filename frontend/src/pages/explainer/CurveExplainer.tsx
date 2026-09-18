import { useId } from 'react'
import { illustrationPoint as point, illustrationFrames } from './curveIllustration'

// Equal animation time steps cover equal reserve increments. CSS owns motion.

function path(from: number, to: number) {
  return Array.from({ length: 65 }, (_, i) => {
    const { x, y } = point(from + (to - from) * i / 64)
    return `${i === 0 ? 'M' : 'L'}${x.toFixed(2)},${y.toFixed(2)}`
  }).join(' ')
}

const ZONES = [
  { from: 0, to: 0.25, calm: true },
  { from: 0.25, to: 0.75, calm: false },
  { from: 0.75, to: 1.25, calm: true },
  { from: 1.25, to: 1.75, calm: false },
  { from: 1.75, to: 2, calm: true },
].map(zone => ({ ...zone, d: path(zone.from, zone.to) }))

const FRAMES = illustrationFrames

function CurveMotionStyles() {
  return (
    <style>{`
        .xd-curve-dot { transform: translate(210px, 104.21px); animation: xd-curve-travel 8s linear infinite alternate; }
        @keyframes xd-curve-travel { ${FRAMES} }
        @media (prefers-reduced-motion: reduce) {
          .xd-curve-dot { animation: none; }
        }
      `}</style>
  )
}

// The story thumbnail and detailed chart share the same sine shape and motion.
export function CurveDiagram() {
  return (
    <>
      <CurveMotionStyles />
      <svg viewBox="0 0 420 240" className="h-full w-full" aria-hidden="true">
        <path d="M28,15 V225 H400" fill="none" stroke="var(--line)" />
        {ZONES.map(zone => (
          <path key={zone.from} d={zone.d} fill="none"
            stroke={zone.calm ? 'var(--phase-calm)' : 'var(--phase-heat)'}
            strokeWidth="7" strokeLinecap="round" />
        ))}
        <g className="xd-curve-dot">
          <circle r="20" fill="var(--text-hi)" opacity="0.12" />
          <circle r="9" fill="var(--text-hi)" />
        </g>
      </svg>
    </>
  )
}

export default function CurveExplainer() {
  const titleId = useId()
  const descId = useId()

  return (
    <section className="mt-6" aria-labelledby={titleId}>
      <CurveMotionStyles />
      <h3 id={titleId} className="font-display text-xl sm:text-2xl">how buying and selling move the price</h3>
      <p className="mt-3 max-w-2xl leading-relaxed text-text-lo">
        buying PSP adds mixETH to the reserves and raises the price. selling takes mixETH
        out and lowers it. the S-shaped bonding curve alternates between flatter and steeper
        sections as reserves grow. one formula covers the opening buy and active trading.
      </p>

      <div className="mt-7 grid items-center gap-8 lg:grid-cols-2">
        <figure className="min-w-0 rounded-xl border border-line bg-bg-0 p-4">
          <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-text-lo">
            <span>first two waves · PSP price · log scale</span>
          </div>
          <svg viewBox="0 0 420 240" className="mt-3 block w-full" role="img" aria-labelledby={descId}>
            <title id={descId}>The first two softened cube-root sine waves reach 4.34 and 12.13 times the launch price. Green marks flatter stretches. Amber marks steeper stretches. The dot follows buys to the right and sells to the left.</title>
            {ZONES.map(zone => (
              <rect key={zone.from} x={point(zone.from).x} y="15" width={182 * (zone.to - zone.from)} height="210"
                fill={zone.calm ? 'var(--phase-calm)' : 'var(--phase-heat)'} opacity="0.07" />
            ))}
            <path d="M28,15 V225 H400" fill="none" stroke="var(--line)" />
            {ZONES.map(zone => (
              <path key={zone.from} d={zone.d} fill="none" stroke={zone.calm ? 'var(--phase-calm)' : 'var(--phase-heat)'}
                strokeWidth="3" strokeLinecap="round" />
            ))}
            <g className="xd-curve-dot">
              <circle r="11" fill="var(--text-hi)" opacity="0.12" />
              <circle r="5" fill="var(--text-hi)" stroke="var(--bg-0)" strokeWidth="2" />
            </g>
          </svg>
          <p className="text-right text-xs text-text-lo">mixETH reserves →</p>
          <figcaption className="mt-4 flex flex-wrap justify-between gap-2 border-t border-line pt-3 text-xs text-text-lo">
            <span>launch 1× → wave two 12.13×</span>
            <span>← sells · buys →</span>
          </figcaption>
        </figure>

        <div className="min-w-0">
          <div className="border-l-2 border-phase-calm pl-4">
            <h4 className="font-data text-sm text-phase-calm">stable zones</h4>
            <p className="mt-2 leading-relaxed">
              on the flatter sections, buying or selling moves the price by a smaller percentage.
            </p>
          </div>
          <div className="mt-6 border-l-2 border-phase-heat pl-4">
            <h4 className="font-data text-sm text-phase-heat">volatile zones</h4>
            <p className="mt-2 leading-relaxed">
              on the steeper sections, the same change in reserves causes a bigger
              percentage move in price.
            </p>
          </div>
          <p className="mt-6 text-sm leading-relaxed text-text-lo">
            ten waves reach 1,000 times the launch price. each wave adds a smaller percentage gain than the last. a 500 mixETH opening buy starts with 450 backing. each wave adds 955 backing, reaching 10,000 at wave ten. the wave width scales with the square root of launch backing.
          </p>
        </div>
      </div>
    </section>
  )
}
