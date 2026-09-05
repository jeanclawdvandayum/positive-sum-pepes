import type { AvatarComponent } from '@rainbow-me/rainbowkit'
import { useRound } from '../lib/useRound'
import { useWalletPepe } from '../lib/useWalletPepe'

/** RainbowKit account identity matches the NFT/address Pepe in the top bar. */
const WalletPepeAvatar: AvatarComponent = ({ address, size }) => {
  const round = useRound()
  const svg = useWalletPepe(address as `0x${string}`, round.staker)
  return (
    <span
      className="pepe-chip-art"
      aria-hidden="true"
      style={{ width: size, height: size }}
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  )
}

export default WalletPepeAvatar
