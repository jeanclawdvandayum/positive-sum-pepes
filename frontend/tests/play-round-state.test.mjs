import test from 'node:test'
import assert from 'node:assert/strict'
import { playRoundState } from '../src/lib/playRoundState.ts'

const hook1 = '0x00000000000000000000000000000000000000a1'
const hook2 = '0x00000000000000000000000000000000000000b2'
const round = (id, mode, hook = hook1) => ({ id, mode, hook, readError: undefined })
const idle = { checked: false, dead: false }
const dead1 = { checked: true, dead: true, roundId: 1n, hook: hook1, mode: 2, claimable: 100n }

test('a successor clears rebirth and settlement even while the old-round reader and local receipt persist', () => {
  assert.deepEqual(playRoundState(round(1n, 1), idle), {
    settled: false, spawnFromRoundId: undefined, claimable: undefined,
  })
  // A confirmed detonation is visible before the polling reads catch up.
  assert.equal(playRoundState(round(1n, 1), idle, 1n).spawnFromRoundId, 1n)
  // Reservation and all three birth steps leave round 1 current until completion.
  assert.deepEqual(playRoundState(round(1n, 2), dead1, 1n), {
    settled: true, spawnFromRoundId: 1n, claimable: 100n,
  })
  for (const mode of [0, 1]) {
    assert.deepEqual(playRoundState(round(2n, mode, hook2), dead1, 1n), {
      settled: false, spawnFromRoundId: undefined, claimable: undefined,
    }, 'round 2 must never offer to spawn itself or use round 1 claims')
  }
  // Another detonation needs a new spawn, even if the old wallet read is slow.
  assert.deepEqual(playRoundState(round(2n, 2, hook2), dead1, 1n), {
    settled: true, spawnFromRoundId: 2n, claimable: undefined,
  })
})

test('settlement must belong to this round and hook, regardless of polling order', () => {
  assert.equal(playRoundState(round(1n, 1), dead1).settled, true)
  assert.equal(playRoundState(round(2n, 1, hook2), dead1).settled, false)
  assert.equal(playRoundState(round(1n, 1, hook2), dead1).settled, false)
  assert.equal(playRoundState(round(1n, 1), { ...dead1, checked: false }).settled, false)
  assert.equal(playRoundState(round(1n, 1), { ...dead1, mode: 1 }).settled, false)
})

test('claim amounts stay scoped to the settled round and its hook', () => {
  const current = round(2n, 3, hook2)
  assert.equal(playRoundState(current, dead1).claimable, undefined)
  const matching = { ...dead1, roundId: 2n, hook: hook2, claimable: 222n }
  assert.equal(playRoundState(current, matching).claimable, 222n)
  assert.equal(playRoundState(current, { ...matching, hook: hook1 }).claimable, undefined)
  assert.equal(playRoundState(current, { ...matching, hook: hook2.toUpperCase() }).claimable, 222n)
})

test('an RPC outage hides spawning until current-round reads recover', () => {
  const current = round(1n, 2)
  assert.equal(playRoundState({ ...current, readError: 'RPC unavailable' }, dead1).spawnFromRoundId, undefined)
  assert.equal(playRoundState(current, dead1).spawnFromRoundId, 1n)
})

test('loading, zero and unknown round state never offer a spawn', () => {
  for (const current of [round(0n, undefined), round(0n, 2), round(1n, undefined),
    round(1n, 0), round(1n, 1), { ...round(1n, 2), hook: undefined },
    { ...round(1n, 2), hook: '0x0000000000000000000000000000000000000000' }]) {
    assert.equal(playRoundState(current, idle).spawnFromRoundId, undefined)
  }
})
