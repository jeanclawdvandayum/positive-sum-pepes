// ─────────────────────────────────────────────────────────────────────────────
// PepeChip — header identity chip (REDESIGN-B0 item 5, spec §5/§7:
// "connected = pepe identity chip" replacing the wallet blob)
//
// Presentational: caller supplies NFT or address-derived SVG artwork.
// Sizing and clipping are enforced by .pepe-chip-art in tokens.css.
// ─────────────────────────────────────────────────────────────────────────────

export default function PepeChip({
  svg,
  name,
  size = 28,
  className = '',
}: {
  /** raw on-chain SVG markup — injected exactly like every other pepe surface */
  svg: string
  /** .wei name once the registry lands; falls back to "pepe" */
  name?: string
  size?: number
  className?: string
}) {
  return (
    <span className={`pepe-chip ${className}`}>
      <span
        className="pepe-chip-art"
        aria-hidden="true"
        style={{ width: size, height: size }}
        dangerouslySetInnerHTML={{ __html: svg }}
      />
      <span className="pepe-chip-name">{name ?? 'pepe'}</span>
    </span>
  )
}
