type Address = `0x${string}`

export type TopUpStep = 'checking' | 'approve' | 'stake'
export interface TopUpState {
  owner: Address
  withdrawing: boolean
  balance: bigint
  allowance: bigint
  mode: number
  flatTime: bigint
}

/** Reject malformed/rounded inputs; a single wei of PSP is a valid top-up. */
export function parseTopUpAmount(input: string): bigint | undefined {
  const value = input.trim()
  if (!/^(?:\d+(?:\.\d{0,18})?|\.\d{1,18})$/.test(value)) return undefined
  const [whole, fraction = ''] = value.split('.')
  const amount = BigInt(whole || '0') * 10n ** 18n + BigInt(fraction.padEnd(18, '0'))
  return amount > 0n && amount < 2n ** 256n ? amount : undefined
}

/** All writes supplied here must resolve only after a successful receipt. */
export async function topUpPosition(
  target: { owner: Address; staker: Address; id: bigint; amount: bigint },
  operations: {
    assertSession: () => void
    read: () => Promise<TopUpState>
    approve: (spender: Address, amount: bigint) => Promise<unknown>
    stake: (owner: Address, id: bigint, amount: bigint) => Promise<unknown>
    onStep: (step: TopUpStep) => void
  },
) {
  const { owner, staker, id, amount } = target
  if (amount <= 0n || amount >= 2n ** 256n) throw new Error('Enter a positive PSP amount.')
  async function validate() {
    operations.assertSession()
    const state = await operations.read()
    operations.assertSession()
    if (state.owner.toLowerCase() !== owner.toLowerCase()) throw new Error('This pepe is no longer owned by your wallet.')
    if (state.mode >= 2 || state.flatTime !== 0n) throw new Error('This round has ended. You can withdraw this position.')
    if (state.withdrawing) throw new Error('Cancel this pepe’s withdrawal before adding PSP.')
    if (amount > state.balance) throw new Error('Not enough PSP in your wallet for this amount.')
    return state
  }
  operations.onStep('checking')
  let state = await validate()
  if (state.allowance < amount) {
    operations.onStep('approve')
    await operations.approve(staker, amount)
    // Ownership, withdrawal status, wallet and balance can change during approval.
    operations.onStep('checking')
    state = await validate()
  }
  if (state.allowance < amount) throw new Error('PSP approval is not available yet. Wait a moment and try again.')
  operations.onStep('stake')
  await operations.stake(owner, id, amount)
}
