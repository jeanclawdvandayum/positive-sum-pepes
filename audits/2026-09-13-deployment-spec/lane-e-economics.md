Tool budget exhausted mid-hunt — the analysis is complete and all campaigns finished; only the final file-write didn't happen. Full report content is below, ready to be saved to `~/clawd/positive-sum-pepes/audits/2026-09-13-deployment-spec/lane-e-economics.md`.

Bottom line first: **no Critical/High/Medium findings. Two LOW, four INFO, five refuted attack hypotheses with mechanisms.**

````markdown
# Lane E — Economic & Timing Attacks (deployment-spec branch)

Auditor: Hermes (GLM-5.3) · 2026-09-13/14 · base diff: `testnet-final`
Scope: `src/libraries/SineMath.sol`, `src/CurveHook.sol`, `docs/FINAL-SPEC.md`
(context reads: `RoundController.sol`, `GameRules.sol`, `CurveMath.sol` timings)

## Method

A bit-exact Python oracle of SineMath v2 + solady `expWad`/`lnWad`/`rpow`
(integer-exact ports of the vendored assembly, EVM trunc/floor/sar semantics)
was validated **60/60 cases, zero mismatches** against the repo's actual
SineMath compiled via Foundry in a scratch project outside the tree, across
default params, both validate() extremes, and boots from 4,500 wei to 1e30.
All numbers below come from that oracle.

Campaign volumes: price monotonicity 38,725 pts · supplyAt monotonicity
38,725 pts · buy→sell round trips 5,389 · raw slice tests 3,846 · reserveAt
upper-endpoint tests 2,316 · dust scan boot 1 wei→1e6 wei · giant scan to
boot 1e37 · fee-boundary & clock-cap property sweeps · self-trade economics.

## Findings

### E-1 (LOW) — Dust-boot rounds: buys brick via supply saturation; sub-143-wei boots can never launch

`_validateBootstrap` (RoundController.sol:385-392) only dry-runs
`hook.sineGenesisPSP(netBoot)` when `netBoot >= 450e18`; the comment below it
("Dust pools can grow into a representable launch") assumes dust boots fail
`materialize` — they don't. With default params (ref targetReserve 10,000e18),
`materialize(boot=1 wei)` **succeeds**: target = 22, lam = 7, W = 48,698,
q0 = 43,012 (SineMath.sol:121-131 never rejects). Reachable: `deposit()`
accepts any amount > 0, and `launchPooledBuy()` is permissionless once the
3-day window expires (RoundController.sol:447-450); totalBoot=1 wei →
potFee floors to 0 → boot = 1 wei.

Consequences on the zombie round:
- Total representable supply = q0 + W·g/(g−1) ≈ 97,600 wei PSP (~1e-13 PSP).
- The first ≥ MIN_BUY buy saturates it (spend/lam ≈ 6e14 waves). Every later
  buy: `supplyAt` difference = 0 → `buyOut` → 0 → `ZeroOutput` revert
  (CurveHook.sol:484, SineMath.sol:221,228). Buys permanently bricked; sells
  still work; reserve only descends.
- The one buyer overpays catastrophically (0.005 mixETH for ~5.5e4 wei PSP,
  effective ~10^5 mixETH/PSP) — self-harm; P1/P2 hold throughout.
- Separately, net boot < ~143 wei with default params gives lam = 0 →
  `sineGenesisPSP` reverts inside `launchPooledBuy` → the round can NEVER
  launch (funds remain claimable via predeposit withdrawal; round dead).
  With minimum-`targetReserve` (451e18) params this cliff sits at ~1,350 wei.

No value extraction; availability/design blemish on neglected or griefed
rounds only. Suggest a minimum-viable-boot gate at launch (e.g. require
`lam >= MIN_BUY_INPUT` or net boot ≥ floor) or extend `_validateBootstrap`
below 450e18.

### E-2 (LOW) — Raw-library slice overpay from supply quantization (contained at hook level)

The hunt question "does `sellOut(supplyAt(R) − supplyAt(R−s))` ever exceed s?"
— **YES, at raw-library level**: 1,659 / 3,846 fuzz violations (43%), excess
from 1 wei up to ~1.25e13 wei. Mechanism: `reserveAt` returns the LEFT edge
of `supplyAt`'s integer plateau (bisection `supplyAt(mid) >= target → hi = mid`,
SineMath.sol:198-211), so a sell's endpoint snaps down by up to one plateau
width ≈ p(R) reserve-wei. Plateaus only form where dq/dR < 1 PSP-wei per
reserve-wei, i.e. price > 1.0 mixETH/PSP — beyond ~1.4× target on defaults.

Contained in the hook by three independent layers:
1. Buy haircuts (1 wei + 1 bps, SineMath.sol:229-230): 5,389/5,389 buy→sell
   round trips strictly losing; minimum observed margin 4e-15 relative.
2. Sell spot clamp (SineMath.sol:241-247) bounds payout ≤ q·p(R); for tiny
   sells (q·p < plateau width) it binds and pays ≈ fair value.
3. The clamp-free zone (`_inversePriceAt == 0`, beyond 42/trend+1 ≈ 20 waves,
   SineMath.sol:264) is unreachable while Active: buys die at the SAME
   horizon (spotBound = 0 → `ZeroOutput`), so reserve can never be pushed
   into it.

At real scales (default curve, s ∈ [0.001, 1000] mixETH): worst relative
excess 1.5e-10, worst absolute ~5e-13 mixETH. Tranched-selling harvest test
(2/5/20 tranches at boot and target regions): deltas ±1e-9 mixETH, well
inside fees. Solvency never touched: the integer ledger is self-consistent
(supplyAt monotone 38,725/38,725; reserveAt upper endpoint 2,316/2,316;
P1/P2 hold on every path). Dust-scale curves (boot ~1e5 wei) show grosser
violations (out up to 2.5× s) — that is E-1 territory, not reachable value.

### E-3 (INFO) — Chunked buys pay marginally less fee than one big buy

Fee is anchored at the pre-trade reserve (CurveHook.sol:478, :576); buying
raises reserve into cheaper fee territory, so splitting a large buy saves
≈ x·750bps·0.9x/(target−boot) — second order, ~7e-4 mixETH per 10 mixETH at
default scale. Chunked sells are strictly worse. Inherent to any
reserve-anchored fee; no custody impact (each chunk still pays ≥ 2.5%).
Frontends/bots should chunk buys, never sells.

### E-4 (INFO) — Clock-extension economics: detonation requires buyer abstention

Full-window top-up = ⌈248,660/69⌉ = 3,604 units = 18.02 mixETH at base
ticketPrice, one tx, from any remaining time > 0. Sustaining the clock needs
~1,252 units/day ≈ 6.26 mixETH/day gross, of which the true burn is only the
fee + curve premium — a buyer retains PSP redeemable post-detonation at
average backing ≥ early entry. A single motivated early holder can keep a
round alive ~indefinitely at near-fee cost. Design-intent ("buys add time"),
but the deployment should be aware the clock never dies while anyone keeps
buying ≥ ~0.156 mixETH/day equivalent (2.5% fee region).

### E-5 (INFO) — Asymmetric buy wall at the inverse-price horizon

`_inversePriceAt` returns 0 past `42/trend + 1` waves (SineMath.sol:264) →
buys revert `ZeroOutput` there, ~20 waves past boot on defaults (~6.7×
target reserve), well before `priceAt`'s `ExpPriceArg` wall (~60 waves).
Sells remain open below it. Matches FINAL-SPEC.md:43's "supported arithmetic
range"; documented here because the two horizons differ and only the buy side
is economically binding.

### E-6 (INFO) — MIN_BUY buys stop earning units after the first post-genesis trade

`ticketPrice` exceeds `MIN_BUY_INPUT` once pot growth ≥ 47,620 wei
(≈ 4.8e-11 mixETH). The pot leg of the very first qualifying buy (~1.75e14
wei) blows far past it, so only the first qualifying buy can be a 1-unit
0.005-mixETH purchase; afterwards MIN_BUY buys trade but mint no time/seats.
Consistent with the code comment ("Smaller buys still trade normally",
CurveHook.sol:504).

## Refuted hypotheses (with reasons)

1. **Dynamic-fee round-trip extraction** — REFUTED. `swapFeeBps` is
   non-increasing in reserve (1000 at r≤boot → linear → 250 at r≥target;
   buy-fee ≥ sell-fee in any buy-then-sell; sell-then-buy strictly worse).
   Round trip ≤ x·0.975·0.975·0.9999 = 0.9506x even at the cheapest corner.
   Measured 10-mixETH round trips: −19.01% at boot (1000/1000 bps),
   −12.12% mid (625/625), −4.947% at target (250/250); max observed
   differential 251/250 bps at target−1 still loses 4.957%. Fee boundaries
   are exact: r=boot±1 → 1000 bps, r=target−1 → 251, r=target → 250; the
   floored slice always rounds the fee UP (CurveHook.sol:93).
2. **ticketPrice suppression/deflation** — REFUTED. `potBalance` is monotone
   non-decreasing during Active (only `_splitFee` adds); `genesisPotBalance`
   snapshots at `initializeCurve` (CurveHook.sol:865-866); growth clamped at
   0 (no underflow, :184); no decrement path exists before Flat. The current
   trade cannot inflate its own units (units computed :492 before `_splitFee`
   :528).
3. **Cheap-early-ticket / late-ticket arbitrage** — REFUTED as extraction.
   Time added is a global public good (shared clock); seats are a rolling
   last-10 buffer — early seats are evicted. Early cheap units only let a
   buyer delay detonation for everyone (see E-4).
4. **Self-trade loop minting time free** — REFUTED. Each buy+sell cycle pays
   both fees + haircuts (19% early → 4.95% late, measured 1.9008 mixETH lost
   per 10-mixETH cycle) and self-inflates ticketPrice via its own pot legs
   (measured tp 0.005014 → 0.005084, units 2000 → 1972 over 6 cycles).
   Clock-cap math is overflow/boundary clean: property-tested across
   detonationAt ∈ {now, now+1, now+detWindow−70…+detWindow} × units up to
   3.4e22 — `detonationAt' ≤ now + detWindow` in every case
   (cap-before-multiply, CurveHook.sol:496-500). Detonation can never be
   pulled earlier: `detonationAt` only ever increases; `detonate()` gated on
   `block.timestamp >= detonationAt` (RoundController.sol:590); halt gate
   runs before any state change (CurveHook.sol:344). Seat bookkeeping
   (units−seats skip, absolute numbering, uint128 fields) is consistent.
5. **Clamps overpaying sellers / underpaying custody** — REFUTED. Buy clamp
   rounds the reciprocal DOWN (SineMath.sol:226) → buyer never overpaid,
   P1 only strengthened. Sell conservativeness = reserveAt upper endpoint
   (proven structurally + 2,316/2,316) with the spot clamp as an independent
   geometric cap. P2 (`balance ≥ reserve + pot unpaid + deployer credit
   unpaid`) traced on buy and sell paths: user+fee outflows ≤ reserve debit,
   `paid ≤ refLeg` by registry tier bounds (ΣTIER_BPS ≤ 10000, per-cut
   flooring), remainder margins land in the pot. Holds on clamped paths too.
6. **materialize extremes** — giants SAFE (clean through boot = 1e37;
   waveLimit ~9.4e41 ≪ 2^256; fullMulDiv is 512-bit internally; the ≥450e18
   `_validateBootstrap` dry-run catches launch-breaking configs at deposit
   time). lam==0 / W==0 / q0==0 all revert (SineMath.sol:117,123,131) — but
   see E-1 for the unvalidated dust band below 450e18.

## PoC sketch (advisory — both findings are LOW; included for reproducibility)

```solidity
// E-1: dust round bricks buys after saturation (forge, scratch project)
function test_dustBootBricksBuys() public {
    // 1-wei predeposit, warp past the 3-day window, permissionless launch
    vm.warp(block.timestamp + controller.PREDEPOSIT_DURATION() + 1);
    controller.launchPooledBuy();            // materializes boot=1 wei curve
    // first buy succeeds and saturates wave supply (~5.5e4 wei PSP total)
    _buy(alice, 0.005e18);
    // every later buy reverts ZeroOutput: supplyAt(R+s) == supplyAt(R)
    vm.expectRevert(CurveHook.ZeroOutput.selector);
    _buy(bob, 0.005e18);
    // sells still function; P1/P2 invariants hold throughout
}
```

## Verdict

The economic core of this branch is sound. The dynamic fee can never be
arbitraged (multiplicative two-sided fees ≥ 4.9% per round trip dominate any
≤ 750 bps differential, and the fee schedule is provably monotone in
reserve); ticketPrice is monotone, snapshot-anchored, and un-suppressible;
the clock is cap-clean, overflow-free, and irreversible; and the custody
invariants (P1/P2) held on every path probed by a bit-exact oracle across
~50k adversarial points spanning 1-wei to 1e37 boots. The two real findings
are an availability blemish on dust-boot rounds (E-1, buys brick after
saturation; launch itself unbrickable below ~143 wei) and a quantization
artifact in the raw library slice property (E-2) that the hook's haircuts
and spot clamp fully contain — neither extracts value. The remaining notes
are economic-character documentation (chunked-buy fee saving, clock-sustain
cost, the buy-side horizon wall) that deployment owners should simply know.
````

Key artifacts from the session, if you want to re-run anything: oracle + campaigns live in `/tmp/psp-econ/` (`oracle.py` bit-exact port, `hunt_fast.log` the 38k-point fuzz results, `hunt_hook.log` dust/giant/fee/clock sims, `hunt_geom.log`, `hunt_plateau.py`), and the Foundry cross-validation project is `/tmp/psp-econ/src/Probe.sol` + `Cases_gen.sol` (60/60 exact match against the repo's compiled SineMath — the port bug I hit twice mid-session was in my reference, not the contract; the contract's `reserveAt` at boot+1 hit the true inverse to the wei).

One process note: the final file write to `audits/2026-09-13-deployment-spec/lane-e-economics.md` did not happen because the tool budget ran out at exactly that step — the complete report above is ready to drop in verbatim.