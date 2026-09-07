import { getAddress, isAddress, zeroAddress } from 'viem'

type Address = `0x${string}`
export type NftVersion = 0 | 1 | undefined
const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase()

export function nftRecipient(value: string, owner: Address, staker: Address): Address {
  const input = value.trim()
  if (!isAddress(input)) throw new Error('Enter a valid wallet or ERC-721 receiver address.')
  const to = getAddress(input)
  if (same(to, zeroAddress) || same(to, staker) || same(to, owner)) {
    throw new Error('Choose a different recipient address.')
  }
  return to
}

/** Single-position flows use individual approval. The explicitly labeled bulk
 * action can request collection approval once. Ownership/session checks remain. */
export async function prepareNftReinvestment(
  owner: Address, operator: Address, ids: readonly bigint[], version: NftVersion,
  operations: {
    assertSession: () => void
    ownerOf: (id: bigint) => Promise<Address>
    isApprovedForAll: () => Promise<boolean>
    getApproved: (id: bigint) => Promise<Address>
    approve: (id: bigint) => Promise<unknown>
    approveAll: () => Promise<unknown>
  },
  collectionApproval = false,
) {
  if (version === undefined) throw new Error('Waiting for NFT approval support to load.')
  if (ids.length === 0 || ids.length > 64 || new Set(ids).size !== ids.length) throw new Error('Choose 1–64 different Pepes.')
  const assertOwners = async () => {
    operations.assertSession()
    const owners = await Promise.all(ids.map(id => operations.ownerOf(id)))
    operations.assertSession()
    if (owners.some(actual => !same(actual, owner))) throw new Error('A Pepe changed owners. Refresh your positions.')
  }
  await assertOwners()
  const all = await operations.isApprovedForAll()
  operations.assertSession()
  if (!all && (version === 0 || collectionApproval)) {
    await operations.approveAll() // legacy UI labels the collection-wide permission
    await assertOwners()
  } else if (!all) {
    for (const id of ids) {
      const approved = await operations.getApproved(id)
      operations.assertSession()
      if (!same(approved, operator)) {
        await assertOwners()
        await operations.approve(id)
        await assertOwners()
      }
    }
  }
  // Recheck earlier approvals too: a wallet can revoke while another prompt is open.
  const stillAll = await operations.isApprovedForAll()
  if (!stillAll) {
    if (version === 0) throw new Error('Collection approval was revoked. Try again.')
    const approved = await Promise.all(ids.map(id => operations.getApproved(id)))
    if (approved.some(actual => !same(actual, operator))) throw new Error('A Pepe approval changed. Try again.')
  }
  await assertOwners()
}

/** NFT management uses a registered round independently of today's trading
 * rules. This bypass permits safe transfers and revocations only. */
export function assertNftManagement(
  staker: Address, account: Address, reinvestor: Address,
  action: { address: Address; functionName: string; args?: readonly unknown[]; value?: bigint },
) {
  const { args = [] } = action
  if (!same(action.address, staker) || (action.value ?? 0n) !== 0n) throw new Error('Invalid NFT management target.')
  if (action.functionName === 'safeTransferFrom' && args.length === 3 && typeof args[0] === 'string' && same(args[0], account)
      && typeof args[1] === 'string' && typeof args[2] === 'bigint' && args[2] > 0n) {
    nftRecipient(args[1], account, staker)
    return
  }
  if (action.functionName === 'approve' && args.length === 2 && typeof args[0] === 'string' && same(args[0], zeroAddress)
      && typeof args[1] === 'bigint' && args[1] > 0n) return
  if (action.functionName === 'setApprovalForAll' && args.length === 2 && typeof args[0] === 'string'
      && same(args[0], reinvestor) && args[1] === false) return
  throw new Error('NFT management permits safe transfers and approval revocations only.')
}
