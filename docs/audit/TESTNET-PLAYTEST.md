# Base Sepolia playtest

Use chain **84532**. Test mixETH is freely minted and has no monetary value;
Base Sepolia ETH is needed only for gas. The deployment manifest is the source
of addresses and code hashes. Existing earlier deployments retain their old code.

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
   actual added time can be zero. Selling keeps existing seats.
4. Stake into multiple pepes, trade from the other wallet, and observe fees. Claim
   once immediately; request withdrawal on another position and leave its fees
   unclaimed across boundaries. Earned fees should remain available.
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
