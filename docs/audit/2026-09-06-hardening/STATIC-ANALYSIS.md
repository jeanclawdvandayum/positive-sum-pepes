# Fresh static analysis — 2026-09-06

Source SHA-256 (sorted src/**/*.sol relative path, NUL, contents):
`7279ecbaa4cbf13648cc68faa3a1561fab50a4ef69cd54d9836a103224f75a4d`.

Slither 0.11.6, fresh production-only output, 158 contracts and 102 detectors:
242 flags: 10 High, 52 Medium, 63 Low, 115 Informational, 2 Optimization.
These are detector classifications, not confirmed vulnerability counts.
The complete inventory is slither-findings.csv. The prior AUD-14 inventory
contained 234 flags and predates the AUD-15 atomic referral implementation.
This comparison therefore covers both that implementation and this hardening.

## New or changed flags

- **arbitrary-send-erc20 (High, +1):** Registry.unlockCallback transfers from
  the decoded buyer. The buyer and full data hash are committed by the buyer's
  own nonReentrant buyWithMix call before entering the canonical PoolManager.
  Callback caller and hash must match, and the hash is consumed before token
  calls. External callbacks cannot choose another buyer using a standing
  allowance. ReferralPurchase tests exercise direct and purported-manager
  calls outside an active purchase and a malicious token's attempted reentry.
  No arbitrary-from exploit was confirmed for the canonical manager.
- **unused-return (+1):** Registry ignores manager.settle's amount; V4 must
  close all currency deltas before unlock completes. The transfer input and
  swap input are the same mixETH amount. A real fee-on-transfer/rebasing token
  still requires separate integration assessment.
- **calls-loop (+2):** Referral owner reads in depth-bounded chain walks. The
  maximum depth remains five. The owner-wide principal scan discovered manually
  was removed separately; these two flags do not represent that unbounded scan.
- **reentrancy-benign (+1):** The registry clears active callback context after
  unlock; the callback already consumed its purchase hash, and both registration
  and purchase entry points share nonReentrant. Staker reentrancy descriptions
  also now include owner-principal cache writes and the corrected view. Financial
  and transfer entry points remain guarded. Cache values are checked by an
  independent stateful model. Arbitrary callback-enabled token replacement is
  not assumed safe merely because the guard exists.
- **assembly (+1), too-many-digits (+4):** New registry error bubbling and
  canonical-key checks are classified by syntactic detectors. These do not by
  themselves establish vulnerabilities.
- **incorrect-equality (-1), uninitialized-local (-1):** Removing the enumerated
  owner total and correcting the epoch sentinel reduced these counts.

## Existing High families

The six reinvestor balance/reentrancy flags retain owner/operator restrictions,
single-owner batches, nonReentrant and balance-delta custody accounting. The
ETH send in ZapOut forwards the caller's own redemption delta. The weak-prng
flag is still fee-rounding remainder arithmetic, not randomness. biasAdd remains
an unwritten zero mapping retained for compatibility. Earlier detailed triage
is in ../STATIC-ANALYSIS.md; these flags remain visible for human review.

## ERC interface checks

slither-check-erc checked PSPToken against ERC20 and PSPStaker against ERC721
using the same isolated build. PSPToken's required method and event checks pass;
the checker also emits the usual allowance-overwrite race advisory. No change
to standard ERC20 approval semantics is made in this pass.

The position checker confirms missing safeTransferFrom overloads, approve,
getApproved and Approval event. The source-level balanceOf(0) and interface
advertisement differences are recorded in TOKEN-INTEGRATION.md. Completing
that public interface is awaiting the user's decision.

## Reproduction

```sh
forge build --build-info --ast --skip test --skip script \
  --out /tmp/psp-skills-production-20260906 \
  --cache-path /tmp/psp-skills-production-cache-20260906
slither . --ignore-compile \
  --foundry-out-directory /tmp/psp-skills-production-20260906 \
  --filter-paths 'lib/|test/|script/' --exclude-dependencies \
  --json /tmp/psp-skills-slither-20260906.json
slither-check-erc . PSPToken --erc ERC20 --ignore-compile \
  --foundry-out-directory /tmp/psp-skills-production-20260906
slither-check-erc . PSPStaker --erc ERC721 --ignore-compile \
  --foundry-out-directory /tmp/psp-skills-production-20260906
```

The host uses /tmp/psp-audit-venv/bin for the two Slither executables.
Slither completed successfully and exited 255 because it found flags;
it was not a clean static-analysis gate.
