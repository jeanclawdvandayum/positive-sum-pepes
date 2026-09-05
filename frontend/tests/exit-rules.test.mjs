import test from 'node:test'
import assert from 'node:assert/strict'
import { assertRoundExit, verifyRoundExit } from '../src/lib/exitRules.ts'
const round = { token: '0x01', controller: '0x02', hook: '0x03', staker: '0x04' }
test('old-round exits are independent of current-round game constants', () => {
  for (const [target, names] of [
    ['hook', ['redeemBacking', 'claimPot']],
    ['staker', ['withdraw', 'requestWithdraw', 'claimFees', 'claimAllTo']],
    ['controller', ['claimPredepositPSP']],
  ]) for (const functionName of names) assertRoundExit(round, { address: round[target], functionName })
  assertRoundExit(round, { address: round.token, functionName: 'approve', args: [round.hook, 123n] })
})
test('exit bypass rejects altered targets, new exposure, unrelated approvals and ETH', () => {
  for (const action of [
    { address: '0x05', functionName: 'withdraw' },
    { address: round.hook, functionName: 'buyWithMix' },
    { address: round.staker, functionName: 'stakeFor' },
    { address: round.staker, functionName: 'cancelWithdraw' },
    { address: round.token, functionName: 'approve', args: ['0x05', 123n] },
    { address: round.hook, functionName: 'claimPot', value: 1n },
  ]) assert.throws(() => assertRoundExit(round, action))
})

test('exit preflight reads only the selected registry entry even if the current round is unreadable', async () => {
  const calls = []
  const reads = {
    round: async id => {
      calls.push(id)
      if (id !== 1n) throw Error('new round unavailable')
      return [round.token, round.controller, round.hook]
    },
    staker: async controller => { assert.equal(controller, round.controller); return round.staker },
  }
  await verifyRoundExit(reads, 1n, { address: round.hook, functionName: 'redeemBacking' })
  assert.deepEqual(calls, [1n])
  await assert.rejects(verifyRoundExit(reads, undefined, { address: round.hook, functionName: 'redeemBacking' }))
  await assert.rejects(verifyRoundExit(reads, 1n, { address: '0x99', functionName: 'redeemBacking' }))
})
