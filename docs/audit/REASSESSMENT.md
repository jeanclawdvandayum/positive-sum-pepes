# Status after approved follow-up implementation

RS-1, RS-2 and RS-5 now have fixes and regressions. RS-3 has measured economic
scenarios; RS-4 now includes a three-wallet, multiposition real-V4 campaign
(256 runs / 32,768 calls / zero reverts), ending every campaign with full exits.
RS-6 release evidence is in READINESS.md and TESTNET-PLAYTEST.md. The assessment
below is the historical rationale for this work; its unfixed-status statements
are superseded by the current readiness packet.

# Reassessment after the September 5 hardening pass

PSP is a materially stronger testnet alpha. The source is ready for a controlled
Base Sepolia deployment with pinned, tested settings and for preliminary human
audit scoping. I would resolve the issues below before freezing a final audit
revision. No contracts were changed or deployed during this reassessment.

The last complete baseline is 384 Solidity tests across 53 suites, 9 frontend
tests, 90 independent oracle vectors, 102 ABI declarations and 32 production
artifact size checks. The current contract-source hash matches the final static
analysis snapshot. The full suite was not rerun for this assessment; a separate
focused curve-domain probe was run and confirmed RS-2 below. The probe is not
included in the reported 384-test baseline.

Real improvements include explicit purchase budgets, multiple seats per buy,
4:20 clock increments, actual protection against permissionless top-up fee theft,
conservative fee budgeting, bounded-gas settlement, bracketed curve inversion,
continuous wave endpoints, confirmed wallet writes and recovery of old-round
assets through the interface. The numerical oracle and expanded solvency
invariant caught real defects, giving stronger evidence than a larger test count
alone. See READINESS.md for the complete findings matrix.

| Area | Assessment |
|---|---|
| Game rules | More coherent; entry budget no longer depends on PSP unit price. Larger purchases have an explicit ladder benefit up to ten seats. |
| Contract security | Substantial improvement; the identified payout and conservation defects have regressions. Unknown defects and external-token assumptions remain. |
| Testing | Good deterministic foundation; combined multi-wallet/multi-position stateful coverage is still thin. |
| Testnet release | Updated source has not been freshly deployed/verified. Old deployments retain old behavior and defects. |
| Human audit | Suitable for scoping and early review. Fee semantics and accepted parameter bounds should be settled before a final source freeze. |

1. **RS-1 — claim timing can reduce already-accrued fees during withdrawal.**
   PSPStaker._liveCredit (src/PSPStaker.sol:342) multiplies the entire accumulator
   increase since the last claim by the position's current weight. A withdrawing
   position that waits loses some credit earned at earlier, higher weights.
   test/unit/FeeImmediacy.t.sol:293 explicitly expects unclaimed credit to be zero
   after the six-epoch vest finishes. This is an existing documented behavior,
   not a newly demonstrated unauthorized theft. I would preserve earned fees
   and apply decaying weight only to future fees. At minimum, the product must
   explain the claim-timing consequence explicitly; “fully unlocked” is not
   enough to communicate it.

2. **RS-2 — confirmed gap in custom sine-parameter validation.**
   With p0=1e13, preK=4_605_170_185_988_092, pTarget=0.06e18,
   targetReserve=1e40 and ampBps=10000, validate succeeds. Materializing at
   boot=90e18 produces slope=0 and g=1e18; supplyAt(boot+0.005e18) reverts because
   the geometric endpoint denominator is zero. A separate Foundry probe passed
   assertions reproducing all three steps. Factory.configureSine is owner-only,
   so this is an accepted-configuration/liveness defect; it is not evidence that
   an ordinary trader can break the tested default curve. Enforce a supported
   parameter domain and validate derived slope, growth, supply and precision
   at the supported launch extremes. Stored probe: probes/CustomCurveValidation.t.sol.

3. **RS-3 — game economics still need adversarial playtesting.**
   A 0.05 mixETH buy occupies all ten seats and adds at most 43m20s. The buyer's
   principal remains redeemable/sellable under the applicable rules; gross spend
   is not the irreversible cost of taking the board. Traders can also recover
   some fees through their staking share, referrals and eventual pot winnings.
   This does not contradict allowing fee-paying round trips. It means that
   fee turnover alone does not demonstrate healthy distribution among players.
   Assess net fee flows per participant, board concentration, gross volume versus
   new deposits, organic clock expiries, and profitability after rewards and gas.
   One 0.005 purchase unit every 260 seconds balances the clock's passage of time
   when no extension is wasted at the cap: roughly 1.662 mixETH gross buys/day.
   This is arithmetic, not a claim that sustaining the clock costs that amount
   or that an isolated operator can guarantee winnings. Transaction ordering is
   a known source of [MEV](https://ethereum.org/developers/docs/mev/); PSP-specific
   profitability must be measured rather than assumed.

4. **RS-4 — broader stateful scenarios are the highest-value testing addition.**
   The current real-V4 handler selects buy/sell/advance/settle/redeem, using one
   funded trading identity and a simple virtual genesis stake. Its 2,048 calls
   include guarded no-ops and are not 2,048 independent successful swaps. Add
   multiple holders and positions, stake/top-up/request/cancel/withdraw, NFT and
   operator changes, claims and reinvestment across rounds. Track all unpaid
   obligations and finish campaigns by attempting to exit every position.
   Separate valid-action and intentionally invalid-action campaigns help test
   both liveness and atomic rejection. This follows the handler/ghost-state
   approach described by [Foundry](https://getfoundry.sh/forge/invariant-testing).

5. **RS-5 — asset exits are unnecessarily coupled to current-round compatibility.**
   frontend/src/lib/useConfirmedWrite.ts:18 checks the CURRENT round's rule
   getters before every write, including old-round claims and redemption. An
   incompatible or unreadable current round blocks those exits through this UI
   even when the old target contract is callable. The contracts' withdrawal
   rights are unchanged. Keep compatibility checks for new buys/deposits, and
   validate exit actions against their own target round so legacy funds remain
   accessible. Wallet-driven tests should cover this alongside rejection,
   cancellation, account/chain changes, receipt failure and interrupted birth.

6. **RS-6 — reduce release and audit ambiguity.**
   The tree still mixes substantial pre-existing uncommitted work with the
   hardening changes. Review and record one clean revision; create a fresh staged
   Base Sepolia deployment; verify source; deploy the reinvestor from actual
   round addresses; generate the release manifest; and exercise two rounds with
   multiple wallets. Quarantine the retired keeper APIs and unused curve/art
   paths from the supported release. The 233 Slither classifications remain a
   triage inventory, not 233 confirmed exploits or a clean bill of health.

The immediate priority is deciding earned-fee semantics and closing RS-2, then
expanding combined stateful tests and performing controlled testnet playtesting.
The user has explicitly kept this work on testnet; authenticated mainnet fork
coverage remains deferred and is not claimed by the local results.

The confirmed custom-configuration probe can be reproduced independently of the
normal suite with:

```sh
FOUNDRY_TEST=docs/audit/probes/CustomCurveValidation.t.sol forge test --out /tmp/psp-reassessment/out --cache-path /tmp/psp-reassessment/cache --match-contract SineDomainProbe -vv
```

A passing probe currently means the defect reproduced; it is review evidence,
not an assertion that the configuration is safe.
