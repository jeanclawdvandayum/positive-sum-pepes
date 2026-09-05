/** Referral hints are scoped to a chain and immutable per-round registry. */
export interface ReferralHint { nftId: string; registry: string; chainId: number }
const UINT256_MAX = (1n << 256n) - 1n
export function parseReferral(params: URLSearchParams): ReferralHint | null {
  const id = params.get('ref') ?? ''
  const registry = params.get('refRegistry') ?? ''
  const chain = params.get('refChain') ?? ''
  if (!/^[1-9][0-9]{0,77}$/.test(id) || BigInt(id) > UINT256_MAX ||
      !/^0x[0-9a-fA-F]{40}$/.test(registry) || /^0x0+$/.test(registry) ||
      !/^[1-9][0-9]{0,14}$/.test(chain)) return null
  return { nftId: id, registry: registry.toLowerCase(), chainId: Number(chain) }
}
export function referralKey(chainId: number, registry: string): string {
  return `psp-ref-v2:${chainId}:${registry.toLowerCase()}`
}
export function matchingReferral(hint: ReferralHint | null, chainId: number, registry?: string): bigint {
  return hint && hint.chainId === chainId && hint.registry === registry?.toLowerCase() ? BigInt(hint.nftId) : 0n
}
export function referralParams(nftId: bigint, chainId: number, registry: string): string {
  const params = new URLSearchParams({ ref: nftId.toString(), refChain: String(chainId), refRegistry: registry })
  if (!parseReferral(params)) throw new Error('Referral link is unavailable.')
  return params.toString()
}
export function savedReferral(raw: string | null): ReferralHint | null {
  try {
    const hint = JSON.parse(raw ?? '') as ReferralHint
    return parseReferral(new URLSearchParams({ ref: hint.nftId, refRegistry: hint.registry, refChain: String(hint.chainId) }))
  } catch { return null }
}

/** A persisted/link hint never overrides a recorded on-chain entry. */
export function purchaseReferral(hint: bigint, attributed: boolean | undefined): bigint {
  if (attributed === true) return 0n
  if (hint > 0n && attributed === undefined) throw new Error('Checking your round referral. Try again when the connection is ready.')
  return hint
}
export function assertReferralPurchase(expected: { registry: string; hook: string; version: bigint }, target: string, hook: string): void {
  if (expected.version !== 1n || expected.registry.toLowerCase() !== target.toLowerCase() ||
      expected.hook.toLowerCase() !== hook.toLowerCase()) {
    throw new Error('This round needs the updated referral contracts for referrals to be included in a purchase.')
  }
}
