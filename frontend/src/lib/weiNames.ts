import { concatHex, keccak256, parseAbi, stringToHex, type Address, type PublicClient } from 'viem'

// Canonical Ethereum deployment, verified against wei.domains and its repository.
export const WNS_ADDRESS = '0x0000000000696760E15f265e828DB644A0c242EB' as const
export const WEI_NODE = '0xa82820059d5df798546bcc2985157a77c3eef25eba9ba01899927333efacbd6f' as const
export const TEST_NAME_PARENT_ID = 6361740363536127648378182158538670061512393038427336338828631921647240523046n
export const wnsAbi = parseAbi([
  'function records(uint256 id) view returns (string label, uint256 parent, uint64 expiresAt, uint64 epoch, uint64 parentEpoch)',
  'function ownerOf(uint256 id) view returns (address)',
  'function resolve(uint256 id) view returns (address)',
  'function primaryName(address account) view returns (uint256)',
  'function getFullName(uint256 id) view returns (string)',
  'function isAvailable(string label, uint256 parentId) view returns (bool)',
])
export const appNameAbi = parseAbi(['function primaryName(address account) view returns (uint256)'])

export function childNameId(parentId: bigint, label: string): bigint {
  return BigInt(keccak256(concatHex([`0x${parentId.toString(16).padStart(64, '0')}`, keccak256(stringToHex(label))])))
}

export function shortAddress(address: string) { return `${address.slice(0, 6)}…${address.slice(-4)}` }

export type NameNamespace = { chainId: number; names: Address; parentId: bigint; parentLabel: string; registrar?: Address }

/** Same-block forward verification is required even for our own registrar's
 * reverse mapping: WNS names may transfer, be redirected, expire or be reclaimed.
 * A name is display text only; it never becomes a transaction recipient. */
export async function readVerifiedName(client: Pick<PublicClient, 'getChainId' | 'getBlockNumber' | 'readContract'>,
  namespace: NameNamespace, account: Address): Promise<string | undefined> {
  if (await client.getChainId() !== namespace.chainId) throw new Error('Name network mismatch')
  if (childNameId(BigInt(WEI_NODE), namespace.parentLabel) !== namespace.parentId) throw new Error('Name parent mismatch')
  const blockNumber = await client.getBlockNumber({ cacheTime: 0 })
  const read = { address: namespace.names, abi: wnsAbi, blockNumber }
  let id = 0n
  if (namespace.registrar) {
    id = await client.readContract({ address: namespace.registrar, abi: appNameAbi, functionName: 'primaryName', args: [account], blockNumber })
  }
  if (id === 0n) id = await client.readContract({ ...read, functionName: 'primaryName', args: [account] })
  if (id === 0n) return undefined
  const [record, owner, resolved] = await Promise.all([
    client.readContract({ ...read, functionName: 'records', args: [id] }),
    client.readContract({ ...read, functionName: 'ownerOf', args: [id] }),
    client.readContract({ ...read, functionName: 'resolve', args: [id] }),
  ])
  const label = record[0]
  // Display printable ASCII labels only; Unicode bidi/confusable names keep
  // their address label. Registration rules will be enforced by the registrar.
  if (!/^[a-z0-9](?:[a-z0-9-]{0,253}[a-z0-9])?$/.test(label)
    || record[1] !== namespace.parentId || childNameId(namespace.parentId, label) !== id
    || owner.toLowerCase() !== account.toLowerCase() || resolved.toLowerCase() !== account.toLowerCase()) return undefined
  return `${label}.${namespace.parentLabel}.wei`
}
