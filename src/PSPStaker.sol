// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICurveHook} from "./interfaces/ICurveHook.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";

/// @dev Minimal descriptor slice (EIP-170 budget): metadata + SVG from DNA.
interface IPepeDescriptor {
    function tokenURI(uint256 dna) external pure returns (string memory);
}

/// @title PSPStaker — ERC-721 staking positions (vlCVX-style, tradeable)
/// @notice Every locked position is an NFT. One position per address (amounts
///         merge on top-up, timer resets — same semantics as the old ledger).
///         Transferring the NFT moves the WHOLE position: principal, accrued
///         fees (rewardDebt rides along), and the unlock clock. Locked
///         positions are therefore tradeable — sell your lock, keep your life.
///
///         Hand-rolled minimal ERC-721 (no OZ): the contract is born inside
///         RoundController's constructor and its creation code embeds in the
///         controller's runtime — every byte counts against EIP-170.
///
///         Genesis lock: the predeposit pool's virtual position lives at this
///         contract's own address, never minted as an NFT, never transferable.
///
///         Pepe art (2026-08-22): each NFT carries deterministic DNA
///         (keccak(tokenId)) rendered by PepeDescriptor. lock(0) mints the
///         NFT with no stake — the pepe-first onboarding path. unlock() keeps
///         the NFT (a "husk"): the pepe remains with its owner forever as
///         proof of participation; re-locking revives the husk.
contract PSPStaker {
    using SafeERC20 for IERC20;

    // ─────────────── Errors ───────────────
    error ZeroAmount();
    error NotLocker();
    error LockNotExpired();
    error TooEarlyToRelock();
    error RoundFlattened();
    error RoundDead();
    error NothingToClaim();
    error RecipientHasPosition(); // D9: recipient must unlock first
    error NotNftOwner();
    error NotAuthorizedNft();
    error ZeroAddress();
    error NotController();
    error BadNftTransfer();
    error BadPepeId();      // chosen-id path: zero or already claimed
    error PepeAlreadyOwned(); // lockWithPepe with an existing NFT — top up via lock()

    // ─────────────── Events (ERC-721) ───────────────
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // ─────────────── Events (staking) ───────────────
    event Locked(address indexed user, uint256 amount);
    event Unlocked(address indexed user, uint256 amount);
    event Relocked(address indexed user, uint256 newUnlockTime);
    event FeesClaimed(address indexed user, uint256 amount);
    event FeesForfeited(address indexed user, uint256 mixETHAmount);

    // ─────────────── Immutables ───────────────
    IERC20 public immutable psp;
    IRoundController public immutable controller;
    uint256 public constant PRECISION = 1e18;

    // ─────────────── Staking state ───────────────
    struct Position {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lockTime;
        uint256 unlockTime;
    }
    /// @dev address-keyed: one position per address (Model B, design doc).
    mapping(address => Position) public positions;
    uint256 public totalLocked;
    uint256 public accFeePerShareMixETH;
    uint256 public pendingFeesMixETH;

    // ─────────────── ERC-721 state ───────────────
    string public constant name = "Positive Sum Pepe Position";
    string public constant symbol = "PSPP";
    uint256 public nextTokenId = 1;
    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _tokenOf; // 0 = none
    mapping(address => mapping(address => bool)) private _operator;

    // ─────────────── Pepe art state ───────────────
    /// @dev PepeDescriptor (SVG + metadata), wired at construction via the
    ///      factory. Zero = this round carries no art (tokenURI is empty).
    address public immutable descriptor;

    constructor(IERC20 _psp, IRoundController _controller, address descriptor_) {
        if (address(_psp) == address(0)) revert ZeroAddress();
        if (address(_controller) == address(0)) revert ZeroAddress();
        psp = _psp;
        controller = _controller;
        descriptor = descriptor_;
    }

    // ─────────────── ERC-165 / ERC-721 surface ───────────────

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x80ac58cd || id == 0x01ffc9a7; // ERC-721, ERC-165
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _ownerOf[tokenId];
        if (o == address(0)) revert NotNftOwner();
        return o;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _tokenOf[owner] != 0 ? 1 : 0;
    }

    function tokenOf(address owner) external view returns (uint256) {
        return _tokenOf[owner];
    }

    /// @notice deterministic per-token generative DNA (full word; the
    ///         descriptor clamps every axis — any dna renders). Pure view:
    ///         every conceivable tokenId has a dna, live or not.
    ///         encodePacked(uint) is byte-identical to encode(uint) —
    ///         minus the 32-byte offsets head — so the dna is unchanged.
    function dnaOf(uint256 tokenId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(tokenId)));
    }

    /// @dev Raw mint with a specific id — validation is the CALLER's job
    ///      (sequential ids are skip-loop-fresh; lockWithPepe guards its own).
    function _mint(address to, uint256 id) internal {
        _ownerOf[id] = to;
        _tokenOf[to] = id;
        emit Transfer(address(0), to, id);
    }

    /// @dev Mint with the next free sequential id (skips user-chosen ids).
    function _mintSequential(address to) internal {
        while (_ownerOf[nextTokenId] != address(0)) ++nextTokenId;
        _mint(to, nextTokenId++);
    }

    /// @notice token metadata: the pepe rendered from this token's DNA.
    ///         Reverts on a round deployed without art (descriptor == 0).
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_ownerOf[tokenId] == address(0)) revert NotNftOwner();
        return IPepeDescriptor(descriptor).tokenURI(dnaOf(tokenId));
    }

    /// @dev per-token approvals dropped (EIP-170, 2026-08-22): operator
    ///      approvals (setApprovalForAll) remain — that's the only path
    ///      marketplaces (Seaport) use.
    function setApprovalForAll(address operator, bool approved) external {
        _operator[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operator[owner][operator];
    }

    /// @notice Transfer a position NFT — moves principal + accrued fees +
    ///         unlock clock together. Recipient must hold no position.
    function transferFrom(address from, address to, uint256 tokenId) external {
        _transferPosition(from, to, tokenId);
    }

    function _transferPosition(address from, address to, uint256 tokenId) internal {
        if (to == address(0) || to == address(this)) revert BadNftTransfer();
        address o = _ownerOf[tokenId];
        if (o == address(0) || o != from) revert NotNftOwner();
        if (msg.sender != from && !_operator[from][msg.sender]) {
            revert NotAuthorizedNft();
        }
        // D9: positions are address-keyed; a recipient with an existing
        // LIVE position cannot merge on-chain — they unlock first (or
        // transfer to a fresh address). A husk holder (unlocked, NFT kept)
        // CAN receive: the position merges onto their surviving NFT and the
        // sender's NFT burns.
        bool recipientHusk = _tokenOf[to] != 0 && positions[to].amount == 0;
        if (_tokenOf[to] != 0 && !recipientHusk) revert RecipientHasPosition();

        // Move the whole position — rewardDebt rides, so accrued fees pay to
        // the NEW owner on their next claim. (User spec: transfer moves lock
        // + rewards.)
        positions[to] = positions[from];
        delete positions[from];

        if (recipientHusk) {
            // Position rides the recipient's husk; sender's NFT retires.
            _ownerOf[tokenId] = address(0);
            _tokenOf[from] = 0;
            emit Transfer(from, address(0), tokenId);
        } else {
            _ownerOf[tokenId] = to;
            _tokenOf[from] = 0;
            _tokenOf[to] = tokenId;
            emit Transfer(from, to, tokenId);
        }
    }

    // ─────────────── Staking ───────────────

    /// @dev Z-1: no locking into a dying/dead round.
    function _requireAlive() internal view {
        if (controller.flatTime() != 0) revert RoundDead();
        address hook = controller.hookAddress();
        // Mode order: Predeposit < Active < Flat < Destroyed — the two
        // dead modes are exactly mode() >= Flat.
        if (hook != address(0) && ICurveHook(hook).mode() >= ICurveHook.Mode.Flat) revert RoundDead();
    }

    /// @notice Lock PSP — mints a position NFT on first lock, tops up
    ///         (claiming fees, resetting the clock) afterwards.
    ///         amount == 0 mints the NFT with NO stake (pepe-first path:
    ///         arrive, get your pepe, stake when ready). Never resets a clock.
    function lock(uint256 amount) external {
        _requireAlive();
        if (amount != 0) _stake(amount);
        if (_tokenOf[msg.sender] == 0) _mintSequential(msg.sender);
    }

    /// @notice Lock with a CHOSEN pepe — the art-selection path. A pepe's
    ///         dna is keccak(pepeId), so pick your art off-chain (renderSVG
    ///         on candidate ids) and commit the one you love. amount == 0
    ///         hatches the pepe with no stake. Caller must hold no pepe
    ///         yet — top up an existing one via lock().
    function lockWithPepe(uint256 amount, uint256 pepeId) external {
        _requireAlive();
        if (_tokenOf[msg.sender] != 0) revert PepeAlreadyOwned();
        if (pepeId == 0 || _ownerOf[pepeId] != address(0)) revert BadPepeId();
        if (amount != 0) _stake(amount);
        _mint(msg.sender, pepeId);
    }

    /// @dev shared stake body for lock()/lockWithPepe().
    function _stake(uint256 amount) internal {
        _updateAccumulator();
        Position storage pos = positions[msg.sender];
        if (pos.amount > 0) {
            _claimPendingFees(msg.sender, true);
        }

        psp.safeTransferFrom(msg.sender, address(this), amount);

        pos.amount += amount;
        pos.rewardDebt = (pos.amount * accFeePerShareMixETH) / PRECISION;
        pos.lockTime = block.timestamp;
        pos.unlockTime = block.timestamp + controller.LOCK_DURATION();
        totalLocked += amount;

        emit Locked(msg.sender, amount);
    }

    /// @notice Withdraw after expiry (or any time once the round is flat).
    ///         The NFT SURVIVES as a husk — the pepe stays with its owner
    ///         forever, proof they participated. Re-locking revives it.
    function unlock() external {
        Position storage pos = positions[msg.sender];
        if (pos.amount == 0) revert NotLocker();
        if (controller.flatTime() == 0 && block.timestamp < pos.unlockTime) revert LockNotExpired();

        _updateAccumulator();
        _claimPendingFees(msg.sender, true);

        uint256 amount = pos.amount;
        totalLocked -= amount;
        // Position goes; NFT + DNA stay (proof of participation).
        delete positions[msg.sender];

        psp.safeTransfer(msg.sender, amount);

        emit Unlocked(msg.sender, amount);
    }

    /// @notice Extend the lock — only inside the relock window.
    function relock() external {
        Position storage pos = positions[msg.sender];
        if (pos.amount == 0) revert NotLocker();
        if (controller.flatTime() != 0) revert RoundFlattened();
        if (block.timestamp < pos.unlockTime - controller.RELOCK_WINDOW()) revert TooEarlyToRelock();

        _updateAccumulator();
        _claimPendingFees(msg.sender, true);

        pos.unlockTime = block.timestamp + controller.EXTEND_DURATION();
        pos.lockTime = block.timestamp;

        emit Relocked(msg.sender, pos.unlockTime);
    }

    function claimFees() external {
        if (positions[msg.sender].amount == 0) revert NotLocker();
        _updateAccumulator();
        uint256 pending = pendingFeesOf(msg.sender);
        if (pending == 0) revert NothingToClaim();
        _claimPendingFees(msg.sender, false); // strict: explicit intent
        emit FeesClaimed(msg.sender, pending);
    }

    // ─────────────── Controller entry points ───────────────

    /// @dev Genesis virtual lock — the whole claimable predeposit pool,
    ///      locked at launch (NK24: kills the first-locker fee-capture
    ///      window). Never an NFT, never transferable: it lives at this
    ///      contract's own address slot.
    function lockGenesis(uint256 amount) external {
        if (msg.sender != address(controller)) revert NotController();
        if (amount == 0) revert ZeroAmount();
        Position storage genesis = positions[address(this)];
        genesis.amount += amount;
        genesis.rewardDebt = (genesis.amount * accFeePerShareMixETH) / PRECISION;
        genesis.lockTime = block.timestamp;
        genesis.unlockTime = block.timestamp + controller.LOCK_DURATION();
        totalLocked += amount;
    }

    /// @dev Predeposit share claim: move `share` out of the genesis position
    ///      into `user`'s position (minting their NFT if first). Pays out any
    ///      pending fees on an existing position, plus the fees the share
    ///      accrued since the genesis lock (computed against THIS
    ///      accumulator — rewardDebt at launch was zero). Forfeit-on-
    ///      shortfall semantics (M-2): a fee leg never traps principal.
    function claimGenesisShare(address user, uint256 share) external {
        if (msg.sender != address(controller)) revert NotController();

        _updateAccumulator();

        Position storage genesis = positions[address(this)];
        Position storage pos = positions[user];

        if (pos.amount > 0) {
            _claimPendingFees(user, true);
        }
        uint256 accruedOnShare = (share * accFeePerShareMixETH) / PRECISION;
        if (accruedOnShare > 0) {
            _payFees(user, accruedOnShare, true);
        }

        genesis.amount -= share;
        genesis.rewardDebt = (genesis.amount * accFeePerShareMixETH) / PRECISION;

        pos.amount += share;
        pos.rewardDebt = (pos.amount * accFeePerShareMixETH) / PRECISION;
        pos.lockTime = block.timestamp;
        pos.unlockTime = block.timestamp + controller.LOCK_DURATION();
        // totalLocked unchanged: share moves between positions

        if (_tokenOf[user] == 0) _mintSequential(user);

        emit Locked(user, share);
    }

    /// @dev Fee accumulator feed — controller forwards hook addFees() here.
    function addFees(uint256 mixETHAmount) external {
        if (msg.sender != address(controller)) revert NotController();
        pendingFeesMixETH += mixETHAmount;
        _updateAccumulator();
    }

    // ─────────────── Fee internals ───────────────

    function pendingFeesOf(address user) public view returns (uint256) {
        Position storage pos = positions[user];
        return (pos.amount * accFeePerShareMixETH) / PRECISION - pos.rewardDebt;
    }

    function _claimPendingFees(address user, bool forfeitOnShortfall) internal {
        uint256 pending = pendingFeesOf(user);
        if (pending == 0) return;
        Position storage pos = positions[user];
        pos.rewardDebt = (pos.amount * accFeePerShareMixETH) / PRECISION;
        _payFees(user, pending, forfeitOnShortfall);
    }

    /// @dev M-2: on the forfeit path a hook surplus shortfall burns the fees
    ///      rather than reverting — a fee leg must never trap PSP principal.
    function _payFees(address user, uint256 amount, bool forfeitOnShortfall) internal {
        address hook = controller.hookAddress();
        if (forfeitOnShortfall) {
            try ICurveHook(hook).sendFees(user, amount) {}
            catch {
                emit FeesForfeited(user, amount);
            }
        } else {
            ICurveHook(hook).sendFees(user, amount);
        }
    }

    function _updateAccumulator() internal {
        if (totalLocked == 0 || pendingFeesMixETH == 0) return;
        accFeePerShareMixETH += (pendingFeesMixETH * PRECISION) / totalLocked;
        pendingFeesMixETH = 0;
    }

    // ─────────────── Registry oracle views ───────────────

    function lockedPSPOf(address user) external view returns (uint256) {
        return positions[user].amount;
    }
    // (lockTime/unlockTime read via positions(user) — EIP-170 budget,
    //  the aliases were dropped 2026-08-22)
}
