# Pepe safe transfers and individual approvals — September 6, 2026

The user approved the previously deferred NFT interface proposal. This change is
implemented in source and the local frontend. Existing deployed contracts are
immutable; a fresh factory with the new deployers and a second-pass reinvestor
is required. Existing NFTs are not migrated by this change.

## Resulting permissions and transfers

PSPStaker now implements both safeTransferFrom overloads, approve, getApproved
and Approval. It advertises ERC-165, ERC-721 and metadata support, rejects
balanceOf(address(0)), and returns an empty URI for an existing NFT when the
round deliberately has no descriptor. Unknown token IDs still revert.
NFT IDs, art selection and the no-burn lifetime are unchanged.

An individual approval permits transferring that Pepe and claiming its fees.
Only its owner or an approved-for-all operator can grant or replace that
approval; an individually approved account cannot delegate it. Zero revokes.
Every transfer, including a self-transfer, clears the individual approval.
Collection approvals belong to the owner and remain a separate permission.
Withdrawal requests, cancellation and principal withdrawal remain owner-only.

Both safe transfer entry points use the installed OpenZeppelin ERC721Utils
receiver check. Ownership, enumeration, owner principal totals and approval
clearing finish before the callback. A rejection or wrong magic value reverts
all changes; receiver revert data bubbles up. The transfer holds the staker's
shared reentrancy guard through the callback. A receiver that tries to perform
a nested transfer or financial staking action must defer that action until
after receipt. Ordinary approval operations can still run in a receiver callback.
Plain transferFrom remains available and does not check receiver acceptance.
Mints retain their existing behavior; this is not a safe-mint or burn change.

PSPReinvestor accepts an individually approved caller as well as the owner or a
collection operator. Every NFT in a batch must have the same owner, and caller
authorization is checked for each ID before fees are claimed. Approving the
wrapper itself never authorizes arbitrary external callers. Because ERC-721 has
one individual approval slot, separately approving both the wrapper and another
caller requires one of them to have collection permission; owner-initiated
reinvestment needs only the wrapper's individual approval.

## Frontend behavior

- Single reinvestment approves that Pepe on upgraded rounds. Batch reinvestment
  approves each included Pepe that needs permission. Existing collection
  approval remains usable. Legacy rounds explicitly identify their existing
  collection-approval requirement. Failed capability reads disable the action;
  they do not silently widen its permission scope.
- Approval preparation rereads NFT ownership and permission, checks wallet,
  network and round changes between prompts, and verifies previous approvals
  again before the buy. Each approval uses simulation and confirmed receipts.
- Each stake position has a manage-pepe disclosure: safe transfer, a full
  recipient-address review, individual approval revocation, and revocation of
  the configured reinvestor's collection permission. It explains that principal,
  earned fees and the withdrawal timer travel with the NFT. Revoking one
  permission does not revoke the other.
- NFT management verifies the selected factory round and its staker independently
  of current trading rules. This exception only allows safe transfers and
  revocations, never approvals that grant access or trading actions. New grants
  still verify the current round and configured reinvestor.
- Legacy stakers advertised ERC-721 despite missing methods. The UI therefore
  checks metadata support plus the new NFT_INTERFACE_VERSION marker instead of
  trusting the old ERC-721 bit. Legacy safe-transfer controls stay unavailable.

## Validation

`bash scripts/check-audit.sh` passed with **450 Solidity tests / 61 suites**,
**77 frontend tests**, **119 ABI declarations**, **32 production size checks**,
independent oracle reproducibility, the governance gate, TypeScript and Vite.
Final capability-state refinements and fixture cleanup were followed by
another successful 77-test frontend run and TypeScript/Vite build. Existing wallet bundle-size warnings remain.

Thirteen Solidity tests were added: receiver acceptance/data, malformed/missing
receivers, rejection rollback, reentrancy, permission escalation, replacement and
revocation, transfer-held fees and vesting, owner-attributed reinvestment, batch
permission isolation, and interface validation. The transfer sequence fuzz runs
256 cases of 32 operations and independently tracks owners, enumerations and
principal, including self-transfers. Existing real-V4 accounting and complete-exit
invariants also pass. Nine frontend tests cover address validation, narrow and
legacy approvals, interrupted sessions, failed receipts, ownership changes,
revocation during a batch and the scoped management exception.

The initial gate found a test setup error: requestWithdraw already pays accrued
fees. The transfer test now requests withdrawal first, generates new trading
fees, transfers the NFT and verifies the recipient's actual payment. An old
combined-birth canary also crossed its 12.5M assumption. It still records combined
costs (12,623,711 / 12,616,411 gas), restores the same reservation, and verifies the
actual three-step path under the existing stricter 12M limit per transaction:
6,155,471 / 6,276,997 / 189,213 gas (round three wiring: 181,913). No production
gas limit was raised. Real-V4 staged-birth tests independently remain green.

Browser review used an isolated local fixture with simulated wallet data to
inspect the actual new component, its full-address transfer review and legacy
notice at a narrow card width. The rebuilt stake page also loaded against the
current testnet. No live wallet approval, transfer, deployment or signature was
performed. Temporary fixture files and its server were removed afterward.

## Static analysis and deployment sizes

Production-only build with solc 0.8.26, via-IR, optimizer 200, Cancun; Slither
0.11.6 ran 102 detectors over 160 contracts. Its ERC-721 checker now passes all
listed functions, events, return types and indexing; see [erc721-check.txt](erc721-check.txt).
This interface check is not a behavioral proof.

The detector inventory is **243 flags**: 10 High / 52 Medium / 64 Low /
115 Informational / 2 Optimization. Compared with the prior hardening snapshot,
there is one additional low calls-loop flag: per-NFT authorization in
reinvestAll reads the immutable staker inside a batch capped at 64 IDs. This is
intentional bounded validation, not an unbounded or user-selected callback.
Existing high/medium flags retain their prior [manual triage](../2026-09-06-hardening/STATIC-ANALYSIS.md).
No new exploitable issue was confirmed in the changed surface. Full inventory:
[slither-findings.csv](slither-findings.csv).

| Contract | Runtime bytes | Initcode bytes |
| --- | ---: | ---: |
| PSPStaker | 13,133 | 13,494 |
| StakerDeployer | 14,352 | 14,378 |
| PSPReinvestor | 4,786 | 5,518 |
| ControllerDeployer | 22,622 | 22,648 |
| CurveHook | 23,243 | 24,829 |
| PSPFactory | 20,442 | 27,384 |

Source SHA-256, sorted src/**/*.sol paths + NUL + file contents:
`8f27c8742190b1a86456e62fd1f5a373dd2b7ef26c2d71214530056e4b5d44a9`.

Human review should focus on permission composition, callback compatibility,
fee/principal conservation across transfers, and wallet/marketplace integrations.
This pass does not replace a human audit or certify production mixETH behavior.
