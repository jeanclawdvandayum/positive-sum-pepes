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
import {SineMath} from "./libraries/SineMath.sol";
import {HookDeployer} from "./HookDeployer.sol";
import {ControllerDeployer, TokenDeployer} from "./ControllerDeployer.sol";
import {StakerDeployer} from "./StakerDeployer.sol";
import {IRoundController} from "./interfaces/IRoundController.sol";

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

    event RoundDeployed(uint256 indexed roundId, address token, address controller, address hook, address staker);
    event ETHCarried(uint256 indexed fromRound, uint256 indexed toRound, uint256 mixETHAmount);
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

    /// @dev EIP-170 vessel (2026-08-23): carries PSPStaker's creation code
    ///      so RoundController's creation program (embedded in the
    ///      ControllerDeployer above) stays lean.
    StakerDeployer public immutable stakerDeployer;

    /// @dev EIP-170 vessel for PSPToken's creation code. ONE instance from
    ///      construction, shared by every round (was: a fresh throwaway
    ///      deployer per round, 1.07M gas each). Carries the salted
    ///      deploy/predict pair the staged spawn needs.
    TokenDeployer public immutable tokenDeployer;

    /// @dev Global pepe-art descriptor wired into every round's staker at
    ///      construction (DNA → SVG + metadata). Zero until the factory
    ///      owner sets it; rounds deployed before then carry no art.
    address public descriptor;

    /// @notice Wire the generative-art renderer for all future rounds.
    function setDescriptor(address descriptor_) external onlyOwner {
        descriptor = descriptor_;
    }

    uint256 public currentRoundId;
    mapping(uint256 => Round) public rounds;
    int24 public constant tickSpacing = 60;

    /// @dev Curve inherited by every spawned round. Captured from the last
    ///      explicit deployRound() call — no drift between genesis round and
    ///      its descendants.
    CurveMath.CurveConfig public gameCurve;

    /// @notice Tilted-sine flavor (2026-08-29): when armed, every round's hook
    ///         prices off the parametric sine curve (see SineMath). Survives
    ///         rebirths like gameCurve.
    SineMath.Params public gameSineParams;
    bool public useSine;

    /// @dev Owner arms the sine flavor for current + future rounds. Params
    ///      validated (ampBps ≤ 10000 = 45° tilt cap). Call before deployRound.
    function configureSine(SineMath.Params calldata p) external onlyOwner {
        SineMath.validate(p);
        gameSineParams = p;
        useSine = true;
    }

    /// @dev Referral graph — permanent, cross-round. Born here so every
    ///      spawned round wires into the SAME social graph: the factory
    ///      points it at each new round's staker (min-stake oracle) and
    ///      authorizes each new hook as a lazy recorder.
    mapping(uint256 => address) public referralRegistryOf;

    /// @dev Minimum locked PSP to qualify as a referrer (skin in the game).
    uint256 public constant REFERRAL_MIN_STAKE = 1000e18;

    /// @dev Ring-fenced side pot REMOVED (2026-08-19) — the 25bps pot fee is
    ///      dead; the 50bps referral carve-out pays out live in mixETH. The
    ///      whole factory balance is now the generic carry.

    /// @dev Naming for spawned rounds: "<baseName> <id>" / "<baseSymbol><id>".
    string public baseName = "Positive Sum Pepes";
    string public baseSymbol = "PSP";

    /// @dev The walk-away test: the full front-end, served from the contract.
    ///      Anyone can fetch html() over any RPC and render it locally with
    ///      zero backend. Updatable by owner so the UI can evolve without a
    ///      redeploy; the deployed UI keeps working forever either way.
    string private _html;

    /// @dev `_timings == 0` → mainnet defaults, forwarded to every round's
    ///      RoundController. See RoundController "Timing profile".
    constructor(IPoolManager _poolManager, IERC20 _mixETH, HookDeployer _hookDeployer, ControllerDeployer _controllerDeployer, StakerDeployer _stakerDeployer, uint256 _timings)
        Ownable(msg.sender)
    {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        if (address(_mixETH) == address(0)) revert ZeroAddress();
        if (address(_hookDeployer) == address(0)) revert ZeroAddress();
        if (address(_controllerDeployer) == address(0)) revert ZeroAddress();
        if (address(_stakerDeployer) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        mixETH = _mixETH;
        hookDeployer = _hookDeployer;
        tokenDeployer = new TokenDeployer();
        controllerDeployer = _controllerDeployer;
        stakerDeployer = _stakerDeployer;
        roundTimings = _timings;
    }

    uint256 public immutable roundTimings;

    // ─────────────── Walk-away UI ───────────────

    function setHtml(string calldata h) external onlyOwner {
        _html = h;
        emit HtmlUpdated();
    }

    function html() external view returns (string memory) {
        return _html;
    }

    /// @notice Deploy a new PSP round with all contracts wired together
    /// @dev Composed path (owner): reserve + birth in one tx. Carries the
    ///      flag-mine tail (~0.03% of draws exhaust the 131k bound and
    ///      revert the whole tx — retry with fresh block entropy; state
    ///      rolls back clean). The PERMISSIONLESS rebirth path avoids the
    ///      lottery entirely: finalizeCarpet reserves (bounded, deposit-
    ///      free), anyone births (zero variance).
    function deployRound(RoundParams calldata params)
        external
        onlyOwner
        returns (uint256 roundId, address hookAddr)
    {
        gameCurve = params.curveConfig;
        _reserve(0, params.name, params.symbol);
        return _birth(params.name, params.symbol);
    }

    // ─────────────── staged spawn (2026-08-30) ───────────────
    //
    // deployRound used to birth an entire round in one tx: six contract
    // creations + on-chain flag mining. Measured (DeployGasSpread.t.sol):
    // ~12.06M of constant deposits plus a geometric mining tail observed
    // to +8.4M — 5/12 draws breach Base Sepolia's 15M per-tx cap, 2/12
    // breach mainnet's 16.78M. Payload cuts can't fix a lottery; staging
    // kills it:
    //
    //   reserveSpawn — predict EVERY round address via create2 (salts
    //     from block-context entropy, so nothing is computable before the
    //     block that runs it), bounded-mine the hook salt, commit. No
    //     deposits exist, so exhaustion reverts CHEAP and the next block
    //     re-rolls the salt space. Worst case ~6.5M.
    //   birthRound — execute the six create2s with the committed salts +
    //     wiring + pool init. Every byte of gas is deterministic: zero
    //     mining, zero variance, ~11M flat.
    //
    // Squatting a committed address requires the identical deployer +
    // salt + initcode hash — i.e. deploying the IDENTICAL canonical
    // contract — so birth treats "prediction already occupied" as
    // "someone helped" and wires it (idempotent). Landing different code
    // there is a 160-bit preimage break.
    //
    // No admin exists to wire or renounce: both stages are permissionless
    // and guarded (one active reservation; latest-destroyed-round only;
    // config committed by hash so mid-flight gameCurve changes fail
    // closed with ReservationStale instead of birthing a mismatched set).

    struct SpawnReservation {
        uint128 fromRoundId; // destroyed round whose carry seeds this one (0 = owner genesis)
        uint128 newRoundId;
        bytes32 tokenSalt;
        bytes32 controllerSalt;
        bytes32 hookSalt;
        address token;      // predictions — birth verifies each
        address controller;
        address hook;
        bytes32 contextHash; // keccak(config-with-timings, descriptor, name, symbol)
        bool active;
    }

    SpawnReservation public reservation;

    /// @dev Hook flag-mine bound. 14-bit match ⇒ geometric: median ~2^13
    ///      candidates (~1.1M gas @ ~87 gas/iter, measured). 131,072 gives
    ///      ~0.03% exhaustion (e^-8) — worst-case reserve ≈ 12.2M, inside
    ///      every per-tx cap — and exhaustion reverts the deposit-free
    ///      reserve anyway.
    uint256 public constant HOOK_SCAN_CAP = 131_072;

    event SpawnReserved(
        uint256 indexed newRoundId,
        address indexed token,
        address indexed controller,
        address hook,
        address staker,
        address registry,
        bytes32 hookSalt
    );

    error ReservationActive();
    error NoReservation();
    error ReservationStale();
    error PredictMismatch();

    /// @notice Stage 1 (permissionless): commit the next round's full
    ///         address set. Rebirth-path only — genesis goes through
    ///         deployRound.
    function reserveSpawn(uint256 fromRoundId) external {
        Round storage from = rounds[fromRoundId];
        if (address(from.token) == address(0)) revert RoundNotFound();
        if (!from.destroyed) revert RoundNotDestroyed();
        if (fromRoundId != currentRoundId) revert NotLatestRound();
        if (gameCurve.zones.length == 0) revert GameConfigUnset();
        if (reservation.active) revert ReservationActive();

        uint256 newRoundId = currentRoundId + 1;
        _reserve(
            uint128(fromRoundId),
            string.concat(baseName, " ", _itoa(newRoundId)),
            string.concat(baseSymbol, _itoa(newRoundId))
        );
    }

    /// @notice Stage 2 (permissionless): birth the reserved round. Open
    ///         to anyone — bundling birth with the first buy captures the
    ///         launch edge, which pays for the gas.
    function birthRound() external returns (uint256 roundId, address hookAddr) {
        SpawnReservation memory r = reservation;
        if (!r.active) revert NoReservation();
        return _birth(
            string.concat(baseName, " ", _itoa(r.newRoundId)),
            string.concat(baseSymbol, _itoa(r.newRoundId))
        );
    }

    /// @notice Owner escape hatch: void a reservation whose committed
    ///         context went stale (gameCurve/descriptor changed mid-
    ///         flight). Re-reserving with the new context follows.
    function voidReservation() external onlyOwner {
        if (!reservation.active) revert NoReservation();
        reservation.active = false;
    }

    /// @dev Prediction + bounded mining. No contracts are created here.
    function _reserve(uint128 fromRoundId, string memory name, string memory symbol) internal {
        if (reservation.active) revert ReservationActive();
        uint256 newRoundId = currentRoundId + 1;

        CurveMath.CurveConfig memory cfg = gameCurve;
        cfg.timings = roundTimings;

        // Salts: block-context keyed (C-1 posture — unknowable before the
        // block that runs the reserve), one root, role-separated twigs.
        bytes32 root = keccak256(abi.encode(block.prevrandao, block.timestamp, block.number, newRoundId));
        bytes32 tokenSalt = keccak256(abi.encode(root, "token"));
        bytes32 controllerSalt = keccak256(abi.encode(root, "controller"));

        address token = tokenDeployer.predictToken(tokenSalt, name, symbol, address(this));
        address controller = controllerDeployer.predictController(
            controllerSalt, PSPToken(token), mixETH, cfg, address(this), descriptor, stakerDeployer
        );
        // staker + registry salts derive from the predicted controller —
        // the same derivation the controller's own constructor applies.
        bytes32 stakerSalt = keccak256(abi.encode(controller, "psp-staker"));
        address staker = stakerDeployer.predictStaker(
            stakerSalt, IERC20(token), IRoundController(controller), descriptor
        );
        bytes32 registrySalt = keccak256(abi.encode(controller, "psp-registry"));
        address registry = controllerDeployer.predictRegistry(registrySalt, staker, REFERRAL_MIN_STAKE);

        (address hook, bytes32 hookSalt) =
            hookDeployer.mineHook(poolManager, controller, registry, cfg, HOOK_SCAN_CAP);

        reservation = SpawnReservation({
            fromRoundId: fromRoundId,
            newRoundId: uint128(newRoundId),
            tokenSalt: tokenSalt,
            controllerSalt: controllerSalt,
            hookSalt: hookSalt,
            token: token,
            controller: controller,
            hook: hook,
            contextHash: keccak256(abi.encode(cfg, descriptor, name, symbol)),
            active: true
        });

        emit SpawnReserved(newRoundId, token, controller, hook, staker, registry, hookSalt);
    }

    /// @dev Deterministic birth from the committed reservation. Skips any
    ///      create2 whose predicted address is already occupied (identical
    ///      contract — see staging notes above). Everything that can fail
    ///      runs BEFORE poolManager.initialize: the pool manager's state
    ///      does not roll back with this tx, so a post-initialize revert
    ///      would brick the reservation against AlreadyInitialized.
    function _birth(string memory name, string memory symbol)
        internal
        returns (uint256 roundId, address hookAddr)
    {
        SpawnReservation memory r = reservation;
        if (!r.active) revert NoReservation();

        CurveMath.CurveConfig memory cfg = gameCurve;
        cfg.timings = roundTimings;
        if (keccak256(abi.encode(cfg, descriptor, name, symbol)) != r.contextHash) {
            revert ReservationStale();
        }

        // 1. token
        PSPToken token = PSPToken(r.token);
        if (address(token).code.length == 0) {
            address t = address(
                tokenDeployer.deployTokenAt(r.tokenSalt, name, symbol, address(this))
            );
            if (t != r.token) revert PredictMismatch();
        }

        // 2. controller (+ staker in its constructor, salted from the
        //    controller's own predicted address)
        RoundController controller = RoundController(r.controller);
        if (address(controller).code.length == 0) {
            address c = address(
                controllerDeployer.deployControllerAt(
                    r.controllerSalt, token, mixETH, cfg, address(this), descriptor, stakerDeployer
                )
            );
            if (c != r.controller) revert PredictMismatch();
        }

        // 3. wire controller as token's controller
        token.setController(address(controller));

        // 3b. referral registry
        bytes32 registrySalt = keccak256(abi.encode(r.controller, "psp-registry"));
        address registry = controllerDeployer.predictRegistry(
            registrySalt, controller.stakerAddress(), REFERRAL_MIN_STAKE
        );
        if (registry.code.length == 0) {
            registry = controllerDeployer.deployRegistryAt(
                registrySalt, controller.stakerAddress(), REFERRAL_MIN_STAKE
            );
        }
        referralRegistryOf[r.newRoundId] = registry;

        // 4. hook at the mined salt
        CurveHook hook = CurveHook(r.hook);
        if (address(hook).code.length == 0) {
            address h = hookDeployer.deployHookAt(r.hookSalt, poolManager, address(controller), registry, cfg);
            if (h != r.hook) revert PredictMismatch();
        }
        hookAddr = r.hook;

        // Sine flavor: arm THIS round's hook before pool init (guard inside
        // configureSine enforces pre-init + factory identity).
        if (useSine) hook.configureSine(gameSineParams);

        // 5. wiring
        controller.setHook(hook);
        controller.setFactoryRoundId(r.newRoundId);

        // 5b. carry — the destroyed round's entire backing, seeded as the
        //     new round's opening predeposit (cap-exempt). BEFORE pool
        //     init: a failing seedCarry must not leave an initialized pool.
        uint256 carry;
        if (r.fromRoundId != 0) {
            carry = mixETH.balanceOf(address(this));
            if (carry > 0) {
                mixETH.forceApprove(address(controller), carry);
                controller.seedCarry(carry);
            }
        }

        // 6. initialize V4 pool (price 1:1 — the hook owns pricing)
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
        poolManager.initialize(key, 79228162514264337593543950336); // sqrt(1) in Q64.96

        // 7. record — infallible ops only after initialize
        rounds[r.newRoundId] = Round({
            token: token,
            controller: controller,
            hook: hook,
            destroyed: false,
            name: name,
            symbol: symbol
        });
        currentRoundId = r.newRoundId;
        if (r.fromRoundId != 0) {
            emit ETHCarried(r.fromRoundId, r.newRoundId, carry);
        }
        emit RoundDeployed(
            r.newRoundId, address(token), address(controller), address(hook), controller.stakerAddress()
        );

        reservation.active = false; // record kept for history/UI; slot reused next round
        return (r.newRoundId, hookAddr);
    }

    /// @notice One-tx rebirth (permissionless): reserve + birth composed.
    /// @dev Kept for callers that want atomic death→playable-successor
    ///      semantics in a single tx and accept the ~2% mining-exhaustion
    ///      bounce (clean revert, retry with fresh entropy). The default
    ///      rebirth flow is reserveSpawn (from finalizeCarpet) + birthRound.
    function spawnNextRound(uint256 fromRoundId) external returns (uint256 newRoundId, address hookAddr) {
        Round storage from = rounds[fromRoundId];
        if (address(from.token) == address(0)) revert RoundNotFound();
        if (!from.destroyed) revert RoundNotDestroyed();
        if (fromRoundId != currentRoundId) revert NotLatestRound();
        if (gameCurve.zones.length == 0) revert GameConfigUnset();

        newRoundId = currentRoundId + 1;
        _reserve(
            uint128(fromRoundId),
            string.concat(baseName, " ", _itoa(newRoundId)),
            string.concat(baseSymbol, _itoa(newRoundId))
        );
        (newRoundId, hookAddr) = _birth(
            string.concat(baseName, " ", _itoa(newRoundId)),
            string.concat(baseSymbol, _itoa(newRoundId))
        );
    }

    /// @notice Spawn the next round from the latest destroyed one — permissionless.
    /// @dev The game loop's rebirth step, now staged by default: the dying
    ///      round's carpetBomb() reserves the successor (see reserveSpawn),
    ///      and birthRound() — callable by anyone — executes it. The
    ///      composed one-tx variant remains for callers that want atomic
    ///      death→playable-successor semantics (see spawnNextRound above).

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

    // ─────────────── (side pot removed 2026-08-19) ───────────────
    // creditSidePot deleted with the pot — nothing credits a ring-fenced
    // reserve anymore; the whole factory balance is the generic carry.

    /// @notice Mark a round as destroyed (called by its controller during destruction)
    function markDestroyed(uint256 roundId) external {
        Round storage round = rounds[roundId];
        if (msg.sender != address(round.controller)) revert NotRoundController();
        round.destroyed = true;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    // ─────────────── UI round views (scoopy 2026-08-29) ───────────────
    // Everything a frontend needs to build the site for the CURRENT round
    // (or any historical one), queryable by round number. Rebirth itself
    // was already permissionless (finalizeCarpet → spawnNextRound deploys
    // round n+1 with a fresh PSP-n token seeded with the carry — the game
    // loop needs no extra "initialize" call).

    /// @notice Number of the current (latest deployed) round.
    function currentRound() external view returns (uint256) {
        return currentRoundId;
    }

    /// @notice PSP token of a round — round 1 PSP, round 2 PSP2, …
    function pspRoundToken(uint256 roundId) external view returns (address) {
        address t = address(rounds[roundId].token);
        if (t == address(0)) revert RoundNotFound();
        return t;
    }

    /// @notice The V4 pool key of a round (sorted currencies + hook).
    function roundPool(uint256 roundId)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 spacing, address hook)
    {
        Round storage r = rounds[roundId];
        if (address(r.token) == address(0)) revert RoundNotFound();
        currency0 = address(mixETH);
        currency1 = address(r.token);
        if (currency0 > currency1) (currency0, currency1) = (currency1, currency0);
        return (currency0, currency1, 0x800000, tickSpacing, address(r.hook));
    }

    /// @notice One-call round summary for UIs: every contract + lifecycle
    ///         flag for a round, including the live phase timings the
    ///         controller carries (predeposit/vest/vote/flatExit).
    function roundInfo(uint256 roundId)
        external
        view
        returns (
            address token,
            address controller,
            address hook,
            address staker,
            address referralRegistry,
            string memory name,
            string memory symbol,
            bool destroyed,
            uint256 predepositDuration,
            uint256 vestDuration,
            uint256 voteDuration,
            uint256 flatExitWindow
        )
    {
        Round storage r = rounds[roundId];
        if (address(r.token) == address(0)) revert RoundNotFound();
        RoundController c = r.controller;
        return (
            address(r.token),
            address(c),
            address(r.hook),
            c.stakerAddress(),
            referralRegistryOf[roundId],
            r.name,
            r.symbol,
            r.destroyed,
            c.PREDEPOSIT_DURATION(),
            c.VEST_DURATION(),
            c.VOTE_DURATION(),
            c.FLAT_EXIT_WINDOW()
        );
    }
}
