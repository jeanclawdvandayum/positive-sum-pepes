# Base Sepolia playtest

The current local release is **[http://127.0.0.1:4173/#/predeposit](http://127.0.0.1:4173/#/predeposit)**.
Use Base Sepolia, chain **84532**, and a browser wallet. Test mixETH is freely
minted and has no monetary value. Base Sepolia ETH pays gas.

## September 7 fresh release

- Source: **`c724d124e924973d2888c0ed185902c581dbb36b`**.
- Factory: **`0xbbd703ebdab9f0dd4beaa9855d758028f115dacf`**.
- [Manifest](deployments/base-sepolia-2026-09-07.json): addresses, bytecode,
  immutable wiring, timings, rules and feature versions, inspected at block
  **46,490,893**. History starts at factory creation block **46,490,865**.
- [Receipts](deployments/base-sepolia-2026-09-07-receipts.json): **17 successful
  transactions**, including the reinvestor deployed against actual round addresses.
- [Source verification](deployments/base-sepolia-2026-09-07-verification.json):
  **17/17 creation/runtime matches** on Sourcify. With `bytecodeHash=none`, these
  are executable-code matches rather than metadata-backed exact-source matches.
- Both deployed-release tests passed on a local fork, covering fresh features,
  two rounds and old-round exits. They made no public-chain gameplay transactions.

The release starts at round 1 in predeposit with zero deposits. Its initial
window ends **September 7, 2026 at 05:00:28 UTC**, or the round can launch sooner
once deposits fill the **500 mixETH** cap. Any positive predeposit is accepted
within that cap, down to one wei, with no per-wallet cap. Use the free mixETH
faucet before depositing.

The active round clock lasts two hours and the withdrawal vest lasts one hour
(six ten-minute epochs). Active purchases require **0.005 mixETH**, including
fees. Every full 0.005 mixETH earns a ladder ticket and adds up to **260 seconds**,
subject to the clock cap. Current source features are active in this release:
atomic referrals, owner-attributed reinvestment, NFT safe transfers and individual
approvals, block-hash-seeded predeposit art and per-round art uniqueness.

Both local frontend overrides point to this deployment. The export supplies a
primary and fallback public RPC and the confirmed history start block. Without
`VITE_WC_PROJECT_ID`, connections use browser wallets. Naming remains disabled
pending its separate Ethereum registrar, matching gate/verifier and custody setup.

To restart the built app from `frontend/`:

```sh
node node_modules/vite/bin/vite.js preview --host 127.0.0.1 --port 4173
```

Rebuild after changing frontend settings with `npm --prefix frontend run build`.
Deployment-specific values belong in `.env.local` and `.env.production.local`.
The prior local settings are backed up in ignored
`out/releases/ui-before-c724d124/`. Full current release logs, build inputs and
receipts are in ignored `out/releases/base-sepolia-live-2026-09-07-c724d124/`.

Earlier factories retain their balances and NFTs. The prior factory was
`0xc79b74dacf99a82f1b1e847948338f9263913a59`; its
[manifest](deployments/base-sepolia-2026-09-05.json) and
[reinvestor repair](deployments/base-sepolia-2026-09-05-reinvest-repair.json)
remain historical records. Previous here.now previews point to their original
builds and were not updated by this local release.

## Wallet test sequence

1. Open the app and connect a test wallet on Base Sepolia. Use its faucet to get
   free mixETH. Try rejecting a wallet confirmation; the app should show no success.
2. Predeposit any positive amount within the cap, including a dust amount. Launch when the cap or window permits, then
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
   explicit NFT operator approval and is specific to its deployed round. Check
   that single and batch reinvestments name the NFT owner in the ladder and tape,
   including calls made by an approved operator. The owner's recorded referral
   chain should receive its share and resulting seats must be claimable by the owner.
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
`PSP_RELEASE_TESTNET=true`, `PSP_RELEASE_FRESH=true`, `PSP_FACTORY`, `PSP_ZAPIN`, `PSP_ZAPOUT`, and
`PSP_REINVESTOR` set from the manifest. Run it with `forge test --match-contract
BaseSepoliaReleaseTest --fork-url BASE_SEPOLIA_RPC --fork-block-number 46490893`.
This is local fork execution only. The two-wallet complete exit can leave one
wei of unallocated genesis PSP; see [FEE-ACCOUNTING.md](FEE-ACCOUNTING.md).

The historical September 5 router repair also passed `ReinvestRepairTest` against its replacement
contracts at block **46416991**, with `PSP_REINVEST_REPAIR_TEST=true` and
`PSP_USE_DEPLOYED_REPAIR=true`, plus factory/zap/reinvestor addresses from the
September 5 repair manifest. It tests operator single/batch reinvestment and owner pot claims
against the live round's deployed contracts on a local fork. It sends no transactions.

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
