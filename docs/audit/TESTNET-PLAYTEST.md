# Base Sepolia playtest

Use chain **84532**. Test mixETH is freely minted and has no monetary value;
Base Sepolia ETH is needed only for gas. The deployment manifest is the source
of addresses and code hashes. Existing earlier deployments retain their old code.

Open **[the local app](http://127.0.0.1:4173/#/predeposit)** in a browser with your
wallet extension. The frontend is running on this Mac; this is not a public hosted
URL. Without `VITE_WC_PROJECT_ID`, connection uses browser wallets only. A real
WalletConnect project can be configured later for remote/mobile connections.

- Factory: `0xc79b74dacf99a82f1b1e847948338f9263913a59`.
- [Release manifest](deployments/base-sepolia-2026-09-05.json): factory-derived
  addresses, bytecode hashes, constructor wiring and approved rules.
- [Verification record](deployments/base-sepolia-2026-09-05-verification.json):
  17/17 creation/runtime matches on Sourcify. This build uses `bytecodeHash=none`,
  so these are executable-code matches, not metadata-backed exact-source matches.
  See [Sourcify's match definitions](https://docs.sourcify.dev/docs/exact-match-vs-match/)
  and [the verified factory](https://sourcify.dev/server/v2/contract/84532/0xc79b74dacf99a82f1b1e847948338f9263913a59?fields=all).
- [Deployment receipts](deployments/base-sepolia-2026-09-05-receipts.json): 16
  deployment transactions plus the second-pass reinvestor, all successful.

To restart the built app from `frontend/`, run:

```sh
node node_modules/vite/bin/vite.js preview --host 127.0.0.1 --port 4173
```

Deployment addresses are in the ignored `.env.local`; the production RPC default
is in `.env.production` (use `.env.production.local` to override it locally).
Rebuilding uses those settings. The manifest pins protocol source revision `a35228a3`;
subsequent frontend/documentation changes do not change deployed Solidity code.
The frontend uses [Base's public Sepolia endpoint](https://docs.base.org/base-chain/api-reference/rpc-overview)
with Multicall3 view batching, concurrent-request deduplication, a second public
provider as fallback, and 12-second timeouts per provider. Immutable round
metadata is cached. The curve preview samples locally from materialized on-chain
coefficients; executable quotes and minOut protection still come from the contract.
Activity history starts at `VITE_DEPLOYMENT_BLOCK` and advances in bounded pages
with a 12-block reorg overlap. Set this block from the factory's creation receipt
when deploying another instance.
Public RPC service remains subject to rate limits; the playtest should include
an interruption/recovery check.

The configured playtest has a two-hour predeposit window, one-hour withdrawal
vest (six ten-minute epochs), two-hour clock cap, and no per-wallet predeposit
cap. Minimum buy/predeposit is 0.005 mixETH; each whole purchase unit earns a
ticket and 260 seconds, subject to the clock cap. The total predeposit cap is
500 mixETH. To start immediately, fill that cap with free test mixETH and launch;
a smaller raise becomes publicly launchable when its window ends.

## Wallet test sequence

1. Open the app and connect a test wallet on Base Sepolia. Use its faucet to get
   free mixETH. Try rejecting a wallet confirmation; the app should show no success.
2. Predeposit at least 0.005 mixETH. Launch when the cap or window permits, then
   claim your genesis position. A second wallet helps test distribution.
3. Buy 0.005, 0.01 and 0.05 mixETH. Expect 1, 2 and 10 new ticket units. Fractional
   purchase remainders give neither an extra seat nor extra time. At the clock cap,
   actual added time can be zero. Selling keeps existing seats. Check the estimated
   trade fee (mixETH and percentage) below the receive box in both directions:
   buy fees are included in payment; sell quotes already deduct fees. Network gas
   is separate. Quote, rate and mode come from one on-chain snapshot. Sell fee
   estimates reconstruct gross proceeds and can be up to one wei high at current
   protocol rates; the actual receive quote and transaction minOut remain unchanged.
4. Stake into multiple pepes, trade from the other wallet, and observe fees. Claim
   once immediately; request withdrawal on another position and leave its fees
   unclaimed across boundaries. Earned fees should remain available. Use **+ add
   PSP** on an existing position card to top it up: enter an amount or choose Max,
   approve only that PSP amount if prompted, then confirm the top-up. The NFT ID
   stays the same and its stake increases after confirmation. Try a zero-stake
   pepe too. A withdrawing position requires **keep staking** before adding PSP;
   detonated rounds do not accept top-ups. Reject an approval, then try changing
   wallet/network between approval and staking; the second write must not proceed.
5. Cancel a withdrawal before and after maturity, transfer a pepe, claim its fees
   as the new owner, and reinvest fees of at least 0.005 mixETH. The wrapper needs
   explicit NFT operator approval and is specific to its deployed round.
6. Let the clock expire. Trades should fail. Detonate, then resume successor birth
   through reservation and three confirmed birth steps. Interrupting/reloading
   between steps should resume from chain state.
7. In the graveyard, claim any unclaimed predeposit position, withdraw old stakes,
   redeem old PSP and claim ladder winnings. There is no expiry. New-round activity
   must not change the old round's redemption rights.
8. Repeat with wallet/chain changes, cancelled or replaced transactions, and an RPC
   interruption. A submitted hash alone must never appear as a successful action.

Record transaction hashes, round, wallets involved, exact amounts, expected and
observed behavior. Browser wallet scenarios remain part of the user playtest;
automated receipt and exit-target tests do not substitute for those interactions.

The automated deployed-code test is `BaseSepoliaReleaseTest`, with
`PSP_RELEASE_TESTNET=true`, `PSP_FACTORY`, `PSP_ZAPIN`, `PSP_ZAPOUT`, and
`PSP_REINVESTOR` set from the manifest. Run it with `forge test --match-contract
BaseSepoliaReleaseTest --fork-url BASE_SEPOLIA_RPC --fork-block-number 46412314`.
This is local fork execution only. The two-wallet complete exit can leave one
wei of unallocated genesis PSP; see [FEE-ACCOUNTING.md](FEE-ACCOUNTING.md).

## Measured economic scenarios

`forge test --match-contract LadderEconomicsTest -vv` uses real V4 settlement.
With a 100 mixETH genesis raise (10 mixETH initial pot), an otherwise unchallenged
0.05 mixETH buyer buys and sells all PSP, retains all ten seats, and wins the pot:

| Measure | mixETH |
|---|---:|
| Buy/sell cost before rewards | 0.00950405 |
| Pot won at expiry | 10.0037048245 |
| Wallet gain excluding gas | 9.9942007745 |

A separate majority-staker buy/sell/buy scenario credits approximately
0.00869973 mixETH back to the trader as staking fees and adds 0.0056548245 mixETH
to the pot. These are measured examples, not universal profitability estimates.
They show that fee-paying cycles fund rewards while allowing the same trader to
recapture rewards. Ownership concentration and inactivity matter substantially.

Track net new deposits, repeated capital turnover, net fee flows by owner,
concentration of the ten seats, clock extensions wasted at the cap, and whether
rounds expire organically. No anti-Sybil or MEV guarantee is made. One minimum
purchase every 260 seconds balances elapsed time away from the cap: about
1.661538 mixETH gross purchases per day, not that amount of irreversible cost.
