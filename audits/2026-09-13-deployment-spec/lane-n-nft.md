# Lane N — NFT position & art collisions (deployment-spec)

Branch `deployment-spec` @ 6f18dbd7 (base `testnet-final` @ a6ab573f-era lineage).
Scope: `src/PSPStaker.sol`, `src/libraries/PepeDna.sol`, `src/RoundController.sol`,
`src/art/ExpandedPepeArt.sol`, `src/PepeExpandedDescriptor.sol`, `docs/art/EXPANDED.md`,
`docs/audit/2026-09-08-reserved-predeposit-art.md`. No changes made to `src/` or `test/`.

Method: full manual walk of every mint/reserve/claim path and both run-boundary
structures; codec-equivalence proof between `PepeDna.key` and both descriptors'
`decode`; v1↔v2 nibble arithmetic for the misdeployment case; confirmation run of
the existing reserved-art suites (`forge test --match-contract
"ChosenPredepositPepe|ExpandedPepeArt"` → 23 passed / 0 failed, includes
`test_ReservationCollisionRollsBackFundsAndDeposit`,
`test_ChosenMaxIdAndBothDoubleClaimRoutes`, `test_TraitAliasRevertsWithoutConsumingClaim`,
`test_DepositReservesExactArtAndOldClaimMintsItAfterDetonation`).

Art-space facts used throughout: v1 counts 10/10/10/10/10/10/10/10 → 100,000,000
combinations (`testnet-final:src/PepeArtData.sol:16-23`); v2 counts
12/11/11/12/11/10/10/10 → 191,664,000 (`src/art/ExpandedPepeArt.sol:8-15`;
product re-verified by hand). Both descriptors decode with the identical fold
`((dna >> 4i) & 15) % COUNT_i` (`src/PepeExpandedDescriptor.sol:51-60`,
`src/PepeDescriptor.sol:48-56`) and `PepeDna.key` uses the same fold per version
(`src/libraries/PepeDna.sol:34-42`) — so **key equality ⇔ identical rendered
trait tuple** holds for both versions, matched pairwise.

---

## Findings

### N-1 [Medium] — v2 descriptor set on a v1-only factory mints visually duplicate Pepes (silent, permanent)

- **Where:** `src/PSPFactory.sol:85-87` (`setDescriptor`, owner-only, no version
  cross-check), `src/PSPFactory.sol:71` (`stakerDeployer` immutable),
  `testnet-final:src/PSPStaker.sol` (`PEPE_DNA_VERSION = 1` constant, exhaustion
  at `PepeDna.COMBINATIONS` = 10^8). Guarded only procedurally by
  `docs/art/EXPANDED.md:35-37` ("Deploy a fresh factory … Do not set this
  descriptor on a previously deployed factory that still embeds the
  version-1-only staker").
- **Concrete failure mode** (this verifies the docs' "collision codec would
  disagree with the renderer" claim): a pre-upgrade factory's
  `StakerDeployer` vessel permanently embeds the old `PSPStaker` creation code —
  it has no `ART_VERSION()` probe (`src/PSPStaker.sol:210-214` exists only in
  the new code), hardcodes version 1, and enforces key uniqueness with the v1
  fold (every axis `% 10`). The v2 descriptor renders with
  `% (12,11,11,12,11,10,10,10)`. On the five widened axes the two folds
  disagree:
  - expr (12) and wear (12): nibble pairs `{f, f+12}`, f ∈ {0,1,2,3};
  - eyes / hat / item (11): pairs `{f, f+11}`, f ∈ {0..4}.

  For such a pair, v2 residues are **equal** (identical SVG bytes and identical
  attribute list) while v1 residues **differ** (different keys → both mints
  pass `_reserveArt`'s `PepeDnaTaken` check). Result: two minted NFTs with
  byte-identical rendered art in the same round — the round's core "every trait
  combination is unique" invariant breaks silently and irreversibly.
- **PoC sketch:** deploy the testnet-final factory tree; `setDescriptor(v2
  descriptor)`. Off-chain, meet-in-middle grind two candidate ids A, B such
  that `keccak(A)` and `keccak(B)` agree on 7 of 8 nibbles and differ by
  exactly 12 on the expr nibble (work ≈ 2^30 hashes, minutes on a laptop; the
  alias-set formulation needs only ≈ 2^24 hashes per collision when targeting
  an already-known victim dna). `lockWithPepe(0, A)` then `lockWithPepe(0, B)`
  both succeed; `tokenURI(A)` and `tokenURI(B)` return identical images and
  attributes. The same disagreement also makes `isPepeAvailable` (v1 keys)
  disagree with any v2-aware UI (spurious `PepeDnaTaken` reverts and
  false-available previews), and caps the fallback art frontier at 100M of the
  191,664,000-slot space (`PepeArtExhausted` at half capacity).
- **What does NOT break:** `tokenURI` never reverts (decode clamps every axis),
  `fromKey` fallback DNAs (nibbles < 10) render identically under both folds,
  and mid-spawn descriptor swaps fail closed via `contextHash` staleness
  (`ReservationStale`, `src/PSPFactory.sol:392,416,486`). The exposure is
  exactly: owner calls `setDescriptor` on the old (Sept 9, 2026) factory.
- **Assessment:** Medium — privileged misconfiguration, but silent, permanent,
  market-integrity impact (duplicate "unique" NFTs), and the only enforcement
  is a docs sentence. The new-staker constructor probe fixes this for fresh
  factories only. Residual recommendations (no code changed per lane rules):
  keep the Sept-9 factory's descriptor untouched for its remaining life; if an
  art upgrade on an old factory is ever contemplated, deploy a new factory
  instead; consider adding a one-line `ART_VERSION` expectations note to the
  runbook for `setDescriptor`.

### N-2 [Informational] — chosen-id deposit front-run (grief only, fully retryable)

`predepositWithPepe` (`src/RoundController.sol:294-302`) reserves only after the
funded transfer; an attacker front-running the victim's mempool tx can occupy
the target first — either directly via `lockWithPepe(0, victimId)` or, more
insidiously, by grinding an alias id (≈ 2^24 keccaks, see N-1 arithmetic) whose
hash shares the victim's v2 key and minting that. The victim's whole deposit
then reverts atomically (`BadPepeId` / `PepeDnaTaken`; rollback proven by
`test_ReservationCollisionRollsBackFundsAndDeposit` and
`test_TraitFailureRollsBackEveryWrittenAccountingSlot`). No funds lost, no state
consumed; victim retries with a different id. Attacker cost: one tx (+ optional
grind CPU). Documented acceptance: "not Sybil-resistant art allocation"
(`docs/audit/2026-09-08-reserved-predeposit-art.md:14-15`). No action needed.

### N-3 [Informational] — stranded reservations: art-space grief quantified as negligible

A deposit-without-claim strands exactly one id + one art key per funded wallet
(selection lock `src/RoundController.sol:295-296` → one reservation per address
per round). Cost per stranded slot: one wallet + ≥1 wei mixETH (PD-1 accepts
any positive amount; mainnet wallet cap off) + one ~150k-gas tx. The deposit
itself is never stranded — claims stay open forever, including post-detonation
(`test_ChosenClaimStillWorksAfterDetonation`). Burned keys do not tighten
other users' mints: preferred-path keys (keccak-derived) are ~uniform over
191,664,000 slots, and forcing the fallback frontier (`_nextArtKey`) past
`_artCombinations` requires a contiguous occupied run spanning essentially the
whole space. To strand even 1% of the space (~1.9M slots) costs ~1.9M txs of
gas for 1/100th of a cosmetic namespace. Ratio is astronomically unfavorable
to the attacker; unclaimed shares also keep earning inside the genesis
position for later claim, so no externalized cost. No action needed.

---

## Hunt-by-hunt results

**1. Two NFTs with the same rendered art (same normalized tuple)?** No — within
a matched-codec round this is impossible. (a) Codec equivalence: both
descriptors' `decode` applies the same per-axis `% COUNT` fold as
`PepeDna.key`, so identical keys ⇔ identical rendered tuples for v1 and v2
pairwise. (b) Single-assignment: `_artToken[artKey]` is written only in
`_reserveArt` (`src/PSPStaker.sol:296`) behind `!= 0 → PepeDnaTaken`, and is
never deleted anywhere (delete audit: only `_tokenApproval`, `positions`,
`isWithdrawing`, `reservedPepeOwner` are ever deleted — `PSPStaker.sol:384,723,724,842`).
(c) Every ownership-granting path passes `_reserveArt` first: `_mint`
(`:310-315`) always; the reserved-claim fast path (`:841-843`) skips it but
reuses the marker written at deposit time with the same id and the same
`_hashDna(id)`. (d) Run-boundary walk: `_reserveArt`/`_reserveId` implement a
maximal-run interval union — reads happen only at `q±1` of a free slot, which
are necessarily run endpoints with fresh boundary values; writes land on the
new endpoints. Boundary cases hold: `artKey == 1` (left check skipped —
`_artToken[0]` is structurally zero since `key() ≥ 1`), `artKey ==
_artCombinations` (right check skipped), reserve-after-mint adjacency (merge
consumes both neighbors' fresh endpoints), double-reserve (second hits
`BadPepeId` at `:280` or `PepeDnaTaken` at `:288`; controller-only, no external
calls inside, `nonReentrant` upstack). Transfers touch only ownership/
enumeration (`_transfer`, `:377-402`); withdrawals delete `positions` but
never art state — art survives transfer and withdrawal by design. The only
duplicate-art channel is the N-1 codec mismatch across deployment eras.

**2. Reservation theft/front-run/consumption?** No. `reserveGenesisPepe` is
controller-only (`:278`) and the controller's only caller path is
`predepositWithPepe`, which reserves for `msg.sender` (`RoundController.sol:299`);
`predepositFor` never reserves. The claim chain passes the claimant as `user`
end-to-end (`RoundController.sol:557-558` → `_claimGenesisShare`). Enumerating
who can mint into a reserved id: `lock`/`lockWithPepe` → `_mint` reverts
`BadPepeId` on any reservation (`:311`); auto genesis claim explicitly skips
reserved ids (`:839`); another depositor's chosen claim with your id falls to
`_mint` and reverts the same way (`chosen && reservedPepeOwner[id] == user`
fails → else-branch). The only successful mint of a reserved id requires
`reservedPepeOwner[id] == claimant` (`:841`). Front-running is possible but is
a retryable grief (N-2).

**3. `_nextArtKey` / `nextTokenId` pointing at an occupied slot?** Proven
impossible. Every occupancy of key/id `q` flows through `_reserveArt` /
`_reserveId`, each of which advances the pointer exactly when `q == pointer`
to `runEnd + 1` (`:295`, `:307`). `runEnd` is the end of a maximal occupied
run, so `runEnd + 1` is free; when `q ≠ pointer` the pointer's slot stays
free. Hence "reserve exactly at `_nextArtKey`, then contiguous reserves" ends
with the pointer resting just past the merged run — never on an occupied slot,
never requiring a scan. Exhaustion is a legitimate terminal state
(`_nextArtKey > _artCombinations` reverts only the fallback leg of
`_availableDna`, `:269-273`; preferred-free mints still succeed), reachable
only after ~191.66M occupations in one round. `nextTokenId` shares the
structure over id-space; the `type(uint256).max` overflow arm is unreachable
(it would first require a contiguous 1..2^256−1 run). No `BadPepeId`/`
PepeArtExhausted` DoS exists.

**4. Chosen-claim fallback states.** (i) id unreserved, unminted → `_mint` →
art reserved now (`PepeDnaTaken` reverts whole claim atomically; `dep.claimed`
flips in the same tx and rolls back with it — retryable, proven by
`test_TakenSelectionLeavesClaimRetryable`). (ii) id reserved by another →
`_mint` → `BadPepeId` at `:311`. (iii) id reserved by me → `delete
reservedPepeOwner[id]` + `_finishMint` (`:842-843`), reusing the deposit-time
art marker — no re-reserve, no gap in the id-run (reserved→owned is a
same-slot transition). Double-consumption is closed three ways: controller
`dep.claimed` (`RoundController.sol:539,552`, same-tx atomic), controller
selection lock forces `pepeId = reserved` on every claim route
(`:532-537`, override attempt reverts `PredepositClosed`), and staker-side
`_ownerOf[pepeId] != 0 → BadPepeId` (`:833`). "Reserved-by-me-deleted" is
reachable only through a successful mint, after which the id is simply owned.
Post-claim top-ups cannot re-reserve (`selected != 0` branch,
`RoundController.sol:298`). No state double-consumes a reservation.

**5.** See N-3.

**6.** See N-1 (the docs' claim is verified with exact nibble arithmetic; the
new-staker constructor probe at `src/PSPStaker.sol:210-214` closes it for new
factories; `stakerDeployer` immutability means old factories can never be
fixed in place — the docs' "fresh factory" rule is the only correct
procedure).

---

## Refuted hypotheses (explicit)

- **R1 — stale interior boundaries corrupt merges / `_nextArtKey` lands
  occupied:** interior boundary entries are stale by design and never read —
  reads occur only at `q±1` of a free slot, i.e. at maximal-run endpoints.
- **R2 — `nextTokenId` can be pushed onto an occupied id or overflow at
  `uint256.max`:** same guard-invariant as R1; overflow needs a contiguous
  2^256 run.
- **R3 — reservation stolen via `claimGenesisShareWithPepe` by a non-owner:**
  user is bound to `msg.sender` through both hops; mismatch falls into `_mint`
  which reverts on any reservation.
- **R4 — claim a reservation twice (delete then re-claim):** `dep.claimed` +
  selection lock + `_ownerOf` check (Hunt 4iii analysis).
- **R5 — duplicate rendered art within a matched-codec round via any
  reserve/claim/auto/transfer/withdraw ordering:** single-writer,
  never-deleted `_artToken`; codec equivalence (Hunt 1).
- **R6 — false `PepeArtExhausted` blocking valid mints:** preferred-key check
  precedes the frontier check; the revert fires only for fallback allocation
  in genuine exhaustion.
- **R7 — auto-claim minting into a wallet-address id reserved by someone
  else:** explicit `reservedPepeOwner[id] != address(0)` skip at
  `src/PSPStaker.sol:839` (added this branch).
- **R8 — reentrancy via the predeposit transfer sandwiching the reservation:**
  `nonReentrant` on both layers; reservation involves no external calls;
  mixETH is the known plain ERC20 (matches the repo-wide CEI note).

Cosmetic note (no action): metadata `name` is `"Positive Sum Pepe #<dna>"` —
the DNA integer, not the tokenId (`src/PepeExpandedDescriptor.sol:114-115`);
consistent and collision-free within a round, but auto-minted ids display a
78-digit number.

---

## Verdict

The reservation lattice is sound: within a correctly deployed round, art
uniqueness reduces to single-assignment of `_artToken` keys plus exact codec
agreement between `PepeDna.key` and both descriptors' decode folds, the
run-boundary structures provably keep both allocation frontiers on free slots
in O(1), reservations can be created, held, and consumed only by the funding
depositor with all failure modes rolling back atomically (test-proven), and
the plausible griefs (front-run races, stranded-slot art exhaustion) are
retryable or quantitatively negligible. The one real exposure is deployment
procedure, not code: `PSPFactory.setDescriptor` will happily pair a v2
renderer with an old factory's immutably embedded v1-only staker, after which
duplicate-looking Pepes are mintable and undiscoverable on-chain (N-1, Medium)
— the docs' "fresh factory" rule is currently the only enforcement, so the
Sept 9 Base Sepolia factory's descriptor must simply never be touched, and
every future art-version bump should ship with a new factory as EXPANDED.md
already mandates.
