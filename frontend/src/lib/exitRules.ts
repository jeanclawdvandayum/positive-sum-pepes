type Address = `0x${string}`
export interface ExitRound { token: Address; controller: Address; hook: Address; staker: Address }
export interface ExitAction { address: Address; functionName: string; args?: readonly unknown[]; value?: bigint }
import { ADDRESSES } from './config'

const same = (a: unknown, b: string) => typeof a === 'string' && a.toLowerCase() === b.toLowerCase()
/// The one-tx exit router; undefined when the env has not deployed one
const GRAVE_ZAP = ADDRESSES.graveZap === '0x' ? undefined : ADDRESSES.graveZap

export async function verifyRoundExit(
  reads: { round: (id: bigint) => Promise<readonly [Address, Address, Address, ...unknown[]]>; staker: (controller: Address) => Promise<Address> },
  id: bigint | undefined, action: ExitAction,
) {
  if (!id) throw new Error('Wait for the selected round to load.')
  const [token, controller, hook] = await reads.round(id)
  const staker = await reads.staker(controller)
  assertRoundExit({ token, controller, hook, staker }, action)
}

/** RS-5: an exit exception is bound to factory-registered targets and selectors.
 * Approvals may only authorize the round's own redemption hook — or, for the
 * one-transaction exit, the round-bound grave zap. */
export function assertRoundExit(round: ExitRound, action: ExitAction) {
  if ((action.value ?? 0n) !== 0n) throw new Error('An exit cannot send native ETH.')
  const { address, functionName, args = [] } = action
  const zap = GRAVE_ZAP
  const zapExit =
    zap !== undefined &&
    ((same(address, zap) && functionName === 'exit' && same(args[0], round.hook) && same(args[1], round.staker)) ||
     (same(address, round.staker) && functionName === 'setApprovalForAll' && same(args[0], zap) && args[1] === true) ||
     (same(address, round.token) && functionName === 'approve' && same(args[0], zap)))
  const allowed =
    zapExit ||
    (same(address, round.hook) && ['redeemBacking', 'claimPot'].includes(functionName)) ||
    (same(address, round.staker) && ['withdraw', 'claimFees', 'claimAllTo', 'requestWithdraw'].includes(functionName)) ||
    (same(address, round.controller) && functionName === 'claimPredepositPSP') ||
    (same(address, round.token) && functionName === 'approve' && same(args[0], round.hook))
  if (!allowed) throw new Error('This action is not an exit from the selected round.')
}
