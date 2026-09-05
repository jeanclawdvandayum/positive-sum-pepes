import PepeChip from './PepeChip'

export default function WalletAccountButton({ address, svg, onClick }: {
  address: `0x${string}`
  svg: string
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={address}
      aria-label={`open wallet account ${address}`}
      className="inline-flex h-9 shrink-0 items-center overflow-hidden rounded-full border border-line py-1 pl-1 pr-3 align-middle transition hover:border-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
    >
      <PepeChip svg={svg} size={24} name={`${address.slice(0, 6)}…${address.slice(-4)}`} />
    </button>
  )
}
