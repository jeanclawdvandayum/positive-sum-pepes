import { useEffect, useMemo, useSyncExternalStore } from 'react'
import { transactionToasts, type TxToast } from '../lib/transactionToasts'
import { renderPepeSvg } from '../lib/pepeRender'
import { wagmiConfig } from '../lib/config'

const status = {
  preparing: ['lining it up', 'Checking your wallet and network.'],
  simulating: ['checking the move', 'Simulating before you sign.'],
  wallet: ['your move', 'Confirm the transaction in your wallet.'],
  pending: ['frog in flight', 'Submitted. Waiting for confirmation.'],
  success: ['on the record', 'Transaction confirmed.'],
  failed: ['move stopped', 'Transaction failed or was declined.'],
  unknown: ['still unconfirmed', 'Confirmation timed out. Check the explorer before retrying.'],
} as const

function TransactionToast({ item }: { item: TxToast }) {
  const svg = useMemo(() => renderPepeSvg(item.dna), [item.dna])
  const chain = wagmiConfig.chains.find(chain => chain.id === item.chainId)
  const explorer = chain?.blockExplorers?.default
  useEffect(() => {
    const timer = setTimeout(() => transactionToasts.dismiss(item.id, false), Math.max(0, item.updated + 20_000 - Date.now()))
    return () => clearTimeout(timer)
  }, [item.id, item.updated])
  return <article className={`tx-toast tx-toast--${item.stage}`} aria-label={`${item.label}: ${status[item.stage][0]}`}>
    <div className="tx-toast-art" aria-hidden="true">
      <img src={`data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`} alt="" />
      <span className="tx-toast-scan" />
    </div>
    <div className="tx-toast-copy">
      <span className="tx-toast-label">{item.label} / {chain?.name ?? `chain ${item.chainId}`}</span>
      <strong className="font-display">{status[item.stage][0]}</strong>
      <p>{item.detail ?? status[item.stage][1]}</p>
      {item.hash && explorer ? <a href={`${explorer.url}/tx/${item.hash}`} target="_blank" rel="noopener noreferrer">view on {explorer.name} ↗</a>
        : item.stage === 'failed' && <span className="tx-toast-label">No transaction hash was issued.</span>}
    </div>
    <button type="button" className="tx-toast-close" aria-label={`Dismiss ${item.label} notification`} onClick={() => transactionToasts.dismiss(item.id)}>×</button>
    <div key={item.updated} className="tx-toast-life" aria-hidden="true" />
  </article>
}

export default function TransactionToasts() {
  const items = useSyncExternalStore(transactionToasts.subscribe, transactionToasts.snapshot)
  return <aside className="tx-toast-stack" aria-label="Transaction notifications" aria-live="polite" aria-relevant="additions text">
    {items.map(item => <TransactionToast key={item.id} item={item} />)}
  </aside>
}
