import { curveErrorSignatures } from './contractErrors.ts'
import { parseAbi, type Address } from 'viem'

/// Minimal, hand-rolled ABIs — only what the UI touches.

export const factoryAbi = parseAbi([
  'function currentRoundId() view returns (uint256)',
  'function rounds(uint256) view returns (address token, address controller, address hook, bool destroyed, string name, string symbol)',
  'function mixETH() view returns (address)',
  'function referralRegistryOf(uint256) view returns (address)',
  'function poolManager() view returns (address)',
  'function html() view returns (string)',
  // staged spawn (2026-08-30): permissionless rebirth on capped chains
  'function reserveSpawn(uint256 fromRoundId)',
  'function birthStep()',
  'function birthRound() returns (uint256 roundId, address hookAddr)',
  'function reservationActive() view returns (bool)',
  'function reservationPhase() view returns (uint8)',
  // 2026-08-29 UI round views
  'function currentRound() view returns (uint256)',
  'function pspRoundToken(uint256 roundId) view returns (address)',
  'function roundPool(uint256 roundId) view returns (address currency0, address currency1, uint24 fee, int24 spacing, address hook)',
  'function roundInfo(uint256 roundId) view returns (address token, address controller, address hook, address staker, address referralRegistry, string name, string symbol, bool destroyed, uint256 predepositDuration, uint256 vestDuration)',
])

export const controllerAbi = parseAbi([
  ...curveErrorSignatures,
  'error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)',
  'error PepeDnaTaken()',
  'error BadPepeId()',
  'error PredepositClosed()',
  'error CapExceeded()',
  'error WalletCapExceeded()', 
  'function staker() view returns (address)',
  'function predepositState() view returns (uint256 total, uint256 cap, uint256 startTime, bool closed, bool capReached, bool windowOver, bool launchable)',
  'function claimPredepositPSP()',
  'function claimPredepositPSPWithPepe(uint256 pepeId)',
  'function PREDEPOSIT_ART_VERSION() view returns (uint256)',
  'function predeposit(uint256 mixETHAmount)',
  'function predepositWithPepe(uint256 mixETHAmount, uint256 pepeId)',
  'function predepositPepe(address user) view returns (uint256)',
  'function launchPooledBuy()',
  'function PREDEPOSIT_RULES_VERSION() view returns (uint256)',
  'function PREDEPOSIT_DURATION() view returns (uint256)',
  'function PREDEPOSIT_CAP_PER_WALLET() view returns (uint256)',
  'function totalPredepositors() view returns (uint256)',
  'function predeposits(address) view returns (uint256 mixETHAmount, bool claimed)',
  // CLOCK-REDESIGN §4: the clock replaced carpet-bomb governance — detonate
  // is the one-tx kill (flatten + open locks + mark destroyed + spawn)
  'function detonate()',
  'function flatTime() view returns (uint256)',
  'function VEST_DURATION() view returns (uint256)',
  'event Detonated(address indexed by, uint256 potDistributed, address nextRound)',
])

/// PSPStaker — ERC-721 staking positions + pepe art (2026-08-22).
export const stakerAbi = parseAbi([
  'function NFT_INTERFACE_VERSION() view returns (uint256)',
  'function supportsInterface(bytes4 interfaceId) pure returns (bool)',
  'function positions(uint256) view returns (uint256 amount, uint256 startEpoch, uint256 requestEpoch, uint256 creditCheckpoint, uint256 feesPaid)',
  'function pendingFeesOf(uint256 pepeId) view returns (uint256)',
  'function pendingFeesMixETH() view returns (uint256)',
  'function points(uint256) view returns (uint256 epoch, uint256 weight, uint256 slope)',
  'function withdrawableAt(uint256 pepeId) view returns (uint256)',
  'function isWithdrawing(uint256 pepeId) view returns (bool)',
  'function epochSize() view returns (uint256)',
  'function biasOf(uint256 pepeId, uint256 at) view returns (uint256)',
  'function totalLocked() view returns (uint256)',
  'function totalWeight() view returns (uint256)',
  'function balanceOf(address owner) view returns (uint256)',
  'function tokenOfOwnerByIndex(address owner, uint256 index) view returns (uint256)',
  'function primaryOf(address user) view returns (uint256)',
  'function stakedTotalOf(address user) view returns (uint256)',
  'function ownerOf(uint256 tokenId) view returns (address)',
  'function dnaOf(uint256 tokenId) view returns (uint256)',
  'function PEPE_DNA_VERSION() view returns (uint256)',
  'function isPepeAvailable(uint256 id) view returns (bool)',
  'function genesisPepeDna(address wallet) view returns (uint256)',
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
  'function approve(address approved, uint256 tokenId)',
  'function getApproved(uint256 tokenId) view returns (address)',
  'function isApprovedForAll(address owner, address operator) view returns (bool)',
  'function transferFrom(address from, address to, uint256 tokenId)',
  'function safeTransferFrom(address from, address to, uint256 tokenId)',
  'function safeTransferFrom(address from, address to, uint256 tokenId, bytes data)',
  'event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId)',
  'event ApprovalForAll(address indexed owner, address indexed operator, bool approved)',
  'event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)',
  'event Locked(address indexed user, uint256 indexed pepeId, uint256 amount)',
  'event Withdrawn(address indexed user, uint256 indexed pepeId, uint256 amount)',
  'event FeesClaimed(address indexed user, uint256 indexed pepeId, uint256 amount)',
])

/// PepeDescriptor — on-chain SVG art (eth_call-able, pure).
export const descriptorAbi = parseAbi([
  'function renderSVG(uint256 dna) pure returns (string)',
  'function tokenURI(uint256 dna) pure returns (string)',
])

export const hookAbi = parseAbi([
  ...curveErrorSignatures,
  'function ticketPrice() view returns (uint256)',
  'function genesisPotBalance() view returns (uint256)',
  'function TICKET_RULES_VERSION() view returns (uint256)',
  'function SINE_RULES_VERSION() view returns (uint256)',
  'function mode() view returns (uint8)',
  'function reserveMixETH() view returns (uint256)',
  'function totalSupplyPSP() view returns (uint256)',
  'function getBuyOutput(uint256 mixETHInput) view returns (uint256)',
  'function getSellOutput(uint256 pspInput) view returns (uint256)',
  'function SWAP_FEE_BIPS() view returns (uint24)',
  'function swapFeeBps() view returns (uint24)',
  'function curveConfig() view returns (uint256 P0, uint256 timings)',
  'function getCurveZones() view returns ((uint256 startSupply, uint256 endSupply, uint256 rate, bool isExponential)[])',
  // tilted-sine curve (2026-08): struct-free auto-getters on the hook
  'function sineConfigured() view returns (bool)',
  'function sineActive() view returns (bool)',
  'function sineParams() view returns (uint256 p0, uint256 preK, uint256 pTarget, uint256 targetReserve, uint24 ampBps)',
  'function sineCurve() view returns (uint256 p0, uint256 preGrowth, uint256 boot, uint256 targetReserve, uint256 lam, uint256 B, uint256 waveTrend, uint256 amp, uint256 g, uint256 W, uint256 q0)',
  'function sinePriceAt(uint256 R) view returns (uint256)',
  'event Buy(address indexed buyer, uint256 mixETHIn, uint256 pspOut, uint256 newSupply, uint256 newReserveMixETH)',
  'event Sell(address indexed seller, uint256 pspIn, uint256 mixETHOut, uint256 newSupply, uint256 newReserveMixETH)',
  // CLOCK-REDESIGN §1/§2/§4/§5 — BINDING read/write surface (scoopy, 2026-08-31).
  // Declared here so the frontend typechecks before the contracts sibling
  // lands src/; signatures come straight from the spec, nothing invented.
  // detonationAt is SECONDS (block.timestamp domain) — the UI multiplies to ms.
  'function MIN_BUY_INPUT() view returns (uint256)',
  'function TIME_PER_UNIT() view returns (uint256)',
  'function detonationAt() view returns (uint256)',
  'function detWindow() view returns (uint256)',
  // rolling last-10 ticket board: (buyer, pspAmount, mixPaid, ts), newest first
  'function board(uint256 i) view returns (address, uint256, uint256, uint256)',
  'function ticketCount() view returns (uint256)',
  'function potBalance() view returns (uint256)',
  'function claimablePot(address who) view returns (uint256 amount)',
  'function claimPot()',
  // burn PSP for floor pro-rata backing — payout per PSP frozen at detonation
  'function redeemBacking(uint256 pspAmount) returns (uint256 mixETHOut)',
  'event TimeAdded(address indexed buyer, uint256 secondsAdded, uint256 newDetonationAt)',
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
  ...curveErrorSignatures,
  'function zapInBuy((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 minPspOut, uint256 deadline) payable returns (uint256 pspOut)',
  'function buyWithMix((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 mixIn, uint256 minPspOut, uint256 deadline) returns (uint256 pspOut)',
  'function zapInPredeposit(address controller, uint256 minSharesMinted) payable returns (uint256 shares)',
])

export const zapOutAbi = parseAbi([
  ...curveErrorSignatures,
  'function zapOut((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 pspIn, uint256 minMixOut, uint256 deadline) returns (uint256 ethOut)',
  'function sellToMix((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 pspIn, uint256 minMixOut, uint256 deadline) returns (uint256 mixOut)',
])

/// PSPReferralRegistry — per-round referral attribution graph (2026-08-27).
/// buyWithMix binds msg.sender in the purchase; record remains an optional direct path.
export const registryAbi = parseAbi([
  ...curveErrorSignatures,
  'function PURCHASE_REFERRAL_VERSION() view returns (uint256)',
  'function REFERRAL_REWARDS_VERSION() view returns (uint256)',
  'function claimableReferral(address) view returns (uint256)',
  'function claimReferralRewards()',
  'function buyWithMix((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 mixIn, uint256 minPspOut, uint256 deadline, uint256 referrerNftId) returns (uint256 pspOut)',
  'event Referred(address indexed trader, uint256 indexed traderNftId, uint256 indexed referrerNftId)',
  'event ReferralSkipped(address indexed trader, uint256 indexed referrerNftId, bytes4 reason)',
  'function record(uint256 referrerNftId)',
  'function attributed(address) view returns (bool)',
  'function traderRefNftOf(address) view returns (uint256)',
  'function canReferNft(uint256 nftId) view returns (bool)',
])

/// MixETHFaucet — testnet-only: free unlimited mixETH mint (no ETH needed).
export const faucetAbi = parseAbi([
  'function drip(uint256 amount)',
])

/// PSPReinvestor — claims mixETH fees and compounds them into PSP stakes.
export const reinvestorAbi = parseAbi([
  ...curveErrorSignatures,
  'function ATTRIBUTION_VERSION() view returns (uint256)',
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
