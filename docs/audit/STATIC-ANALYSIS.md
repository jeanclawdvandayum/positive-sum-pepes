# Static analysis review — 2026-09-05

Latest source snapshot and triage:
[September 6 hardening review](2026-09-06-hardening/STATIC-ANALYSIS.md).
The inventory below remains the historical September 5 snapshot.

Fresh production-only compilation; no mixed historical build-info. Slither ran
102 detectors across 156 contracts and reported 234 findings: 9 High, 53 Medium,
60 Low, 110 Informational, 2 Optimization. These are detector classifications,
not confirmed exploit counts. The full inventory is `slither-findings.csv`.

The contract-source snapshot SHA-256 (sorted src/**/*.sol path, NUL, content) is:
`044015bd5b1cf380460b62472c6460a954e1098e8337d8ff33b6900eacbaeffd`.

## High classifications

| Detector | Count | Assessment |
|---|---:|---|
| reentrancy-balance | 6 | Reinvestor balance-before/after flows remain flagged. Both public compounding entry points now have the same OpenZeppelin nonReentrant guard; counterparties are immutable, and owner/operator and same-owner batch checks run before claims. Static flags are retained for human confirmation of callback assumptions. |
| weak-prng | 1 | False positive on `numerator % CREDIT_PRECISION != 0`: this checks whether a fixed-point division needs rounding up. No randomness is requested or consumed. |
| arbitrary-send-eth | 1 | ZapOut forwards only the ETH balance increase from the caller's redemption to that caller. This is its intended output. Local real-V4 zap tests check receipts indirectly through successful execution and balance deltas. External mixETH implementation remains an audit assumption. |
| uninitialized-state | 1 | Staker biasAdd is a legacy mapping that is never written and therefore always zero. Immediate stake weight is applied directly to the current point; adding it to this mapping would double-count. The public getter remains for compatibility. |

The fee rounding and permissionless top-up payout vulnerabilities (AUD-12/13)
were found through invariant testing and manual tracing, not these detectors.
They have dedicated regressions and source fixes.

The earlier unchecked-transfer finding at pooled launch was fixed with
SafeERC20.safeTransfer and is absent from this fresh report.

## Remaining detector families

- **Staker/factory reentrancy (11 Medium):** external fee sends precede some
  staker mutations; factory creation/wiring precedes final phase bookkeeping.
  All staker financial entry points and NFT transfers share an OpenZeppelin
  reentrancy guard. A fee-payout callback regression confirms that an approved
  operator cannot transfer the position mid-settlement. Current counterparties
  are the canonical non-callback PSP/mix tokens and
  immutable factory-created contracts/PoolManager. These assumptions must be
  checked on the release deployment. This pass does not establish safety for
  arbitrary callback-enabled replacement tokens or malicious pool managers.
- **Locked ETH (1 Medium):** ControllerDeployer forwards callvalue to CREATE /
  CREATE2. RoundController's nonpayable constructor rejects nonzero value and
  failed creation reverts the complete call; payable deploy methods do not
  intentionally retain user ETH. Forced ETH remains outside game accounting.
- **Equality, division, uninitialized locals and unused returns:** exact zero
  state-machine guards and Solidity's zero-initialized local scalars are used
  deliberately. Rounding-heavy arithmetic remains in human audit scope even
  where the numerical tests pass; no blanket suppression is applied.
- **Return-data, loops and gas:** calls into trusted deployment machinery and
  registry handling remain gas-sensitive. Detonation has a low-gas settlement
  path and staged birth; quote/inverse gas and epoch catch-up still need review
  on the intended chain. A failing optional next-round birth cannot prevent
  settlement through the capped path.
- **Low/informational:** time comparisons implement the clock, numerical
  constants implement fixed-point integration, and low-level/assembly routines
  implement V4/deployment plumbing. See the inventory rather than treating
  these categories as automatically harmless.

## Reproduce

### Reinvestment attribution follow-up

The AUD-14 snapshot has source SHA-256
`d5bc8f1c3358c638c606e6abf317239c55c40e5bfbcc4349dfebb6b863834276`.
A fresh isolated production build and the same 102-detector run still report
234 findings across 156 contracts, with no changes to the counts grouped by
detector, severity and confidence. The new inventory is
[slither-reinvest-attribution.csv](slither-reinvest-attribution.csv); the earlier
inventory remains the original snapshot.

Manual review of the changed path: `buyWithMixFor` pulls only its caller's
approved mixETH, sends PSP back to that caller, rejects a zero beneficiary,
and forwards the chosen beneficiary solely for existing hook attribution.
It cannot create referral edges or spend the beneficiary's allowance.
The reinvestor derives that beneficiary from the owned NFT, preserves owner/operator
authorization and nonReentrant on both entry points, and keeps the original
owner throughout batch restaking. Single/batch and owner/operator real-V4 tests
verify the resulting seats, events, referral payouts and owner pot claims.
The existing callback/token and immutable-counterparty assumptions above still
apply; unchanged detector counts are not a security proof.

Use a new, empty output/cache directory for each static-analysis snapshot:

```sh
forge build --build-info --ast --skip test --skip script --out /tmp/psp-audit-NEW --cache-path /tmp/psp-audit-cache-NEW
slither . --ignore-compile --foundry-out-directory /tmp/psp-audit-NEW --filter-paths 'lib/|test/|script/' --exclude-dependencies --json /tmp/psp-slither-NEW.json
```

Slither exits nonzero when it finds issues. This report is a triage handoff,
not a clean static-analysis gate or a substitute for independent review.
