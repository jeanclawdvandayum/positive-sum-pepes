// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {PSPReferralRegistry} from "../src/PSPReferralRegistry.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPZapOut} from "../src/PSPZapOut.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {SineMath} from "../src/libraries/SineMath.sol";
import {Curve1Zones} from "../src/curves/Curve1Zones.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title DeploymentSupport
/// @notice Shared release configuration and read-only checks before broadcasts.
abstract contract DeploymentSupport is Script {
    address internal constant BASE_SEPOLIA_PM = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    // Reservation mining uses fresh block entropy, so a successful simulation's
    // gas usage is not a bound for the actual transaction. Leave room for the
    // factory's 131,072-candidate scan while staying below Base Sepolia's cap.
    uint256 internal constant GENESIS_RESERVATION_GAS = 15_000_000;

    function _validateModes(bool anvil, bool testnet) internal view {
        require(!(anvil && testnet), "PSP_ANVIL conflicts with PSP_TESTNET");
        if (anvil) require(block.chainid == 31337, "mock deployment requires local chain 31337");
    }

    function _validatePoolManager(address pm, bool testnet) internal view {
        if (testnet) {
            require(block.chainid == 84532, "testnet deployment requires Base Sepolia 84532");
            require(pm == BASE_SEPOLIA_PM, "wrong Base Sepolia PoolManager");
        }
        require(pm.code.length != 0, "PoolManager has no code");
    }

    function _testnetTimings() internal view returns (uint256) {
        return CurveMath.packTimingsCapped(
            vm.envOr("PSP_PREDEPOSIT_SEC", uint256(3 days)),
            vm.envOr("PSP_VEST_SEC", uint256(28 days)),
            vm.envOr("PSP_DET_SEC", uint256(69 hours + 4 minutes + 20 seconds)),
            vm.envOr("PSP_WALLET_CAP_MIX", uint256(0))
        );
    }

    function _htmlPath(bool testnet) internal view returns (string memory) {
        return vm.envOr("PSP_HTML", testnet ? string("script/testnet-status.html") : string("script/app.html"));
    }

    function _validateFactory(PSPFactory factory, bool testnet) internal view {
        require(address(factory).code.length != 0, "factory has no code");
        _validatePoolManager(address(factory.poolManager()), testnet);
        require(address(factory.mixETH()).code.length != 0, "mixETH has no code");
        require(factory.descriptor().code.length != 0, "factory descriptor missing");
        require(factory.useSine(), "factory sine configuration missing");
    }

    /// @dev Resume from the deployed factory's timing profile and current phase.
    /// Never re-reserve a partially completed genesis or repeat a finished step.
    function _completeGenesis(PSPFactory factory) internal {
        if (factory.currentRoundId() != 0) return;
        if (!factory.reservationActive()) {
            require(factory.owner() == msg.sender, "genesis reservation requires factory owner");
            CurveMath.CurveConfig memory config = Curve1Zones.config();
            config.timings = factory.roundTimings();
            vm.startBroadcast(msg.sender);
            factory.reserveGenesis{gas: GENESIS_RESERVATION_GAS}(PSPFactory.RoundParams({
                name: "Positive Sum Pepes", symbol: "PSP", curveConfig: config
            }));
            vm.stopBroadcast();
        }
        for (uint256 i; i < 3 && factory.currentRoundId() == 0; ++i) {
            vm.startBroadcast(msg.sender);
            factory.birthStep();
            vm.stopBroadcast();
        }
        require(factory.currentRoundId() == 1 && !factory.reservationActive(), "genesis birth incomplete");
    }

    function _validateZapIn(address zap, PSPFactory factory) internal view {
        require(zap.code.length != 0, "ZapIn has no code");
        require(address(PSPZapIn(zap).mixETH()) == address(factory.mixETH()), "ZapIn mixETH mismatch");
        require(address(PSPZapIn(zap).poolManager()) == address(factory.poolManager()), "ZapIn PoolManager mismatch");
        // AUD-14 compatibility probe. A zero trader reverts before token access.
        // This checks the owner-attribution API, not executable source identity.
        PoolKey memory key;
        (bool ok, bytes memory result) = zap.staticcall(abi.encodeCall(
            PSPZapIn.buyWithMixFor, (key, 0, 0, 0, address(0))
        ));
        require(!ok && keccak256(result) == keccak256(abi.encodeWithSelector(PSPZapIn.ZeroTrader.selector)),
            "ZapIn owner attribution unavailable");
    }

    function _validateZapOut(address zap, PSPFactory factory) internal view {
        require(zap.code.length != 0, "ZapOut has no code");
        require(address(PSPZapOut(payable(zap)).mixETH()) == address(factory.mixETH()), "ZapOut mixETH mismatch");
        require(address(PSPZapOut(payable(zap)).poolManager()) == address(factory.poolManager()), "ZapOut PoolManager mismatch");
    }

    function _validateCurrentRound(PSPFactory factory, uint256 roundId) internal view returns (PSPFactory.Round memory r) {
        require(roundId != 0 && roundId == factory.currentRoundId(), "select the completed current round");
        require(!factory.reservationActive(), "finish reserved birth first");
        r = factory.getRound(roundId);
        require(address(r.controller).code.length != 0 && address(r.hook).code.length != 0
            && address(r.token).code.length != 0, "round code missing");
        require(!r.destroyed && uint8(r.hook.mode()) < uint8(CurveHook.Mode.Flat), "round already settled");
        require(r.controller.factory() == address(factory) && r.controller.factoryRoundId() == roundId,
            "controller factory mismatch");
        require(r.controller.getPSP() == address(r.token) && address(r.controller.mixETH()) == address(factory.mixETH()),
            "controller token mismatch");
        require(r.controller.hookAddress() == address(r.hook) && address(r.hook.controller()) == address(r.controller)
            && r.token.controller() == address(r.controller), "round wiring mismatch");
        require(address(r.hook.poolManager()) == address(factory.poolManager()), "hook PoolManager mismatch");
        require(r.hook.MIN_BUY_INPUT() == 0.005e18 && r.hook.TIME_PER_UNIT() == 69 && r.hook.TICKET_RULES_VERSION() == 2, "game rules mismatch");
        require(r.controller.PREDEPOSIT_RULES_VERSION() == 2 && r.controller.PREDEPOSIT_CAP() == 0,
            "predeposit rules mismatch");
        PSPStaker staker = r.controller.staker();
        require(address(staker).code.length != 0 && address(staker.controller()) == address(r.controller)
            && address(staker.psp()) == address(r.token), "staker wiring mismatch");
        require(staker.NFT_INTERFACE_VERSION() == 1 && (staker.PEPE_DNA_VERSION() == 1 || staker.PEPE_DNA_VERSION() == 2)
            && staker.supportsInterface(0x80ac58cd), "NFT capabilities missing");
        require(staker.descriptor() == factory.descriptor(), "staker descriptor mismatch");
        PSPReferralRegistry registry = PSPReferralRegistry(factory.referralRegistryOf(roundId));
        require(address(registry).code.length != 0 && address(registry) == address(r.hook.referralRegistry())
            && address(registry.staker()) == address(staker), "referral wiring mismatch");
        require(registry.PURCHASE_REFERRAL_VERSION() == 1, "atomic referral purchases missing");
    }

    function _roundParams(uint256 timings) internal pure returns (PSPFactory.RoundParams memory) {
        // Sine-only (scoopy 2026-08-30): the zone config is creation-code
        // SHAPE — the armed sine overrides all zone pricing at launch. The
        // 1-zone shape is the smallest legal config, keeping the staged
        // create2 initcodes (and birth gas) lean.
        CurveMath.CurveConfig memory cc = Curve1Zones.config();
        cc.timings = timings;
        return PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: cc
        });
    }

    /// @dev Reference calibration at 450 mixETH of net IBCO backing.
    ///      The opening price rises 7.5x, then reaches 0.06 mixETH/PSP
    ///      after three waves (800x the launch price). The 10,000 mixETH
    ///      reference target scales with the actual net IBCO backing.
    ///      Environment overrides use the same 450-mixETH reference.
    function _sineParams() internal view returns (SineMath.Params memory) {
        uint256 amp = vm.envOr("PSP_SINE_AMPBPS", uint256(10_000));
        require(amp <= 10_000, "PSP_SINE_AMPBPS must be at most 10000");
        return SineMath.Params({
            p0: vm.envOr("PSP_SINE_P0", uint256(1e13)),
            preK: vm.envOr("PSP_SINE_PREK", uint256(4_477_562_267_871_699)),
            pTarget: vm.envOr("PSP_SINE_PTARGET", uint256(0.06e18)),
            targetReserve: vm.envOr("PSP_SINE_TARGET_RESERVE", uint256(10_000e18)),
            ampBps: uint24(amp)
        });
    }
}
