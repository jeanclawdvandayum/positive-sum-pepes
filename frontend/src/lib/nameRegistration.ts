import { encodeAbiParameters, keccak256, parseAbi, parseAbiParameters, stringToHex, type Address, type Hex, type PublicClient } from 'viem'
import { controllerAbi, factoryAbi, stakerAbi } from './abi.ts'
import { type NameNamespace, wnsAbi } from './weiNames.ts'

export const NAME_REGISTRATION_FEE = 500_000_000_000_000n
export function assertNameFeeQuote(reviewed: bigint | undefined, current: bigint) {
  if (reviewed === undefined || reviewed !== current) throw Error('Your registration fee changed. Review the updated fee and try again.')
}
export const nameRegistrarAbi = parseAbi([
  'function REGISTRAR_VERSION() view returns (uint256)',
  'function REGISTRATION_FEE() view returns (uint256)',
  'function MIN_COMMIT_AGE() view returns (uint256)',
  'function MAX_COMMIT_AGE() view returns (uint256)',
  'function names() view returns (address)',
  'function parentId() view returns (uint256)',
  'function parentEpoch() view returns (uint64)',
  'function registrationEnabled() view returns (bool)',
  'function eligibilityGate() view returns (address)',
  'function gateVersion() view returns (uint256)',
  'function primaryName(address account) view returns (uint256)',
  'function commitments(address account) view returns (bytes32 hash, uint64 createdAt, uint64 epoch, uint256 gateVersion)',
  'function makeCommitment(address account, string label, bytes32 salt) view returns (bytes32)',
  'function registrationPrice(address account, bytes proof) view returns (uint256)',
  'function commit(bytes32 hash)',
  'function register(string label, bytes32 salt, bytes proof) payable returns (uint256)',
  'function selectPrimaryName(uint256 id)',
])
export const nameGateAbi = parseAbi(['function factory() view returns (address)', 'function isEligible(address account, bytes proof) view returns (bool)'])

export function normalizeNameLabel(input: string) { return input.toLowerCase() }
export function isNameLabel(label: string) { return /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/.test(label) }
export type NamePlan = { label: string; salt: Hex }
export function parseNamePlan(input: string | null): NamePlan | undefined {
  try {
    const p = JSON.parse(input ?? 'null')
    if (p && typeof p.label === 'string' && isNameLabel(p.label) && typeof p.salt === 'string' && /^0x[0-9a-f]{64}$/.test(p.salt)) return { label: p.label, salt: p.salt }
  } catch { /* malformed local storage never authorizes a transaction */ }
}
export function nameCommitment(ns: NameNamespace, account: Address, plan: NamePlan): Hex {
  if (!ns.registrar || !isNameLabel(plan.label)) throw Error('Choose a name using 1–32 letters, numbers or hyphens.')
  return keccak256(encodeAbiParameters(parseAbiParameters('address,uint256,uint256,address,bytes32,bytes32'),
    [ns.registrar, BigInt(ns.chainId), ns.parentId, account, keccak256(stringToHex(plan.label)), plan.salt]))
}

type Reader = Pick<PublicClient, 'getChainId' | 'getBlock' | 'readContract'>
/** Finds an owned funded position across all factory rounds. Errors propagate:
 * an incomplete scan must never classify a staker as a paid registrant. */
export async function findNameEligibilityProof(client: Pick<PublicClient, 'readContract'>, factory: Address, account: Address,
  blockNumber: bigint, signal?: AbortSignal): Promise<Hex> {
  const round = await client.readContract({ address: factory, abi: factoryAbi, functionName: 'currentRoundId', blockNumber })
  for (let roundId = round; roundId > 0n; roundId--) {
    signal?.throwIfAborted()
    const entry = await client.readContract({ address: factory, abi: factoryAbi, functionName: 'rounds', args: [roundId], blockNumber })
    const staker = await client.readContract({ address: entry[1], abi: controllerAbi, functionName: 'staker', blockNumber })
    const read = { address: staker, abi: stakerAbi, blockNumber }
    const count = await client.readContract({ ...read, functionName: 'balanceOf', args: [account] })
    for (let start = 0n; start < count; start += 8n) {
      signal?.throwIfAborted()
      const indices = Array.from({ length: Number(count - start < 8n ? count - start : 8n) }, (_, i) => start + BigInt(i))
      const found = await Promise.all(indices.map(async index => {
        const id = await client.readContract({ ...read, functionName: 'tokenOfOwnerByIndex', args: [account, index] })
        const [position, owner] = await Promise.all([
          client.readContract({ ...read, functionName: 'positions', args: [id] }),
          client.readContract({ ...read, functionName: 'ownerOf', args: [id] }),
        ])
        return position[0] > 0n && owner.toLowerCase() === account.toLowerCase() ? id : undefined
      }))
      const id = found.find(value => value !== undefined)
      if (id !== undefined) return encodeAbiParameters(parseAbiParameters('uint256,uint256'), [roundId, id])
    }
  }
  return '0x'
}

export async function readNameRegistration(client: Reader, ns: NameNamespace, factory: Address, account: Address, signal?: AbortSignal) {
  if (!ns.registrar || await client.getChainId() !== ns.chainId) throw Error('Check the configured name network.')
  const block = await client.getBlock({ blockTag: 'latest' })
  const read = { address: ns.registrar, abi: nameRegistrarAbi, blockNumber: block.number }
  const [version, fee, names, parentId, enabled, gate, commitment, epoch, gateVersion, minAge, maxAge, parentOwner, parentResolved, parentRecord] = await Promise.all([
    client.readContract({ ...read, functionName: 'REGISTRAR_VERSION' }),
    client.readContract({ ...read, functionName: 'REGISTRATION_FEE' }),
    client.readContract({ ...read, functionName: 'names' }),
    client.readContract({ ...read, functionName: 'parentId' }),
    client.readContract({ ...read, functionName: 'registrationEnabled' }),
    client.readContract({ ...read, functionName: 'eligibilityGate' }),
    client.readContract({ ...read, functionName: 'commitments', args: [account] }),
    client.readContract({ ...read, functionName: 'parentEpoch' }),
    client.readContract({ ...read, functionName: 'gateVersion' }),
    client.readContract({ ...read, functionName: 'MIN_COMMIT_AGE' }),
    client.readContract({ ...read, functionName: 'MAX_COMMIT_AGE' }),
    client.readContract({ address: ns.names, abi: wnsAbi, functionName: 'ownerOf', args: [ns.parentId], blockNumber: block.number }),
    client.readContract({ address: ns.names, abi: wnsAbi, functionName: 'resolve', args: [ns.parentId], blockNumber: block.number }),
    client.readContract({ address: ns.names, abi: wnsAbi, functionName: 'records', args: [ns.parentId], blockNumber: block.number }),
  ])
  if (version !== 1n || fee !== NAME_REGISTRATION_FEE || names.toLowerCase() !== ns.names.toLowerCase()
    || parentId !== ns.parentId || minAge !== 60n || maxAge !== 86400n) throw Error('The name deployment does not match these registration rules.')
  if (!enabled || parentOwner.toLowerCase() !== ns.registrar.toLowerCase()
    || BigInt(parentResolved) === 0n || parentRecord[3] !== epoch) throw Error('Name registration is paused or the parent needs renewal.')
  const gateFactory = await client.readContract({ address: gate, abi: nameGateAbi, functionName: 'factory', blockNumber: block.number })
  if (gateFactory.toLowerCase() !== factory.toLowerCase()) throw Error('The name eligibility source does not match this PSP deployment.')
  const proof = await findNameEligibilityProof(client, factory, account, block.number, signal)
  const price = await client.readContract({ ...read, functionName: 'registrationPrice', args: [account, proof] })
  if (price !== (proof === '0x' ? NAME_REGISTRATION_FEE : 0n)) throw Error('The name fee does not match your PSP position.')
  return { blockNumber: block.number, timestamp: block.timestamp, commitment, epoch, gateVersion, minAge, maxAge, price, proof }
}
