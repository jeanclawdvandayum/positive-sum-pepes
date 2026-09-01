// ─────────────────────────────────────────────────────────────────────────────
// ReferralsCard — the den's right column lead (REDESIGN-B3 item 4): link
// generator + the 0.5% mechanic stated plainly. This is the STAKE page's own
// presentation; the shared components/ReferralCard.tsx keeps serving the
// predeposit page untouched — we only reuse its 4s data hooks (no new lanes).
//
// NOTE (copy flag — RESOLVED 2026-08-31): contract truth is a FIXED 0.5% of
// trade volume (CurveHook REFERRAL_FEE_BIPS = 50, spec fix 2026-08-19). This
// card's 0.5%-of-every-trade line is correct; the explainer's old "5% tips
// the referrer" leg was wrong and has been fixed in Landing.tsx to match.
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
          connect a wallet and your link pays you 0.5% of every trade it brings.
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
              pepe #{active?.toString()} isn't referral-eligible yet — visitors can't bind to it.
            </p>
          )}
        </>
      )}

      {/* audit r1 fix 4: line 2 was the 0.5% stated twice — now the mechanism:
          referral fees accrue per block from the round's fee stream (same
          real flow the stake accumulator ticks on; no invented claims). */}
      <p className="mt-3 text-xs leading-relaxed text-text-lo">
        your share accrues per block, straight from the round's fee stream — it
        adds up while you're not looking.
      </p>
    </section>
  )
}
