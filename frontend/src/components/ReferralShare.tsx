import { useEffect, useId, useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'
import { CHAIN_ID } from '../lib/config'
import { fmtPepeId } from '../lib/format'
import { rpcCall } from '../lib/rpc'
import { useRound } from '../lib/useRound'
import {
  loadReferralPepe, pickReferralQuip, referralPepePng, referralPostText,
  referralXIntent, REFERRAL_QUIPS,
} from '../lib/referralShare'

const button = 'inline-flex min-h-11 items-center justify-center rounded-xl border border-line px-4 py-2 text-sm font-semibold transition hover:bg-bg-2 focus-visible:outline-2 focus-visible:outline-accent disabled:cursor-not-allowed disabled:opacity-40'

export default function ReferralShare({ tokenId, link, enabled }: {
  tokenId: bigint | null
  link: string
  enabled: boolean
}) {
  const { address } = useAccount()
  const { staker } = useRound()
  if (!enabled || !link || tokenId === null || !staker || !address) {
    return <button type="button" disabled className={`${button} mt-3 w-full`}>post to X</button>
  }
  return <SharePanel key={`${address}:${staker}:${tokenId}:${link}`} staker={staker} tokenId={tokenId} link={link} />
}

function SharePanel({ staker, tokenId, link }: { staker: `0x${string}`; tokenId: bigint; link: string }) {
  const panelId = useId()
  const [open, setOpen] = useState(false)
  const [quip, setQuip] = useState(() => pickReferralQuip())
  const [imageUrl, setImageUrl] = useState('')
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState('')
  const mounted = useRef(false)
  useEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])

  const art = useQuery({
    queryKey: ['referral-share-art', CHAIN_ID, staker, tokenId.toString()],
    enabled: open,
    queryFn: async () => referralPepePng(await loadReferralPepe(staker, tokenId, rpcCall)),
    staleTime: Infinity,
  })
  useEffect(() => {
    if (!art.data) return
    const url = URL.createObjectURL(art.data)
    setImageUrl(url)
    return () => URL.revokeObjectURL(url)
  }, [art.data])

  const text = referralPostText(REFERRAL_QUIPS[quip], CHAIN_ID)
  const intent = referralXIntent(text, link)

  async function copyAndOpen() {
    if (!art.data || busy) return
    setBusy(true)
    setStatus('')
    try {
      // Write while this page has focus. The PNG is prepared before the click
      // so clipboard permission is requested directly from the user gesture.
      await navigator.clipboard.write([new ClipboardItem({ 'image/png': art.data })])
      if (!mounted.current) return
      setStatus('pepe copied. paste it into your post in X. use “open X” below if your browser kept you here.')
      window.open(intent, '_blank', 'noopener,noreferrer')
    } catch {
      if (mounted.current) setStatus('save your pepe below, then attach the image to your post in X.')
    } finally {
      if (mounted.current) setBusy(false)
    }
  }

  return <div className="mt-3 min-w-0 text-text-hi">
    <button type="button" className={`${button} w-full`} aria-expanded={open} aria-controls={panelId}
      onClick={() => setOpen(value => !value)}>post to X</button>
    {open && <div id={panelId} className="mt-3 min-w-0 rounded-xl border border-line bg-bg-1 p-4">
      <div className="flex flex-wrap items-center gap-4">
        <div className="flex h-28 w-28 shrink-0 items-center justify-center overflow-hidden rounded-xl border border-line bg-bg-2">
          {imageUrl ? <img src={imageUrl} width={112} height={112} className="block h-full w-full object-contain [image-rendering:pixelated]" alt={`pepe #${fmtPepeId(tokenId)}`} />
            : <span role="status" className="px-2 text-center text-xs text-text-lo">{art.isError ? 'art needs a retry' : 'loading your pepe…'}</span>}
        </div>
        <button type="button" className={button} disabled={busy} onClick={() => setQuip(value => pickReferralQuip(value))}>another quip</button>
      </div>
      <p className="mt-4 whitespace-pre-line break-words text-sm leading-relaxed">{text}</p>
      <p className="mt-2 break-all font-mono text-xs text-text-lo">{link}</p>
      <p className="mt-4 text-xs leading-relaxed text-text-lo">your quip and referral link arrive in X ready to post. paste your copied pepe to add the art.</p>
      {art.isError && <button type="button" className={`${button} mt-3`} onClick={() => { void art.refetch() }}>retry pepe art</button>}
      <button type="button" className={`${button} mt-3 w-full bg-accent text-bg-0 hover:brightness-110 hover:bg-accent`}
        disabled={!art.data || busy} onClick={copyAndOpen}>{busy ? 'copying pepe…' : 'copy pepe & open X'}</button>
      {status && <p role="status" className="mt-3 text-xs leading-relaxed text-text-lo">{status}</p>}
      <div className="mt-3 flex flex-wrap gap-4 text-xs text-text-lo">
        {imageUrl && <a href={imageUrl} download={`psp-pepe-${tokenId}.png`} className="underline underline-offset-4">save pepe PNG</a>}
        <a href={intent} target="_blank" rel="noopener noreferrer" className="underline underline-offset-4">open X</a>
      </div>
    </div>}
  </div>
}
