import { useWalletPepe } from '../lib/useWalletPepe'

/** Same round-aware NFT/avatar identity everywhere a wallet appears. */
export default function WalletPepeArt({ address, staker, className }: {
  address: `0x${string}`; staker?: `0x${string}`; className: string
}) {
  const svg = useWalletPepe(address, staker)
  return <span aria-hidden="true" className={className} style={{ imageRendering: 'pixelated' }}
    dangerouslySetInnerHTML={{ __html: svg }} />
}
