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
    error NoCarryBalance();
    error RoundAlreadyDestroyed();

    event RoundDeployed(uint256 indexed roundId, address token, address controller, address hook);
    event ETHCarried(uint256 indexed fromRound, uint256 indexed toRound, uint256 mixETHAmount);

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
    address public constant CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 public currentRoundId;
    mapping(uint256 => Round) public rounds;
    int24 public constant tickSpacing = 60;

    constructor(IPoolManager _poolManager, IERC20 _mixETH) Ownable(msg.sender) {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        if (address(_mixETH) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        mixETH = _mixETH;
    }

    /// @notice Deploy a new PSP round with all contracts wired together
    function deployRound(RoundParams calldata params)
        external
        onlyOwner
        returns (uint256 roundId, address hookAddr)
    {
        return _deployRound(params);
    }

    /// @dev Internal deployment logic, callable from deployRound and deployNextRound
    function _deployRound(RoundParams calldata params)
        internal
        returns (uint256 roundId, address hookAddr)
    {
        // M-3: reject malformed curve configs before anything is deployed
        CurveMath.validate(params.curveConfig);

        roundId = ++currentRoundId;

        // 1. Deploy PSPToken (factory as temp admin)
        PSPToken token = new PSPToken(params.name, params.symbol, address(this));

        // 2. Deploy RoundController
        RoundController controller = new RoundController(
            token,
            mixETH,
            params.curveConfig,
            address(this)
        );

        // 3. Wire controller as token's controller
        token.setController(address(controller));

        // 4. Mine hook address via CREATE2
        //    deployer is address(this) because `new Contract{salt}` deploys from this contract
        //    L-2: BEFORE_INITIALIZE_FLAG added so the hook gates pool initialization
        //    to the canonical {mixETH, PSP} pair (see CurveHook._beforeInitialize).
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(poolManager, controller, params.curveConfig);
        (address expectedAddr, bytes32 salt) = HookMiner.find(
            address(this), flags, type(CurveHook).creationCode, constructorArgs
        );

        // 5. Deploy hook
        CurveHook hook = new CurveHook{salt: salt}(poolManager, controller, params.curveConfig);
        if (address(hook) != expectedAddr) revert HookAddressMismatch();
        hookAddr = address(hook);

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

    /// @notice Carry mixETH from a destroyed round to the next round
    /// @dev L-1: owner-only. Permissionless carry let anyone front-run the
    ///      owner's deployNextRound to drain the carry balance to owner() early,
    ///      forcing NoCarryBalance and a manual rescue flow.
    function carryToNextRound(uint256 fromRoundId) external onlyOwner returns (uint256) {
        Round storage round = rounds[fromRoundId];
        if (address(round.token) == address(0)) revert RoundNotFound();
        if (!round.destroyed) revert RoundNotDestroyed();

        uint256 balance = mixETH.balanceOf(address(this));
        if (balance > 0) {
            // Transfer to owner (factory owner) for redeployment
            // In production, this would auto-deploy the next round
            mixETH.safeTransfer(owner(), balance);
        }

        emit ETHCarried(fromRoundId, currentRoundId + 1, balance);
        return balance;
    }

    /// @notice Deploy the next round, auto-seeded with carried mixETH from a destroyed round.
    /// @dev Combines carryToNextRound + deployRound + predeposit in one call.
    ///      The destroyed round's mixETH becomes the predeposit for the new round.
    function deployNextRound(uint256 fromRoundId, RoundParams calldata params)
        external
        onlyOwner
        returns (uint256 newRoundId, address hookAddr)
    {
        Round storage oldRound = rounds[fromRoundId];
        if (address(oldRound.token) == address(0)) revert RoundNotFound();
        if (!oldRound.destroyed) revert RoundNotDestroyed();

        uint256 carryBalance = mixETH.balanceOf(address(this));
        if (carryBalance == 0) revert NoCarryBalance();

        // Deploy new round (internal deployment)
        (newRoundId, hookAddr) = _deployRound(params);

        // Seed the new round with carried mixETH as a predeposit
        RoundController newController = rounds[newRoundId].controller;
        mixETH.forceApprove(address(newController), carryBalance);
        newController.predeposit(carryBalance);

        // Launch immediately with the carried funds
        newController.launchPooledBuy();

        emit ETHCarried(fromRoundId, newRoundId, carryBalance);
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
