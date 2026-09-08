# Predeposit art selection: differential security review

## Executive summary

Reviewed `8d10592a` against parent `27e500d5`, including the claim path,
its accounting dependencies and the frontend integration. Three independent
reviews covered authorization/collisions, accounting and UI behavior, followed
by root review and regression testing.

| Severity | Confirmed issues | Remaining after fixes |
|---|---:|---:|
| Critical | 0 | 0 |
| High | 0 | 0 |
| Medium | 0 | 0 |
| Low (UI correctness) | 2 | 0 |

No new fund-loss, authorization, duplicate-art or accounting vulnerability was
identified. Both confirmed UI issues were fixed. Recommendation: the reviewed
change is suitable for testnet deployment with the documented limitations below.
This is a focused differential review, not a full-protocol audit.

## What changed and scope

One commit, 10 changed files, 243 additions and 15 deletions. All changed files
were examined. The contract path received the deepest review.

| Files | Change | Review priority |
|---|---|---|
| `src/RoundController.sol` | New chosen claim and shared claim implementation | High |
| `src/PSPStaker.sol` | Chosen genesis NFT and shared accounting | High |
| `frontend/src/pages/Stake.tsx` | Feature detection, claim picker and submission | Medium |
| `frontend/src/components/PepePicker.tsx` | Pending controls and action wording | Medium |
| `frontend/src/lib/abi.ts`, `transactionToasts.ts` | New selector and label | Low |
| `test/ChosenPredepositPepe.t.sol` | Claim regression coverage | Verification |
| `GATE-LOG.md`, `READINESS.md`, chosen-art design note | Deployment/behavior statements | Documentation |

The uncommitted wallet-menu configuration was excluded from this change review.

## Findings and corrections

### LOW-1: duplicate picker could imply the wrong art for ordinary staking

Original location: `frontend/src/pages/Stake.tsx:512-517` in `8d10592a`.

The genesis picker was also inserted inside the ordinary staking form. That
picker changed `genesisPepe`, while the nearby staking button submitted
`pickedId`. A user selecting a face immediately above that button could mint a
different face. Both NFTs and funds still belonged to the user, but the art
selection did not express the transaction being signed.

Fix: removed the duplicate from the ordinary staking form. The dedicated claim
card owns the genesis selection; ordinary staking keeps its own existing picker.
Blast radius: one ordinary-staking form, both `lock` and `lockWithPepe` paths.

### LOW-2: asynchronous claim results could modify a later wallet/round session

Original location: `frontend/src/pages/Stake.tsx:350-358` in `8d10592a`.

A claim submitted for account/round A could complete after account/round B had
loaded. The optimistic state update would then mark B's currently displayed
deposit claimed until the next poll. Likewise, A's delayed availability failure
could clear B's new selection. This affected display state, not on-chain claims.

Fix: bind availability responses, receipt updates, errors and delayed status
resets to the initiating account/controller pair. Reset pending display state
when that pair changes. Wallet identity and chain are separately checked by the
existing confirmed-write helper before signing.
Blast radius: one claim handler, selected and random branches.

## Contract analysis and attacker model

Attackers considered: arbitrary callers, legitimate predepositors attempting a
second claim, other NFT minters racing a selection, and payout failure/reentry
at the external fee-transfer boundary.

- `RoundController.sol:522`: deposits are always indexed by `msg.sender`.
  Both public claim routes share the original amount calculation and claimed
  flag. A new ID cannot alter the claimant or proportional allocation.
- `PSPStaker.sol:779`: the shared handler still requires its immutable controller.
  Both external staker entry points retain `nonReentrant`; both controller
  entry points retain their guard too.
- `PSPStaker.sol:798`: chosen IDs reject zero and existing NFTs. ID zero is the
  virtual genesis position. Existing husks remain owned, so withdrawal never
  permits overwriting their fees or identity.
- `_mint` retains permanent canonical trait reservations through `PepeDna.key`.
  Different hashes with equal rendered traits are rejected. Selected art never
  silently changes to collision fallback art.
- Genesis whole fees, fractional remainder, principal, checkpoints and owner
  totals use the exact same accounting for selected and random claims.
- All NFT/accounting effects precede the external `sendFees` call. Existing
  deferred payout preserves an unpaid fee balance on the minted NFT.
- Failed ID/trait validation reverts the entire cross-contract call, including
  the controller claimed flag and private fractional fee carry.
- Post-detonation claims and immediate principal withdrawal still work.

A public minter can race a chosen face using existing `lockWithPepe(0, id)`.
The losing claim pays gas for a revert but retains its allocation and fees.
This is an explicitly documented first-confirmed selection model. A depositor
can select again or use the existing random claim.

## Blast radius

Counts below are direct production callers, excluding tests, ABI declarations
and comments.

| Changed/shared function | Direct callers | Propagation |
|---|---:|---|
| Controller `_claimPredepositPSP` | 2 public claim wrappers | Every pooled allocation claim |
| Staker `claimGenesisShareWithPepe` | 1 controller call site | Chosen claim only |
| Staker `_claimGenesisShare` | 2 external wrappers | Random and chosen claims |
| Staker `_mint` (unchanged) | 3 staker call sites | Chosen stake, automatic stake, genesis claim |
| UI chosen claim submission | 1 Stake handler | Current-round claim card |

## Historical context

Baseline blame checked the code moved into the shared handlers. The
controller-only boundary and depositor claim flag predate this change. Fee
accrual and fractional-carry hardening from `ed7143e41` remain in the shared
path. Permanent uniqueness from `13e28396` and round-seeded random art from
`8805c023` remain intact. No prior validation or reentrancy defense was removed.

## Test coverage

Existing nine chosen-claim tests included exact preview DNA (256 fuzz cases),
ID/trait collisions, retryability, authorization, fee/principal equivalence and
post-detonation claims. This review adds four cases:

1. Maximum uint256 chosen ID and both routes after an already-successful claim.
2. A pre-launch chosen claim that leaves the deposit usable after launch.
3. Forced fee payout failure, successful later recovery and rejection of a
   second payout.
4. Trait-collision rollback comparing every recorded controller/staker storage
   write against the pre-call snapshot, including private fractional carry.

The first payout test iteration expected a second zero-fee call to succeed;
review confirmed the established `NothingToClaim` behavior and corrected that
expectation. This was a test expectation error, not a contract defect.

Final deterministic gate: 527 contract tests across 69 suites, 160 frontend
tests, 11 verifier tests, 157 ABI declarations, 36 production size checks,
oracle/governance checks and the production build all passed. Results are also
recorded in `GATE-LOG.md`.

## Limits and remaining product behavior

- These source changes have not been deployed. Existing deployed contracts
  retain the old entry points and behavior.
- The Graveyard UI currently offers the original random-art claim. The new
  contract selector works after detonation, but selecting art through the UI
  after a successor becomes current remains a separate UI extension.
- Review used local code, source history and deterministic tests. It did not
  sign real-wallet transactions or deploy the contracts.
- No new malicious payout-callback test was added specifically for the chosen
  wrapper. Existing callback coverage and review of its shared guarded path
  informed the assessment; failed payout now has direct new-wrapper coverage.
