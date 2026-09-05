/** Compatibility check only; deployed source/code verification is separate. */
export function assertReinvestor(expectedStaker: string, actualStaker: string, attributionVersion: bigint) {
  if (attributionVersion !== 1n) throw new Error('This reinvestor does not credit purchases to the NFT owner. Update the deployment.')
  if (expectedStaker.toLowerCase() !== actualStaker.toLowerCase()) throw new Error('Compounding is unavailable for this round.')
}
