// Scratch PoC sketches for agent-2 (access control). NOT part of the repo.
// Repo is read-only. These are traces to attach to findings as proof text.
//
// Setup (matches src/test/utils/Setup.sol fork block 25,969,940):
//   asset = USDC(6), alAsset = alUSD(18), AL_TO_ASSET_SCALER = 1e12.
//   roles: management == emergencyAdmin == SMS; keeper == yHAAS.
//
// ---------------------------------------------------------------------------
// PoC 1 — kickAlAssetAuction accepts a one-wei floor (known: unbounded-auction-price-floor)
// ---------------------------------------------------------------------------
// Precondition: strategy holds 350_000e18 alUSD (idle, e.g. ladder full so
// _transmutableAmount() == 0 and tend cannot stake it).
//
//   vm.prank(management);            // onlyEmergencyAuthorized includes management
//   strategy.kickAlAssetAuction(
//       350_000e18,                  // _amount: the entire alUSD inventory
//       2,                           // _startingPricePerUnit = 2 wei per unit
//       1                            // _minimumPrice = 1 wei per unit
//   );
//   Guard executed: require(_minimumPrice != 0 && _startingPricePerUnit > _minimumPrice)
//   1 != 0 -> true ; 2 > 1 -> true. PASSES.
//
//   // Accomplice takes the whole lot for dust:
//   uint256 needed = alAssetAuction.getAmountNeeded(address(alAsset)); // ~2 wei USDC
//   USDC.approve(address(alAssetAuction), needed);
//   alAssetAuction.take(address(alAsset));
//   // Auction pays receiver() == strategy; strategy now holds ~2 wei USDC
//   // instead of 350k alUSD. Vault lost the inventory; taker paid dust.
//
// Parallel guard that exists for the same knob on the other auction:
//   setAuctionPrices(): require(_minimumPrice > _WAD && _startingPricePerUnit > _minimumPrice)
//
// ---------------------------------------------------------------------------
// PoC 2 — revert inside the try body escapes the catch (known: uncaught-view-revert)
// ---------------------------------------------------------------------------
// MYTLimitsLib.availableWithdrawLimit(IMYT, uint256):
//
//   try IMYTStrategy(_adapter).vault() returns (address _underlying) {
//       _liquid += IERC4626(_underlying).maxWithdraw(_adapter);   // <- NOT covered
//   } catch {
//       _liquid += IMYTStrategy(_adapter).realAssets();
//   }
//
// Solidity try/catch covers ONLY the external call in the try clause and its
// return-data decoding. The success branch body runs OUTSIDE the catching
// scope: a revert in maxWithdraw(_adapter) propagates uncaught.
//
// Attack trace (no attacker profit; blocks every redemption):
//   1. MYT vault's liquidityAdapter points at an adapter whose underlying
//      vault is paused or gated; maxWithdraw(adapter) reverts.
//   2. strategy.availableWithdrawLimit() -> MYTLimitsLib -> revert bubbles up.
//   3. ERC4626.maxRedeem/maxWithdraw reverts -> every redeem() reverts.
//   4. Same revert hits _freeFunds' sizing call? No — _freeFunds calls the
//      1-arg version first; but availableWithdrawLimit() (0-arg) is the one
//      used by views. Redemption path is blocked until the adapter is fixed.
//   Note: a revert in the CATCH body (realAssets()) propagates too.
//
// ---------------------------------------------------------------------------
// PoC 3 — one reverting claimRedemption bricks every exit (known: unclaimed-position-brick)
// ---------------------------------------------------------------------------
// Call graph in src/Strategy.sol:
//   ERC4626.redeem -> _withdraw -> _freeFunds(_amountDebt)      (BaseStrategy v3)
//   tend()          -> _tend    -> _freeFunds(0)
//   emergencyWithdraw -> _emergencyWithdraw -> _freeFunds(0)
//   _freeFunds loop:
//       if (TRANSMUTER.getPosition(_id).maturationBlock > block.number) continue;
//       TRANSMUTER.claimRedemption(_id);        // <- no try/catch, no skip
//   If the transmuter pauses claimRedemption (or any position's claim reverts),
//   redeem(), tend() and emergencyWithdraw() all revert. Depositors cannot exit.
// ---------------------------------------------------------------------------
