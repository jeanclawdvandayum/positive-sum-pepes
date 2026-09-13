## Live alternative UI

The connected version lives in `frontend/src/alt/`. It shares the wallet, quotes,
approvals, transaction receipts and NFT controls with the original frontend.
Run `npm run dev:alt -- --host 127.0.0.1 --port 4180` from `frontend/`.
The local deployment settings are in the ignored `frontend/.env.alt.local` file.
The original UI remains available through the default frontend mode.

The files below are the preserved static design prototype.

# Positive Sum Pepes: alternative frontend

A standalone design prototype in `alt-frontend`. The current `frontend` stays unchanged.

Every page uses local sample data and browser state. The prototype sends no remote procedure calls (RPC) or wallet transactions. Reloading resets the demo. The example archive does not use the build brief’s unverified historical pot.

## Product audit

Positive Sum Pepes (PSP) is a repeating game with a token, a ten-seat ladder, and a countdown. Buys take seats and extend the clock. After expiry, anyone can settle the round. The final ladder divides the pot, and token holders can redeem their share of remaining backing.

The strongest fact is that claims survive the round. A new round can start while old winners and holders retain their claim paths. Earned staking fees also remain claimable. Each old round keeps its own assets and obligations.

The largest credibility risk is presenting backing as a protected purchase price. Redemption opens after detonation, pays a proportional share of remaining backing, and rounds down. It can return less than the purchase cost. The first screen explains this beside the main action.

## Design choices

- The hero puts the moving clock, pot, and ticket price together. Amber marks time and money. Green marks actions.
- The buy form previews occupied seats, added time, and conditional pot claims. A slider shows displacement by later tickets.
- The payout bars explain the ladder before the fee reference. Larger first-place rows make the payout weights visible.
- The stake page shows example positions and lets visitors choose a Pepe before any wallet connection. The graveyard presents example records and surviving art.
- Display fonts carry titles and clock digits. Body fonts carry labels. Responsive layouts, keyboard focus, light mode, and reduced-motion support cover basic access needs.

## Run locally

From the repository root:

```sh
cd alt-frontend
npm run dev
```

Open [the prototype](http://127.0.0.1:4180). Use **demo controls** in the footer to change the round state.

Run the model tests from `alt-frontend`:

```sh
npm test
```

The server requires Python 3. Tests require Node.js. No package installation or build step is required.

## Rules and scope

The model uses integer token amounts. Each whole ticket adds 69 seconds, with a maximum clock of 4 hours and 20 minutes. Tickets start at 0.005 mixETH after genesis. Their price rises linearly by 0.42% of that base per extra mixETH in the pot. Each buy uses the ticket price before its fees enter the pot.

The prototype covers the explainer, play, stake, graveyard, and a predeposit scenario. All trades, names, balances, deposits, and claims are simulated. The chart uses the project’s tilted-sine formula and default parameters with the demo launch reserve. PSP estimates integrate that same curve after fees. The sell panel explains the flow without an executable PSP quote. Reinvestment uses an explicit example amount. No sample record represents a verified historical result.

## Real integration next

Connect the production read/write hooks and replace numeric PSP estimates with exact contract quotes. Add wallet connection, name resolution and registration, referral attribution, and receipt-backed claims. Read each round’s deployed parameters instead of assuming the demo profile.

A live release also needs an Open Graph (OG) image endpoint for each round. That endpoint must read current state and identify when it captured the pot and clock. Static preview values must remain labeled as examples.
