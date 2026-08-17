// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {HookMiner} from "./utils/HookMiner.sol";
import {PSPToken} from "./PSPToken.sol";
import {CurveHook} from "./CurveHook.sol";
import {RoundController} from "./RoundController.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {HookDeployer} from "./HookDeployer.sol";
import {ControllerDeployer} from "./ControllerDeployer.sol";

/// @title PSPFactory — Deploys and manages PSP rounds
/// @notice Each round gets fresh contracts. ETH (as mixETH) is carried from destruction to next round.
contract PSPFactory is Ownable2Step {
    using LPFeeLibrary for uint24;
    using SafeERC20 for IERC20;

    error RoundNotFound();
    error RoundNotDestroyed();
    error ZeroAddress();
    error NotRoundController(); // only the round's own controller may markDestroyed (I-4)
    error HookAddressMismatch();
    error RoundAlreadyDestroyed();
    error NotLatestRound(); // spawn chains strictly forward: latest destroyed round only
    error GameConfigUnset(); // no round has been deployed yet — no curve to inherit
    error SidePotOverdrawn(); // ledger credit exceeds the tokens actually held

    event RoundDeployed(uint256 indexed roundId, address token, address controller, address hook);
    event ETHCarried(uint256 indexed fromRound, uint256 indexed toRound, uint256 mixETHAmount);
    event SidePotCredited(uint256 amount); // dying round's pot redemption received
    event SidePotContributed(uint256 indexed toRound, uint256 mixETHAmount); // released into a new round's curve
    event HtmlUpdated();

    struct Round {
        PSPToken token;
        RoundController controller;
        CurveHook hook;
        bool destroyed;
        string name;
        string symbol;
    }

    struct RoundParams {
        string name;
        string symbol;
        CurveMath.CurveConfig curveConfig;
    }

    IPoolManager public immutable poolManager;
    IERC20 public immutable mixETH;
    /// @dev EIP-170: holds the CurveHook creation-code literal so the factory
    ///      stays under the 24,576-byte limit (see HookDeployer docs)
    HookDeployer public immutable hookDeployer;
    /// @dev EIP-170: holds RoundController's + PSPToken's creation code
    ControllerDeployer public immutable controllerDeployer;

    uint256 public currentRoundId;
    mapping(uint256 => Round) public rounds;
    int24 public constant tickSpacing = 60;

    /// @dev Curve inherited by every spawned round. Captured from the last
    ///      explicit deployRound() call — no drift between genesis round and
    ///      its descendants.
    CurveMath.CurveConfig public gameCurve;

    /// @dev Ring-fenced protocol reserve, fed by dying rounds' side-pot
    ///      redemptions (25bps swap fee, accrued as PSP, exited at average
    ///      backing on carpet bomb). NOT part of the generic carry: at spawn
    ///      it is forwarded to the new round via potDeposit() — it thickens
    ///      the genesis curve for everyone, cap-exempt and share-less. The
    ///      public predeposit cap (500 mixETH) applies to USERS only, so a
    ///      round can open with 500 user mixETH + whatever the pot holds.
    ///      Invariant: sidePot <= mixETH.balanceOf(factory) at all times
    ///      (credits only follow a matching transfer from a round controller).
    uint256 public sidePot;

    /// @dev Naming for spawned rounds: "<baseName> <id>" / "<baseSymbol><id>".
    string public baseName = "Positive Sum Pepes";
    string public baseSymbol = "PSP";

    /// @dev The walk-away test: the full front-end, served from the contract.
    ///      Anyone can fetch html() over any RPC and render it locally with
    ///      zero backend. Updatable by owner so the UI can evolve without a
    ///      redeploy; the deployed UI keeps working forever either way.
    string private _html;

    constructor(IPoolManager _poolManager, IERC20 _mixETH, HookDeployer _hookDeployer, ControllerDeployer _controllerDeployer)
        Ownable(msg.sender)
    {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        if (address(_mixETH) == address(0)) revert ZeroAddress();
        if (address(_hookDeployer) == address(0)) revert ZeroAddress();
        if (address(_controllerDeployer) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        mixETH = _mixETH;
        hookDeployer = _hookDeployer;
        controllerDeployer = _controllerDeployer;
    }

    // ─────────────── Walk-away UI ───────────────

    function setHtml(string calldata h) external onlyOwner {
        _html = h;
        emit HtmlUpdated();
    }

    function html() external view returns (string memory) {
        return _html;
    }

    /// @notice Deploy a new PSP round with all contracts wired together
    function deployRound(RoundParams calldata params)
        external
        onlyOwner
        returns (uint256 roundId, address hookAddr)
    {
        return _deployRound(params);
    }

    /// @dev Internal deployment logic, callable from deployRound and spawnNextRound
    function _deployRound(RoundParams memory params)
        internal
        returns (uint256 roundId, address hookAddr)
    {
        // M-3: curve validation happens in the RoundController constructor —
        // inlining CurveMath here pushed the factory past EIP-170's 24KB limit
        gameCurve = params.curveConfig;

        roundId = ++currentRoundId;

        // 1. Deploy PSPToken (factory as temp admin) — via ControllerDeployer
        //    (EIP-170: keeps PSPToken's creation code out of this contract)
        PSPToken token = controllerDeployer.deployToken(params.name, params.symbol, address(this));

        // 2. Deploy RoundController — via ControllerDeployer (EIP-170)
        RoundController controller = controllerDeployer.deployController(
            token, mixETH, params.curveConfig, address(this)
        );

        // 3. Wire controller as token's controller
        token.setController(address(controller));

        // 4. Mine + deploy hook via the dedicated deployer
        //    (EIP-170: keeps CurveHook's creation code out of this contract —
        //    the factory was 41KB with it embedded twice. The deployer holds
        //    the literal once and verifies the mined address on-chain.)
        (address hookAddress,) = hookDeployer.deployHook(
            poolManager, address(controller), params.curveConfig
        );
        CurveHook hook = CurveHook(hookAddress);
        hookAddr = hookAddress;

        // 6. Wire hook to controller
        controller.setHook(hook);

        // 6b. Wire controller's roundId in factory
        controller.setFactoryRoundId(roundId);

        // 7. Initialize V4 pool
        Currency currency0 = Currency.wrap(address(mixETH));
        Currency currency1 = Currency.wrap(address(token));
        if (currency0 > currency1) {
            (currency0, currency1) = (currency1, currency0);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000, // dynamic fee flag
            tickSpacing: tickSpacing,
            hooks: hook
        });

        // Initialize pool (price doesn't matter for custom curve, use 1:1)
        poolManager.initialize(key, 79228162514264337593543950336); // sqrt(1) in Q64.96

        // Store round
        rounds[roundId] = Round({
            token: token,
            controller: controller,
            hook: hook,
            destroyed: false,
            name: params.name,
            symbol: params.symbol
        });

        emit RoundDeployed(roundId, address(token), address(controller), address(hook));
    }

    /// @notice Spawn the next round from the latest destroyed one — permissionless.
    /// @dev The game loop's rebirth step. Normally invoked by the dying round's
    ///      carpetBomb() (itself permissionless), but callable by anyone as a
    ///      fallback: the strict latest-destroyed-round guard makes spamming
    ///      impossible (each round can spawn exactly one successor, and only
    ///      while it is the latest).
    ///
    ///      The destroyed round's carry (reserve + staker fees) becomes the new
    ///      round's opening predeposit via seedCarry() (cap-exempt), and the
    ///      ring-fenced side pot is forwarded separately via potDeposit() —
    ///      it buys NO predeposit shares, it thickens the genesis curve for
    ///      every participant of the new round (cap-exempt, share-less).
    ///      Zero carry / zero pot are both fine — the round simply opens empty
    ///      and waits for the public window (or owner launch).
    function spawnNextRound(uint256 fromRoundId) external returns (uint256 newRoundId, address hookAddr) {
        Round storage from = rounds[fromRoundId];
        if (address(from.token) == address(0)) revert RoundNotFound();
        if (!from.destroyed) revert RoundNotDestroyed();
        if (fromRoundId != currentRoundId) revert NotLatestRound();
        if (gameCurve.zones.length == 0) revert GameConfigUnset();

        // Generic carry = factory balance MINUS the ring-fenced side pot.
        // Both pots were funded by this round's death; they leave separately.
        uint256 carry = mixETH.balanceOf(address(this)) - sidePot;
        uint256 pot = sidePot;

        newRoundId = currentRoundId + 1;
        RoundParams memory params;
        params.name = string.concat(baseName, " ", _itoa(newRoundId));
        params.symbol = string.concat(baseSymbol, _itoa(newRoundId));
        params.curveConfig = gameCurve;
        (newRoundId, hookAddr) = _deployRound(params);

        if (carry > 0) {
            RoundController newController = rounds[newRoundId].controller;
            mixETH.forceApprove(address(newController), carry);
            newController.seedCarry(carry);
        }

        if (pot > 0) {
            RoundController newController = rounds[newRoundId].controller;
            mixETH.forceApprove(address(newController), pot);
            newController.potDeposit(pot);
            sidePot = 0;
            emit SidePotContributed(newRoundId, pot);
        }

        emit ETHCarried(fromRoundId, newRoundId, carry);
    }

    /// @dev Minimal uint → decimal string (round ids are small; loop is short)
    function _itoa(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        for (uint256 x = v; x > 0; x /= 10) digits++;
        bytes memory b = new bytes(digits);
        for (uint256 i = digits; i > 0; i--) {
            b[i - 1] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(b);
    }

    // ─────────────── Side pot (protocol reserve) ───────────────

    /// @notice Credit the side pot. Called by the dying round's controller
    ///         immediately after transferring its pot redemption mixETH here.
    /// @dev Ledger-only: the tokens must already be at the factory. Guarded to
    ///      the CURRENT round's controller so nobody can earmark the generic
    ///      carry as pot (earmarking changes next round's allocation — pot
    ///      funds buy no predeposit shares, carry does).
    function creditSidePot(uint256 amount) external {
        if (msg.sender != address(rounds[currentRoundId].controller)) revert NotRoundController();
        if (mixETH.balanceOf(address(this)) < sidePot + amount) revert SidePotOverdrawn();
        sidePot += amount;
        emit SidePotCredited(amount);
    }

    /// @notice Mark a round as destroyed (called by its controller during destruction)
    function markDestroyed(uint256 roundId) external {
        Round storage round = rounds[roundId];
        if (msg.sender != address(round.controller)) revert NotRoundController();
        round.destroyed = true;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }
}
