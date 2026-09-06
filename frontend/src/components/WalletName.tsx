import { useDisplayName } from '../lib/useDisplayName'

export default function WalletName({ address, className }: { address: `0x${string}`; className?: string }) {
  const name = useDisplayName(address)
  return <span className={className} title={`${name} · ${address}`}>{name}</span>
}
