import { parseAbi, type Address } from 'viem'

/// Minimal, hand-rolled ABIs — only what the UI touches.

export const factoryAbi = parseAbi([
  'function currentRoundId() view returns (uint256)',
  'function rounds(uint256) view returns (address token, address controller, address hook, bool destroyed, string name)',
  'function mixETH() view returns (address)',
  'function referralRegistryOf(uint256) view returns (address)',
  'function poolManager() view returns (address)',
  'function html() view returns (string)',
])

export const controllerAbi = parseAbi([
  'function staker() view returns (address)',
  'function predepositState() view returns (uint256 total, uint256 cap, uint256 startTime, bool closed, bool capReached, bool windowOver, bool launchable)',
  'function claimPredepositPSP()',
  'function predeposit(uint256)',
  'function launchPooledBuy()',
  'function PREDEPOSIT_DURATION() view returns (uint256)',
  'function totalPredepositors() view returns (uint256)',
  'function predeposits(address) view returns ((uint256 mixETHAmount, bool claimed))',
  'function proposeCarpetBomb()',
  'function voteCarpetBomb(bool support)',
  'function carpetBomb()',
  'function finalizeCarpet()',
  'function flatTime() view returns (uint256)',
  'function getCarpetBombState() view returns (address proposer, uint256 proposeTime, uint256 yesVotes, uint256 noVotes, bool executed, bool canExecute)',
  'function currentProposal() view returns (address proposer, uint256 proposeTime, uint256 yesVotes, uint256 noVotes, uint256 lockedAtPropose, bool executed)',
  'function proposalCount() view returns (uint256)',
  'function lastVotedOn(address) view returns (uint256)',
  'function VOTE_DURATION() view returns (uint256)',
  'function QUORUM_BIPS() view returns (uint256)',
  'function MAJORITY_BIPS() view returns (uint256)',
  'function VEST_DURATION() view returns (uint256)',
  'event CarpetBombProposed(address indexed proposer)',
  'event Voted(address indexed voter, bool support, uint256 weight)',
  'event CarpetBombExecuted(uint256 mixETHCarried)',
])

/// PSPStaker — ERC-721 staking positions + pepe art (2026-08-22).
export const stakerAbi = parseAbi([
  'function positions(uint256) view returns (uint256 amount, uint256 startEpoch, uint256 requestEpoch, uint256 settledEpoch, uint256 settledW, uint256 settledSlope, uint256 feesPaid, uint256 actionTime)',
  'function pendingFeesOf(uint256 pepeId) view returns (uint256)',
  'function withdrawableAt(uint256 pepeId) view returns (uint256)',
  'function epochSize() view returns (uint256)',
  'function biasOf(uint256 pepeId, uint256 at) view returns (uint256)',
  'function totalLocked() view returns (uint256)',
  'function totalWeight() view returns (uint256)',
  'function accFeePerShareMixETH() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function tokenOfOwnerByIndex(address, uint256) view returns (uint256)',
  'function primaryOf(address) view returns (uint256)',
  'function stakedTotalOf(address) view returns (uint256)',
  'function voteWeight(address, uint256) view returns (uint256)',
  'function ownerOf(uint256) view returns (address)',
  'function dnaOf(uint256) view returns (uint256)',
  'function descriptor() view returns (address)',
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function lock(uint256 amount)',
  'function lockWithPepe(uint256 amount, uint256 pepeId)',
  'function stakeFor(address user, uint256 pepeId, uint256 amount)',
  'function requestWithdraw(uint256 pepeId)',
  'function cancelWithdraw(uint256 pepeId)',
  'function withdraw(uint256 pepeId)',
  'function claimFees(uint256 pepeId)',
  'function claimFeesTo(uint256 pepeId, address to)',
  'function claimAllTo(uint256[] pepeIds, address to)',
  'function setApprovalForAll(address operator, bool approved)',
  'function isApprovedForAll(address, address) view returns (bool)',
  'function transferFrom(address from, address to, uint256 tokenId)',
  'event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)',
  'event Locked(address indexed user, uint256 indexed pepeId, uint256 amount)',
  'event Withdrawn(address indexed user, uint256 indexed pepeId, uint256 amount)',
  'event FeesClaimed(address indexed user, uint256 indexed pepeId, uint256 amount)',
])

/// PepeDescriptor — on-chain SVG art (eth_call-able, pure).
export const descriptorAbi = parseAbi([
  'function renderSVG(uint256 dna) view returns (string)',
  'function tokenURI(uint256 dna) view returns (string)',
])

export const hookAbi = parseAbi([
  'function mode() view returns (uint8)',
  'function reserveMixETH() view returns (uint256)',
  'function totalSupplyPSP() view returns (uint256)',
  'function getMarginalPrice() view returns (uint256)',
  'function getBuyOutput(uint256 mixETHInput) view returns (uint256)',
  'function getSellOutput(uint256 pspInput) view returns (uint256)',
  'function curveConfig() view returns (uint256 P0)',
  'function getCurveZones() view returns ((uint256 startSupply, uint256 endSupply, uint256 rate, bool isExponential)[] zones)',
  'event Buy(address indexed buyer, uint256 mixETHIn, uint256 pspOut, uint256 newSupply, uint256 newReserveMixETH)',
  'event Sell(address indexed seller, uint256 pspIn, uint256 mixETHOut, uint256 newSupply, uint256 newReserveMixETH)',
])

export const erc20Abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
  'function allowance(address, address) view returns (uint256)',
  'function symbol() view returns (string)',
  'function totalSupply() view returns (uint256)',
  'function transfer(address, uint256) returns (bool)',
])

export const mixVaultAbi = parseAbi([
  'function depositETH() payable returns (uint256)',
  'function redeemETH(uint256) returns (uint256)',
  'function totalAssets() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
])

export const zapInAbi = parseAbi([
  'function zapInBuy((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 minPspOut, uint256 deadline) payable returns (uint256)',
  'function buyWithMix((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 mixIn, uint256 minPspOut, uint256 deadline) returns (uint256)',
  'function zapInPredeposit(address controller, uint256 minSharesMinted) payable returns (uint256)',
])

export const zapOutAbi = parseAbi([
  'function zapOut((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 pspIn, uint256 minMixOut, uint256 deadline) returns (uint256)',
  'function sellToMix((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 pspIn, uint256 minMixOut, uint256 deadline) returns (uint256)',
])

/// PSPReferralRegistry — per-round referral attribution graph (2026-08-27).
/// record() is called by the VISITOR (msg.sender = trader) and binds forever.
export const registryAbi = parseAbi([
  'function record(uint256 referrerNftId)',
  'function attributed(address) view returns (bool)',
  'function traderRefNftOf(address) view returns (uint256)',
  'function canReferNft(uint256) view returns (bool)',
])

/// MixETHFaucet — testnet-only: pay multiples of 0.0001 ETH, receive 100 mixETH each.
export const faucetAbi = parseAbi([
  'function drip() payable',
])

/// PSPReinvestor — claims mixETH fees and compounds them into PSP stakes.
export const reinvestorAbi = parseAbi([
  'function reinvest(uint256 pepeId, (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 minPspOut, uint256 deadline)',
  'function reinvestAll(uint256[] pepeIds, (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 minPspOut, uint256 deadline)',
  'function staker() view returns (address)',
  'event Reinvested(address indexed owner, uint256 indexed pepeId, uint256 mixIn, uint256 pspStaked)',
])

/// Uniswap V4 PoolKey the factory initializes: dynamic-fee flag + tickSpacing 60.
export function buildPoolKey(mix: Address, psp: Address, hooks: Address) {
  const [c0, c1] = [mix, psp].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase())) as Address[]
  return {
    currency0: c0,
    currency1: c1,
    fee: 0x800000,
    tickSpacing: 60,
    hooks,
  } as const
}
