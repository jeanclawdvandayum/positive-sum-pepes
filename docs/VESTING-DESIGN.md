# PSP Vesting Redesign — indefinite locks, ve-style decay, per-pepe cards

Spec (scoopy, 2026-08-28): indefinite locks; `requestWithdraw` starts a 6-week
linear decay of dividend + voting power (1000 PSP → 5/6 at wk1, 1/2 at wk3, 0
at wk6, then withdrawable). Stake page: one card per staked pepe NFT (art,
amount, $value, unlock date, extend→cancel / withdraw buttons, per-card claim +
reinvest), header totals + multiclaim + reinvest-all.

## Contract changes

### PSPStaker — rewrite to multi-position (id-keyed)
- `Position{amount, rewardDebt, requestTime, actionTime}` keyed by tokenId.
  Genesis virtual position lives at tokenId 0 (never minted, never decays).
- ERC721-lite enumeration: `_ownerOf[id]`, `_owned[user] = uint256[]`,
  `balanceOf`, `tokenOfOwnerByIndex`. Transfers move whole positions (no more
  one-per-address merge/husk logic — cards are the positions).
- `lock(amount)` mints a sequential pepe; `lockWithPepe(amount, id)` chosen id;
  top-up = `stakeFor/lock` on an owned id. Top-up while decaying → revert
  (`RequestActive` — cancel first; keeps bias math one-slope per position).
- `requestWithdraw(id)`: claims classic fee leg, stamps requestTime, sets the
  position's day-bucket cursor to day(request)+1. Power starts decaying NOW.
- `cancelWithdraw(id)`: pays the bucket leg, clears requestTime, rewardDebt =
  amount×acc (rejoins classic leg). The UI's "extend" analog.
- `withdraw(id)`: allowed when elapsed ≥ VEST_DURATION or round is flat
  (carpet-bomb keeps immediate-open). Pays bucket leg, principal out, NFT
  survives as husk (amount=0 position; re-stakeable).
- `claimFees(id)` / `claimFeesTo(id, to)` / `claimAll(ids[])`: classic leg for
  non-decaying, bucket leg for decaying. `claimFeesTo` is the reinvestor hook.
- `stakeFor(user, pepeId, amount)`: permissionless — reinvestor path (pulls
  PSP from msg.sender into user's owned pepeId).
- Voting: `voteWeight(user, at)` = Σ bias(id, at) over ids with
  `actionTime < at` (propose-snapshot guard, finding-29 pattern extended).

### Fee math (dual-leg, in-staker — move to PSPFeeVault only if size demands)
Classic Synthetix leg breaks under time-varying weights. Design:
- `addFees(fee)` at event time t:
  `W(t) = totalLocked − decayingBias(t)` where decayingBias is maintained
  O(1) via aggregate (snapshot + slope-sum integral, veCRV totalSupply trick).
  `acc += fee·P / W_full? NO — /W_total(t)`; simultaneously
  `dayAcc[day(t)] += fee·P / W_total(t)` (same division, one extra SSTORE).
- Non-decaying position claim: `amount·acc − rewardDebt` (unchanged math,
  O(1)); their true share fee·amount/W_total is exact because W_total is
  evaluated at every event.
- Decaying position claim: walk `dayAcc[d] × bias(id, d_start)/P` from cursor
  to min(today, day(request)+42). bias(d_start) is pure per position.
  Approximation: intra-day drift of the DECAYER's own weight only
  (<1/42 of a decaying position's daily slice) — Curve feeDistributor makes
  weekly approximations at higher stakes. Bounded ≤42 iterations.
- Weight floor: after decay completes, bias = 0 → earns nothing, withdraws.

### RoundController — timing + vote surface
- Timings pack: PREDEPOSIT, VEST_DURATION, VOTE_DURATION (+flat exit const).
  LOCK/EXTEND/RELOCK slots retired (findings-46 zero-guards preserved).
- vote(): weight = Σ bias(id, proposeTime), per-id actionTime < proposeTime.
- Quorum denominator: max(totalBias(proposeTime), hook.totalSupplyPSP()).
- flatTime bypass on withdraw stays (carpet bomb = all locks open).

### PSPReinvestor (new, script-deployed like zaps — zero factory size)
`reinvest(pepeId, key, minOut, deadline)`:
claimFeesTo(pepeId, reinvestor) → mix.forceApprove(zapIn) →
zapIn.buyWithMix(key, mix, minOut, deadline) → PSP → stakeFor(owner, pepeId).
`reinvestAll(ids[], …)` loops. No custody beyond in-flight, no admin.

### Size plan (EIP-170, per finding 50)
- Staker net: −relock/extend/merge/husk-transfer, +enumeration/request/
  cancel/withdraw/buckets/stakeFor. Measure; headroom test at 24,000B.
- If over: extract fee/bias math to PSPFeeVault (deployed by StakerDeployer
  vessel BEFORE staker — counterparty-has-code order, finding 47 — bound via
  staker constructor passing address(this)).
- Controller: three timing immutables → one; net negative expected.

## Frontend (stake page)
- PepeCards: one card per owned pepe id — art via renderPepeSvg(dnaOf(id));
  rows: amount staked, $value (amount × curvePrice × mix→USD), unlock date
  (requestTime ? requestTime+6w : 'indefinite'), buttons: cancel-request /
  withdraw (greyed per state machine), claim [claim – X mixETH], reinvest.
- Header: total PSP staked (Σ), total $ value, multiclaim (claimAll), 
  reinvest-all.
- ABI additions: positions(id), requestWithdraw, cancelWithdraw, withdraw,
  claimFees(id), claimAll, stakeFor, voteWeight, VEST_DURATION; reinvestor.

## Test plan
- New: decay curve pins (wk0 1.0, wk1 5/6, wk3 1/2, wk6 0), fee-split
  exactness (decayer vs stayer over shared windows), vote-weight snapshot
  (request/cancel/lock post-propose excluded), withdraw gating, stakeFor,
  reinvestor e2e (claim→buy→restake), multiclaim gas, size gates.
- Adapt: every relock/extend/unlock-window test → new lifecycle; temporal
  guards (warp between last action and propose).
- Longitudinal: conservation across full lifecycle stays green.
