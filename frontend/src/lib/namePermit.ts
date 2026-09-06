import { encodeAbiParameters, parseAbi, parseAbiParameters, parseSignature, type Address, type Hex } from 'viem'

export const remoteNameGateAbi = parseAbi([
  'function GATE_VERSION() view returns (uint256)',
  'function sourceChainId() view returns (uint256)',
  'function factory() view returns (address)',
  'function signer() view returns (address)',
  'function signerEpoch() view returns (uint256)',
  'function MAX_PERMIT_AGE() view returns (uint256)',
])
export const permitFields = [
  { name: 'sourceChainId', type: 'uint256' }, { name: 'factory', type: 'address' },
  { name: 'registrar', type: 'address' }, { name: 'account', type: 'address' },
  { name: 'commitment', type: 'bytes32' }, { name: 'nonce', type: 'uint256' },
  { name: 'parentEpoch', type: 'uint256' }, { name: 'gateVersion', type: 'uint256' },
  { name: 'signerEpoch', type: 'uint256' }, { name: 'roundId', type: 'uint256' },
  { name: 'pepeId', type: 'uint256' }, { name: 'sourceBlock', type: 'uint256' },
  { name: 'sourceBlockHash', type: 'bytes32' }, { name: 'issuedAt', type: 'uint256' },
  { name: 'deadline', type: 'uint256' },
] as const
export type NamePermit = {
  sourceChainId: bigint; factory: Address; registrar: Address; account: Address;
  commitment: Hex; nonce: bigint; parentEpoch: bigint; gateVersion: bigint; signerEpoch: bigint;
  roundId: bigint; pepeId: bigint; sourceBlock: bigint; sourceBlockHash: Hex; issuedAt: bigint; deadline: bigint;
}
export function permitTypedData(chainId: number, gate: Address, permit: NamePermit) {
  return { domain: { name: 'PSPRemoteNameGate', version: '1', chainId, verifyingContract: gate },
    types: { NamePermit: permitFields }, primaryType: 'NamePermit' as const, message: permit }
}
export function encodeNamePermit(p: NamePermit, signature: Hex): Hex {
  const { r, s, yParity } = parseSignature(signature)
  return encodeAbiParameters(parseAbiParameters(
    'address,address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes32,uint256,uint256,uint8,bytes32,bytes32'),
    [p.registrar, p.account, p.commitment, p.nonce, p.parentEpoch, p.gateVersion, p.signerEpoch,
      p.roundId, p.pepeId, p.sourceBlock, p.sourceBlockHash, p.issuedAt, p.deadline, 27 + yParity, r, s])
}

/** A fixed configured service supplies bytes only. The registrar verifies the
 * signature and exact price again before the wallet is asked to transact. */
export async function requestNamePermit(url: string, account: Address, roundId: bigint, pepeId: bigint, signal?: AbortSignal): Promise<Hex> {
  const response = await fetch(`${url.replace(/\/$/, '')}/permit`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account, roundId: roundId.toString(), pepeId: pepeId.toString() }),
    signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(25_000)]) : AbortSignal.timeout(25_000),
  })
  // A compromised endpoint cannot supply an unbounded body to the browser.
  const reader = response.body?.getReader()
  if (!reader) throw Error('The name verifier returned an empty response.')
  let body = '', size = 0
  const decoder = new TextDecoder()
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.length
      if (size > 4096) throw Error('The name verifier returned an invalid response.')
      body += decoder.decode(value, { stream: true })
    }
  } finally { await reader.cancel() }
  if (!response.ok) {
    if (response.status === 409) throw Error('Your stake or reservation is still settling. Wait for finality and try again.')
    if (response.status === 429) throw Error('The name verifier is busy. Please try again shortly.')
    throw Error('The name verifier is unavailable. Your free registration fee stays unchanged; try again shortly.')
  }
  const result = JSON.parse(body)
  if (typeof result.proof !== 'string' || !/^0x[0-9a-fA-F]{1024}$/.test(result.proof)) throw Error('The name verifier returned an invalid permit.')
  return result.proof as Hex
}
