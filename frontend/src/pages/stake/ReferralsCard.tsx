// ─────────────────────────────────────────────────────────────────────────────
// ReferralsCard — the den's right column lead (REDESIGN-B3 item 4): link
// generator and referral fee share. This is the STAKE page's own
// presentation; the shared components/ReferralCard.tsx keeps serving the
// predeposit page untouched — we only reuse its 4s data hooks (no new lanes).
//
// Referral chains split 5% of attributed trade fees; the closest tier gets
// 80% of that leg. These are live transfers, not a per-block accumulator.
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useMemo, useState } from 'react'
import { useAccount } from 'wagmi'
import { useCanRefer, refLinkFor, useReferral } from '../../components/ReferralCard'

export default function ReferralsCard() {
  const { isConnected } = useAccount()
  const { pepeIds, registry } = useReferral()
  const [selected, setSelected] = useState<bigint | null>(null)
  const [copied, setCopied] = useState(false)

  const ids = useMemo(() => [...pepeIds].sort((a, b) => (a < b ? -1 : 1)), [pepeIds])
  const active = selected !== null && ids.includes(selected) ? selected : (ids[0] ?? null)
  const canRefer = useCanRefer(registry, active)
  const link = active !== null ? refLinkFor(active) : ''

  useEffect(() => {
    if (!copied) return
    const t = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(t)
  }, [copied])

  async function copyLink() {
    try {
      await navigator.clipboard.writeText(link)
      setCopied(true)
    } catch {
      window.prompt('copy your referral link', link)
      setCopied(true)
    }
  }

  return (
    <section className="rounded-2xl border border-line bg-bg-1 p-5" aria-label="referrals">
      <h2 className="font-display text-lg">referrals</h2>

      {!isConnected ? (
        <p className="mt-3 text-sm leading-relaxed text-text-lo">
          invite the usual suspects. connect your wallet to share your pepe’s referral link. referral chains share 5% of trading fees from wallets that accept the referral.
        </p>
      ) : ids.length === 0 ? (
        <p className="mt-3 text-sm leading-relaxed text-text-lo">stake a pepe to unlock referral links</p>
      ) : (
        <>
          <select
            value={active !== null ? active.toString() : ''}
            onChange={(e) => setSelected(BigInt(e.target.value))}
            className="st-select mt-3"
            aria-label="which pepe's link"
          >
            {ids.map((id) => (
              <option key={id.toString()} value={id.toString()}>
                pepe #{id.toString()}
              </option>
            ))}
          </select>
          <div className="st-linkbox mt-3">{link}</div>
          <button type="button" className="st-btn st-btn-primary mt-3 w-full" onClick={copyLink}>
            {copied ? 'copied ✓' : 'copy referral link'}
          </button>
          {canRefer === false && (
            <p className="mt-2 text-xs text-phase-heat">
              pepe #{active?.toString()} needs referral eligibility before visitors can accept its referral.
            </p>
          )}
        </>
      )}

      <p className="mt-3 text-xs leading-relaxed text-text-lo">
        the closest referrer gets 80% of the referral share. the other tiers split the rest. each referred trade pays the chain.
      </p>
    </section>
  )
}
