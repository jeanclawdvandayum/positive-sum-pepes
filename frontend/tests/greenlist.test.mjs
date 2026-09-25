import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  buildGreenlist, greenLeaf, hashGreenPair, parseGreenlistCsv, parseGreenlistTree, verifyGreenProof,
} from '../src/lib/greenlist.ts'
import { normalizePredepositState } from '../src/lib/predeposit.ts'
import { predepositResult } from '../src/lib/chainResults.ts'

// Known-small vector, independently confirmed with `cast keccak` (foundry):
// leaves keccak(address-bytes); level-1 pair sorted by HASH order, not by
// address order (leaf(0x…10) < leaf(0x…02)); odd level duplicates its last
// leaf. This is exactly RoundController._greenlisted's walk.
const A02 = '0x0000000000000000000000000000000000000002'
const A10 = '0x0000000000000000000000000000000000000010'
const AAA = '0x00000000000000000000000000000000000000aa'
const LEAF02 = '0xd52688a8f926c816ca1e079067caba944f158e764817b83fc43594370ca9cf62'
const LEAF10 = '0x90b0d289ea211dca8e020c9cc8c5d6ba2f416fe15fa692b47184a4b946b2214d'
const LEAFAA = '0x528b55564e8518548e42b534da3a526179b820f264ee7c6929d00b0b6a31cfc2'
const PAIR_02_10 = '0xd98f2a859e681bfef210868e06d864923b6951b6f546a172f5ffcaff147fa8cb'
const PAIR_AA_AA = '0x12cc259a4ef33acfe9a28448a07cf2ba17b1cb214e6ef6d2411e992009d8aa3e'
const ROOT3 = '0xc2da9602d1c589a3654f7c98948e7dd4b8026c26afb19e3845907dc756b0ac96'

test('leaves are keccak of the 20 raw address bytes (the packed-abi.encodePacked leaf)', () => {
  assert.equal(greenLeaf(A02), LEAF02)
  assert.equal(greenLeaf(A10), LEAF10)
  assert.equal(greenLeaf(AAA.toUpperCase()), LEAFAA)
})

test('parents hash the sorted pair — hash order, not address order', () => {
  assert.equal(hashGreenPair(LEAF02, LEAF10), PAIR_02_10)
  assert.equal(hashGreenPair(LEAF10, LEAF02), PAIR_02_10)
})

test('a three-leaf csv tree reproduces the pinned cast-verified root and proofs', () => {
  const tree = buildGreenlist([A10, A02, AAA])
  assert.equal(tree.count, 3)
  assert.equal(tree.root, ROOT3)
  assert.deepEqual(tree.proofs[A02], [LEAF10, PAIR_AA_AA])
  assert.deepEqual(tree.proofs[A10], [LEAF02, PAIR_AA_AA])
  // the duplicated odd leaf proofs against itself at level 0
  assert.deepEqual(tree.proofs[AAA], [LEAFAA, PAIR_02_10])
  for (const member of [A02, A10, AAA]) assert.ok(verifyGreenProof(member, tree.proofs[member], ROOT3))
  assert.equal(verifyGreenProof('0x00000000000000000000000000000000000000ff', [LEAF02, PAIR_AA_AA], ROOT3), false)
})

test('single and two entry trees, and input order or case never change the root', () => {
  const one = buildGreenlist([A02])
  assert.equal(one.root, LEAF02)
  assert.deepEqual(one.proofs[A02], [])
  assert.equal(verifyGreenProof(A02, one.proofs[A02], one.root), true)
  const two = buildGreenlist([AAA, A02])
  assert.equal(two.root, hashGreenPair(LEAF02, LEAFAA))
  for (const shuffled of [[A02, A10, AAA], [AAA, A10, A02], [A10, AAA, A02]]) {
    assert.equal(buildGreenlist(shuffled).root, ROOT3)
  }
  assert.equal(buildGreenlist([A02.toUpperCase(), A10, AAA]).root, ROOT3)
})

test('odd levels duplicate the last leaf at every depth (5 → 3 → 2 → 1)', () => {
  const five = ['0x0000000000000000000000000000000000000001', A02, A10, AAA, '0x00000000000000000000000000000000000000ff']
  const tree = buildGreenlist(five)
  assert.equal(tree.count, 5)
  for (const member of five) assert.ok(verifyGreenProof(member, tree.proofs[member], tree.root))
  assert.equal(verifyGreenProof('0x0000000000000000000000000000000000000003', tree.proofs[A02], tree.root), false)
})

test('csv rows parse comments, commas, mixed case and 0X prefixes; garbage rows throw', () => {
  const csv = [
    '# greenlist for round 4',
    `${A02},whale`,
    '0X00000000000000000000000000000000000000AA',
    A10,
    A10.toUpperCase(),
    `${A02}   `,
  ].join('\n')
  assert.deepEqual(parseGreenlistCsv(csv), [A02, AAA, A10])
  assert.throws(() => parseGreenlistCsv('not,an,address'), /row 1 has no address/)
  assert.throws(() => parseGreenlistCsv(`${A02}\n0x1234`), /row 2 has no address/)
  assert.throws(() => buildGreenlist([]), /greenlist is empty/)
})

test('tree JSON round-trips through parseGreenlistTree; malformed files are refused', () => {
  const tree = buildGreenlist([A02, A10, AAA])
  const file = JSON.parse(JSON.stringify({ root: tree.root, count: tree.count, proofs: tree.proofs }))
  const parsed = parseGreenlistTree(file)
  assert.equal(parsed.root, ROOT3)
  assert.deepEqual(parsed.proofs[A10], tree.proofs[A10])
  assert.throws(() => parseGreenlistTree({ root: tree.root, count: 3 }), /missing proofs/)
  assert.throws(() => parseGreenlistTree({ root: '0x1234', count: 3, proofs: {} }), /missing root/)
  assert.throws(() => parseGreenlistTree({ root: tree.root, count: 3, proofs: { nope: [] } }), /bad address key/)
  assert.throws(() => parseGreenlistTree({ root: tree.root, count: 3, proofs: { [A02]: ['0x00'] } }), /bad proof/)
})

test('the 11-tuple state decodes with phase facts; the legacy 7-tuple keeps them undefined', () => {
  const v3 = normalizePredepositState([
    100n, 1000n, 2000n, false, false, false, false, 0n, 60n, 50n, 10n * 10n ** 18n,
  ])
  assert.equal(v3?.phase, 0)
  assert.equal(v3?.greenTotal, 60n)
  assert.equal(v3?.greenPerWallet, 50n)
  assert.equal(v3?.openPerWallet, 10n * 10n ** 18n)
  assert.equal(v3?.total, 100n)
  const legacy = normalizePredepositState([100n, 1000n, 2000n, false, false, false, true])
  assert.equal(legacy?.launchable, true)
  assert.equal(legacy?.phase, undefined)
  assert.equal(legacy?.greenPerWallet, undefined)
  assert.equal(normalizePredepositState([100n, 1000n, 2000n, false, false, false]), undefined)
  assert.equal(normalizePredepositState('nope'), undefined)
})

test('predeposits entries parse both eras off the one normalizer', () => {
  assert.deepEqual(predepositResult([70n, 20n, false]), { mixETHAmount: 70n, greenAmount: 20n, claimed: false })
  assert.deepEqual(predepositResult([70n, false]), { mixETHAmount: 70n, greenAmount: 0n, claimed: false })
  assert.throws(() => predepositResult([70n]), /Invalid predeposit response/)
})
