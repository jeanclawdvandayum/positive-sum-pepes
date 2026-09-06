// Read-only: pins parent custody, expiry and canonical WNS code to one mainnet block.
import { createPublicClient, http, keccak256 } from 'viem'
import { writeFileSync } from 'node:fs'
import { childNameId, WEI_NODE, WNS_ADDRESS, wnsAbi } from '../src/lib/weiNames.ts'
const label = process.argv[2] || 'pepetesters'
if (!/^[a-z0-9-]+$/.test(label)) throw Error('Pass one lowercase parent label')
const client = createPublicClient({ transport: http(process.env.WNS_RPC_URL || 'https://ethereum-rpc.publicnode.com', { timeout: 15000, retryCount: 1 }) })
if (await client.getChainId() !== 1) throw Error('Expected Ethereum mainnet')
const block = await client.getBlock({ blockTag: 'finalized' })
const parentId = childNameId(BigInt(WEI_NODE), label)
const common = { address: WNS_ADDRESS, abi: wnsAbi, blockNumber: block.number, args: [parentId] }
const [record, owner, fullName, code] = await Promise.all([
  client.readContract({ ...common, functionName: 'records' }),
  client.readContract({ ...common, functionName: 'ownerOf' }),
  client.readContract({ ...common, functionName: 'getFullName' }),
  client.getCode({ address: WNS_ADDRESS, blockNumber: block.number }),
])
if (!code || code === '0x' || record[0] !== label || record[1] !== 0n || fullName !== `${label}.wei`) throw Error('Parent validation failed')
const result = { chainId: 1, blockNumber: block.number.toString(), blockHash: block.hash,
  blockTimestamp: block.timestamp.toString(), registry: WNS_ADDRESS, registryCodeHash: keccak256(code),
  parentId: parentId.toString(), fullName, owner, expiresAt: record[2].toString(),
  expiresAtUTC: new Date(Number(record[2]) * 1000).toISOString(), epoch: record[3].toString(),
  sourceRepository: 'https://github.com/src-company/wei-names', sourceCommit: '8eb07215182bacbfa5ca624f9a147998b57ba90e',
  sourceMatch: 'Repository API reviewed; deployed bytecode hash recorded, not a reproducible source-verification claim.',
}
const output = JSON.stringify(result, null, 2) + '\n'
if (process.argv[3]) writeFileSync(process.argv[3], output)
console.log(output)
