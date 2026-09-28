// Test-only RPC fixture for the isolated visual harness (fixture-harness +
// vite.fixture.config). Drop-in replacement for `lib/rpc` — the app's hooks
// call these by functionName; we return typed values directly, no ABI
// encoding. Read-only: nothing here can sign or send a transaction.
import type { Address } from 'viem'

const NOW = BigInt(Math.floor(Date.now() / 1000))
const MIX = (n: number) => BigInt(n) * 10n ** 18n

// fixture round addresses — values are keyed by functionName, not `to`
const CONTROLLER = '0x' + 'c1'.repeat(20) as Address
const HOOK = '0x' + 'd2'.repeat(20) as Address
const STAKER = '0x' + 'e3'.repeat(20) as Address
const TOKEN = '0x' + 'f4'.repeat(20) as Address
const MIX_TOKEN = '0x' + 'a5'.repeat(20) as Address

const seatAddress = (i: number) => '0x' + (i + 1).toString().repeat(40).slice(0, 40) as `0x${string}`

const predepositState = [
  MIX(0), MIX(1000), NOW - 86400n, true, false, true, true, 2n, MIX(0), MIX(1000),
]

const state: Record<string, unknown> = {
  // factory / metadata lane
  currentRoundId: 2n,
  rounds: [TOKEN, CONTROLLER, HOOK],
  mixETH: MIX_TOKEN,
  staker: STAKER,
  curveConfig: [MIX(5), 7200n],
  detWindow: 1800n,
  TIME_PER_UNIT: 260n,
  sineConfigured: true,
  TICKET_RULES_VERSION: 3n,
  // hook state — ACTIVE round, ~48h left on the 72h clock
  mode: 1n,
  reserveMixETH: MIX(4200),
  totalSupplyPSP: 4_000_000n * 10n ** 18n,
  sineActive: true,
  sinePriceAt: 10n ** 17n,          // 0.1 mixETH per PSP
  swapFeeBps: 250,
  ticketPrice: 5n * 10n ** 15n,
  detonationAt: NOW + 48n * 3600n,
  potBalance: 1375n * 10n ** 17n,
  // ladder — 10 occupied seats
  ticketCount: 10n,
  // wallet reads
  balanceOf: MIX(250),
  allowance: 0n,
  // predeposit era reads (round already launched)
  PREDEPOSIT_RULES_VERSION: 3n,
  GREEN_DURATION: 3600n,
  OPEN_DURATION: 3600n,
  predepositState,
  predeposits: [MIX(0), 0n, false],
  // misc
  flatTime: 0n,
  totalLocked: 0n,
  MIN_BUY_INPUT: 5n * 10n ** 15n,
  reservationActive: false,
  reservationPhase: 0n,
  // wallet pepe lane: every address owns tokenId 1 with a v3 (420-art) dna
  ownerOf: seatAddress(0),
  dnaOf: 0x0123456789abcdefn,
  PEPE_DNA_VERSION: 3n,
}

export const rpcCall = async (
  _to: Address,
  _abi: readonly unknown[],
  functionName: string,
  args: readonly unknown[] = [],
): Promise<unknown> => {
  if (functionName === 'board') {
    const i = Number(args[0] as bigint)
    return [seatAddress(i), 10n ** 18n * BigInt(1000 - i * 37), MIX(120 - i * 7), NOW - 600n * BigInt(i + 1)]
  }
  if (functionName in state) return state[functionName]
  return 0n
}

export const rpcBatchCall = async (
  _to: Address,
  _abi: readonly unknown[],
  calls: readonly { functionName: string; args?: readonly unknown[] }[],
): Promise<readonly unknown[]> => Promise.all(calls.map(c => rpcCall(_to, _abi, c.functionName, c.args)))

export const rpcLogs = async (): Promise<unknown[]> => []
