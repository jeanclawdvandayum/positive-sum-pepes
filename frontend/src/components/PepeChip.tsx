// ─────────────────────────────────────────────────────────────────────────────
// PepeChip — header identity chip (REDESIGN-B0 item 5, spec §5/§7:
// "connected = pepe identity chip" replacing the wallet blob)
//
// Presentational: caller supplies the on-chain SVG markup (from
// descriptor.renderSVG) and the .wei name. Falls back to the locally
// rendered base pepe (same art data the contract draws from) and the
// word "pepe". Sizing follows the [&>svg] injection pattern (inventory
// red-line #2) via .pepe-chip-art in tokens.css.
// ─────────────────────────────────────────────────────────────────────────────

import { useMemo } from 'react'
import { renderPepeSvg } from '../lib/pepeRender'
import { dnaOfId } from './PepePicker'

export default function PepeChip({
  svg,
  name,
  size = 28,
  className = '',
}: {
  /** raw on-chain SVG markup — injected exactly like every other pepe surface */
  svg?: string
  /** .wei name once the registry lands; falls back to "pepe" */
  name?: string
  size?: number
  className?: string
}) {
  const fallback = useMemo(() => renderPepeSvg(dnaOfId(0n)), [])

  return (
    <span className={`pepe-chip ${className}`}>
      <span
        className="pepe-chip-art"
        style={{ width: size, height: size }}
        dangerouslySetInnerHTML={{ __html: svg ?? fallback }}
      />
      <span className="pepe-chip-name">{name ?? 'pepe'}</span>
    </span>
  )
}
