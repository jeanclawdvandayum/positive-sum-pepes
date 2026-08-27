import { renderPepeSvg } from '../lib/pepeRender'

/// Token marks sized like MixLogo: default flows with surrounding text
/// (1.3em, deep-baselined); pass px for a fixed size in chips.

/// dna 0n → every 4-bit axis reads 0, and each `% count` lands on index 0
/// (hat/wear/item slot 0 is blank), so renderPepeSvg(0n) IS the base pepe —
/// the canonical PSP token mark.
const BASE_PSP_DNA = 0n

const PSP_DATA_URI = (() => {
  /// the contract-mirror emits camelCase attrs which aren't valid XML;
  /// normalize so crispEdges survives the image/<xml> parse path.
  const svg = renderPepeSvg(BASE_PSP_DNA).replace('shapeRendering=', 'shape-rendering=')
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`
})()

/// the PSP token icon — the on-chain base pepe
export function PspIcon({ px, className = '' }: { px?: number; className?: string }) {
  return (
    <img
      src={PSP_DATA_URI}
      alt="PSP"
      draggable={false}
      style={px ? { height: px, width: px } : undefined}
      className={`inline-block h-[1.3em] w-[1.3em] shrink-0 align-[-0.32em] ${className}`}
    />
  )
}

/// the canonical Ethereum diamond (/tokens/eth.svg)
export function EthIcon({ px, className = '' }: { px?: number; className?: string }) {
  return (
    <img
      src="/tokens/eth.svg"
      alt="ETH"
      draggable={false}
      style={px ? { height: px, width: px } : undefined}
      className={`inline-block h-[1.3em] w-[1.3em] shrink-0 align-[-0.32em] dark:drop-shadow-[0_0_1px_rgba(255,255,255,0.55)] ${className}`}
    />
  )
}
