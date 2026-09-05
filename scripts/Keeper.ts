/** The old yield keeper targets APIs removed by the clock redesign. */
console.error('The legacy yield keeper is disabled. This testnet uses owner/operator-authorized PSPReinvestor transactions from the staking page. Historical source: scripts/legacy/Keeper.ts.');
process.exitCode = 1;
