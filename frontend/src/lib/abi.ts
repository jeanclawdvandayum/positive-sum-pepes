import { parseAbi, type Address } from 'viem'

/// Minimal, hand-rolled ABIs — only what the UI touches.

export const factoryAbi = parseAbi([
  'function currentRoundId() view returns (uint256)',
  'function rounds(uint256) view returns (address token, address controller, address hook, bool destroyed, string name)',
  'function mixETH() view returns (address)',
  'function poolManager() view returns (address)',
  'function html() view returns (string)',
])

export const controllerAbi = parseAbi([
  'function locks(address) view returns (uint256 amount, uint256 rewardDebt, uint256 lockTime, uint256 unlockTime)',
  'function potState() view returns (uint256 pspBalance, uint256 mixETHFunded)',
  'function totalLocked() view returns (uint256)',
  'function accFeePerShareMixETH() view returns (uint256)',
  'function pendingFeesMixETH() view returns (uint256)',
  'function totalInitialPSP() view returns (uint256)',
  'function totalPredepositMixETH() view returns (uint256)',
  'function PREDEPOSIT_CAP() view returns (uint256)',
  'function predepositClosed() view returns (bool)',
  'function predeposits(address) view returns (uint256 mixETHAmount, bool claimed)',
  'function claimPredepositPSP()',
  'function predeposit(uint256)',
  'function lock(uint256)',
  'function unlock()',
  'function relock()',
  'function claimFees()',
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
  'function RELOCK_WINDOW() view returns (uint256)',
  'event FeesAdded(uint256 mixETHAmount)',
  'event Locked(address indexed user, uint256 amount)',
  'event CarpetBombProposed(address indexed proposer)',
  'event Voted(address indexed voter, bool support, uint256 weight)',
  'event CarpetBombExecuted(uint256 mixETHCarried)',
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
