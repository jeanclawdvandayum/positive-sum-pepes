import { isAddress } from 'viem'
import { controllerAbi, factoryAbi, stakerAbi } from '../../frontend/src/lib/abi.ts'
import { readNameDeployment, readRemoteGate, nameRegistrarAbi } from '../../frontend/src/lib/nameRegistration.ts'
import { permitTypedData, encodeNamePermit } from '../../frontend/src/lib/namePermit.ts'

export class PermitError extends Error {
  constructor(status, message) { super(message); this.status = status }
}
const same = (a, b) => a.toLowerCase() === b.toLowerCase()
const conflict = () => { throw new PermitError(409, 'Eligibility or reservation is still settling.') }
const fresh = (block, now, maxAge) => {
  if (!block.hash || block.timestamp > now + 15n || now - block.timestamp > maxAge) conflict()
}
export function parsePermitRequest(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)
    || Object.keys(input).sort().join(',') !== 'account,pepeId,roundId'
    || typeof input.account !== 'string' || !isAddress(input.account) || BigInt(input.account) === 0n) throw new PermitError(400, 'Invalid permit request.')
  for (const key of ['roundId', 'pepeId']) {
    if (typeof input[key] !== 'string' || !/^(0|[1-9][0-9]{0,77})$/.test(input[key]) || BigInt(input[key]) >= 2n ** 256n)
      throw new PermitError(400, 'Invalid position identifier.')
  }
  if (input.roundId === '0') throw new PermitError(400, 'Invalid round.')
  return { account: input.account, roundId: BigInt(input.roundId), pepeId: BigInt(input.pepeId) }
}
async function checkPosition(client, factory, request, blockNumber) {
  // The client chooses an NFT hint, never a contract, chain or RPC endpoint.
  const round = await client.readContract({ address: factory, abi: factoryAbi, functionName: 'rounds', args: [request.roundId], blockNumber })
  if (BigInt(round[0]) === 0n || BigInt(round[1]) === 0n) conflict()
  const staker = await client.readContract({ address: round[1], abi: controllerAbi, functionName: 'staker', blockNumber })
  const [owner, position] = await Promise.all([
    client.readContract({ address: staker, abi: stakerAbi, functionName: 'ownerOf', args: [request.pepeId], blockNumber }),
    client.readContract({ address: staker, abi: stakerAbi, functionName: 'positions', args: [request.pepeId], blockNumber }),
  ])
  if (!same(owner, request.account) || position[0] <= 0n) conflict()
  return staker
}

/** The only signing path: configured destination + active wallet commitment,
 * source finalized ownership AND a fresh-head recheck. Cross-chain transfers
 * after issuance remain a bounded, documented 180-second trust window. */
export async function issueNamePermit({ destination, source, signer, config, now = () => BigInt(Math.floor(Date.now() / 1000)), signal }, input) {
  const request = parsePermitRequest(input)
  const [sourceChain, destinationChain] = await Promise.all([source.getChainId(), destination.getChainId()])
  if (sourceChain !== config.sourceChainId || destinationChain !== config.namespace.chainId) throw new PermitError(503, 'Verifier network mismatch.')
  const state = await readNameDeployment(destination, config.namespace, request.account)
  if (!same(state.gate, config.gate)) throw new PermitError(503, 'Verifier deployment changed.')
  const policy = await readRemoteGate(destination, state.gate, state.blockNumber, sourceChain, config.factory)
  if (!same(policy.signer, signer.address)) throw new PermitError(503, 'Verifier signer changed.')
  const [hash, createdAt, epoch, version] = state.commitment
  if (BigInt(hash) === 0n || state.nonce === 0n || epoch !== state.epoch || version !== state.gateVersion
    || state.timestamp < createdAt + state.minAge || state.timestamp > createdAt + state.maxAge) conflict()
  const [finalized, latest, destBlock] = await Promise.all([
    source.getBlock({ blockTag: 'finalized' }), source.getBlock({ blockTag: 'latest' }),
    destination.getBlock({ blockNumber: state.blockNumber }),
  ])
  const clock = now()
  fresh(finalized, clock, 3600n); fresh(latest, clock, 60n); fresh(destBlock, clock, 60n)
  if (destBlock.hash !== state.blockHash || finalized.number > latest.number) conflict()
  const [oldStaker, currentStaker] = await Promise.all([
    checkPosition(source, config.factory, request, finalized.number),
    checkPosition(source, config.factory, request, latest.number),
  ])
  if (!same(oldStaker, currentStaker)) conflict()
  // Reject snapshots whose canonical hash changed during the reads.
  const [finalAgain, latestAgain, destAgain] = await Promise.all([
    source.getBlock({ blockNumber: finalized.number }), source.getBlock({ blockNumber: latest.number }),
    destination.getBlock({ blockNumber: state.blockNumber }),
  ])
  if (finalAgain.hash !== finalized.hash || latestAgain.hash !== latest.hash || destAgain.hash !== destBlock.hash) conflict()
  signal?.throwIfAborted()
  fresh(latest, now(), 60n); fresh(destBlock, now(), 60n)
  const permit = { sourceChainId: BigInt(sourceChain), factory: config.factory,
    registrar: config.namespace.registrar, account: request.account, commitment: hash, nonce: state.nonce,
    parentEpoch: state.epoch, gateVersion: state.gateVersion, signerEpoch: policy.signerEpoch,
    roundId: request.roundId, pepeId: request.pepeId, sourceBlock: finalized.number, sourceBlockHash: finalized.hash,
    issuedAt: destBlock.timestamp, deadline: destBlock.timestamp + policy.maxPermitAge }
  const signature = await signer.signTypedData(permitTypedData(destinationChain, config.gate, permit))
  signal?.throwIfAborted()
  const proof = encodeNamePermit(permit, signature)
  // Exercise the same contract verifier used at registration. A commitment,
  // parent epoch, gate or signer change during the request prevents issuance.
  const price = await destination.readContract({ address: config.namespace.registrar, abi: nameRegistrarAbi,
    functionName: 'registrationPrice', args: [request.account, proof] })
  if (price !== 0n) conflict()
  return { proof, deadline: permit.deadline.toString(), sourceBlock: finalized.number.toString() }
}
