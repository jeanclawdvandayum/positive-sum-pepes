# Agent 12 — Flow Gap — working traces (scratchpad, not deliverable)

## Verified periphery semantics (source: ~/clawd/alchemix-v3/src/Transmuter.sol, TokenUtils.sol, fork tests)

- Transmuter.createRedemption: pulls alAsset via transferFrom, `_positions[++_nonce]`,
  `_mint(recipient, _nonce)` — PLAIN mint (no safeMint). OZ ERC721Enumerable mint
  appends at index = pre-mint balance = post-mint balance-1 (tail). Strategy's
  `tokenOfOwnerByIndex(strategy, balanceOf(strategy)-1)` after createRedemption
  returns the fresh id. VERIFIED against real source.
- claimRedemption reverts: PositionNotFound (burned), PrematureClaim (startBlock ==
  block.number — impossible for matured), CallerNotOwner (strategy owns tracked ids).
  Zero-value TokenUtils.safeTransfer is allowed (no nonzero check). TokenUtils
  reverts only on call failure.
- AlchemistV3.redeem (onlyTransmuter): clamps amount to liveEarmarked, transfers 0
  on empty earmark — does not revert. Claim-brick surface is narrow.
- Auction module (fork-pinned, source not on disk): factory arg = payment token
  (`want`); receiver = governance = strategy; per-unit WAD prices; auction ends by
  floor-crossing or ~24h; full take settles (kicked resets); sweep(token) returns
  auction balance to receiver, works on ended-unsold lots.

## Dead hypotheses (killed by source/tests — do not report)
- 1-wei donation to ASSET_AUCTION bricking kickAuction: DEAD — kickAuction sweeps
  the auction balance back BEFORE pricing/transfer, so _available <= post-sweep
  balance always holds.
- Wrong-id capture via tokenOfOwnerByIndex tail: DEAD — OZ appends at tail; no
  reentrancy window between _mint and the read (alUSD transferFrom has no hook).
- safeMint/onERC721Received requirement: DEAD — transmuter uses plain _mint.
- Auction minimumPrice unit mismatch: DEAD — tests pin per-unit WAD semantics on
  both auctions.
- Zero-value MYT/alUSD transfers reverting in claim: DEAD — TokenUtils allows.

## Re-reached known findings (report in full with own proof)
1. kickAlAssetAuction unbounded-auction-price-floor: `require(_minimumPrice != 0 &&
   _startingPricePerUnit > _minimumPrice)` — floor of 1 wei accepted; lot decays to
   ~free. onlyEmergencyAuthorized.
2. aprAfterDebtChange overstated-apr: idle-alAsset term unconditional; ladder-full
   (positions.length >= maxPositions) or zero transmuter headroom never stakes it,
   APR still books full-cycle accretion.
3. MYTLimitsLib.availableWithdrawLimit uncaught-view-revert: only `vault()` is inside
   try; `IERC4626(_underlying).maxWithdraw(_adapter)` and catch-path
   `IMYTStrategy(_adapter).realAssets()` revert-escape. Reaches: strategy
   availableWithdrawLimit (vault redeem limit check), _freeFunds (withdraw/tend/
   emergencyWithdraw body), _tendTrigger (keeper automation). Extension beyond known
   text: _tendTrigger + _freeFunds revert paths.

## Re-reached known leads (mechanism confirmed)
- redeem-catch-skips-all: convertToShares(liquid) rounding vs Morpho redeem bounds;
  single revert in try{}catch{} skips the whole redemption; withdraw then reverts on
  short idle. Morpho-side revert condition unverified (no Morpho source on disk).
- withdraw-limit-ignores-claim-haircut: `_matured += _position.amount` at face;
  claim pays fee + bad-debt scaling + shortfall-as-synthetics; limit overstates.
- unclaimed-position-brick: a tracked matured id whose claimRedemption reverts
  reverts the whole _freeFunds loop → tend/withdraw/emergencyWithdraw all revert.
- erc721-no-recovery-path + donated-nft-stranded: sweep() blocks only the 3 ERC20s;
  manualClaim indexes positions[] only; a donated position NFT has no claim path and
  its balanceOf inflation is handled by the tail read (verified safe).
- bad-debt-mirror-divergence: mirror formula matches deployed Transmuter exactly
  (mulDivUp, same inputs, ASSET_UNIT == underlying decimals) — divergence is
  temporal (ETA-time vs claim-time), not formulaic.
- myt-rate-without-liquidity: ETA += convertToAssets(balance) with no liquidity
  bound; illiquid vault keeps par marking; profit unlocks on unbacked PPS.
- parameter-change-re-marks-carrying-value: `_alAssetPrice = 1e36/minimumPrice`
  re-marks ALL idle alAsset on setAuctionPrices; lowering the floor books mark-up
  profit at next report without any external fill.
- uncapped-auction-lot-depeg-take: maxAuctionAmount is the only lot cap (tests set
  uint96.max); keeper lists everything; a depeg fill converts the whole vault at the
  1.1 floor in alAsset.
- auction-module-semantics-unverified: still true for me — fork tests pin behavior,
  source not readable on this machine.
- missing-loss-limit-config + unset-strategist-role: Deploy.run sets neither;
  default lossLimitRatio 0 blocks loss-taking reports until management configures.

## New leads from this pass
- availableDepositLimit reserves headroom 1:1 per queued asset, but a fill converts
  each asset into fillPrice alAsset (>1), so deposits can exceed deployable room;
  the excess alAsset idles untransmuted and unwithdrawable until headroom frees.
