import PepeChip from './PepeChip'
import { useDisplayName } from '../lib/useDisplayName'

export default function WalletAccountButton({ address, svg, onClick }: {
  address: `0x${string}`
  svg: string
  onClick: () => void
}) {
  const name = useDisplayName(address)
  return (
    <button
      type="button"
      onClick={onClick}
      title={`${name} · ${address}`}
      aria-label={`open wallet account ${name}, ${address}`}
      className="inline-flex h-9 shrink-0 items-center overflow-hidden rounded-full border border-line py-1 pl-1 pr-3 align-middle transition hover:border-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
    >
      <PepeChip svg={svg} size={24} name={name} className="min-w-0 max-w-[min(220px,40vw)]" />
    </button>
  )
}
