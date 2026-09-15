// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploymentSupport} from "../../script/DeploymentSupport.sol";
import {PSPFactory} from "../../src/PSPFactory.sol";
import {HookDeployer} from "../../src/HookDeployer.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {StakerDeployer} from "../../src/StakerDeployer.sol";
import {PepeDescriptor} from "../../src/PepeDescriptor.sol";
import {PSPZapIn} from "../../src/PSPZapIn.sol";
import {PSPZapOut} from "../../src/PSPZapOut.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {SineV3Math} from "../../src/SineV3Math.sol";
import {IMixETH} from "../../src/interfaces/IMixETH.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockMixETH} from "../mocks/MockMixETH.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";

contract DeploymentScriptHarness is DeploymentSupport {
    function checkModes(bool anvil, bool testnet) external view { _validateModes(anvil, testnet); }
    function checkManager(address manager, bool testnet) external view { _validatePoolManager(manager, testnet); }
    function sinePL() external view returns (uint128) { return _sinePL(); }
    function timings() external view returns (uint256) { return _testnetTimings(); }
    function complete(PSPFactory factory) external { _completeGenesis(factory); }
    function checkRound(PSPFactory factory, uint256 id) external view { _validateCurrentRound(factory, id); }
    function checkIn(address zap, PSPFactory factory) external view { _validateZapIn(zap, factory); }
    function checkOut(address zap, PSPFactory factory) external view { _validateZapOut(zap, factory); }
    function params(uint256 timing) external pure returns (PSPFactory.RoundParams memory) { return _roundParams(timing); }
}

/// @dev Models a pre-AUD-14 router with valid counterparties but no buyWithMixFor.
contract LegacyDeploymentZap {
    IMixETH public immutable mixETH;
    IPoolManager public immutable poolManager;
    constructor(IMixETH mix, IPoolManager manager) { mixETH = mix; poolManager = manager; }
}

/// @title DeploymentScriptsTest
/// @notice Deployment preflights and interrupted genesis use the approved release flow.
contract DeploymentScriptsTest is Test {
    DeploymentScriptHarness harness;
    address constant BASE_PM = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    function setUp() public { harness = new DeploymentScriptHarness(); }

    function test_TestnetRejectsWrongChainManagerAndMissingCode() public {
        vm.chainId(1);
        vm.etch(BASE_PM, hex"00");
        vm.expectRevert("testnet deployment requires Base Sepolia 84532");
        harness.checkManager(BASE_PM, true);
        vm.chainId(84532);
        vm.expectRevert("wrong Base Sepolia PoolManager");
        harness.checkManager(address(1234), true);
        vm.etch(BASE_PM, hex"");
        vm.expectRevert("PoolManager has no code");
        harness.checkManager(BASE_PM, true);
        vm.etch(BASE_PM, hex"00");
        harness.checkManager(BASE_PM, true);
    }

    function test_MockModeCannotRunOnPublicChainOrAlongsideTestnet() public {
        vm.chainId(84532);
        vm.expectRevert("PSP_ANVIL conflicts with PSP_TESTNET");
        harness.checkModes(true, true);
        vm.expectRevert("mock deployment requires local chain 31337");
        harness.checkModes(true, false);
        vm.chainId(31337);
        harness.checkModes(true, false);
    }

    function test_RetiredSineEnvFailsLoudlyAndPLBoundsEnforced() public {
        vm.setEnv("PSP_SINE_PTARGET", "60000000000000000");
        vm.expectRevert("PSP_SINE_PTARGET is retired under sine rules v3");
        harness.sinePL();
        vm.setEnv("PSP_SINE_PTARGET", "");
        vm.setEnv("PSP_SINE_PL", "1");
        vm.expectRevert("PSP_SINE_PL out of bounds");
        harness.sinePL();
        vm.setEnv("PSP_SINE_PL", "75000000000000");
        assertEq(harness.sinePL(), 75_000_000_000_000);
    }

    function test_TimingOverridesUseCanonicalPackingAndRejectInvalidVest() public {
        vm.setEnv("PSP_PREDEPOSIT_SEC", "600");
        vm.setEnv("PSP_VEST_SEC", "1200");
        vm.setEnv("PSP_DET_SEC", "1800");
        vm.setEnv("PSP_WALLET_CAP_MIX", "25");
        assertEq(harness.timings(), CurveMath.packTimingsCapped(600, 1200, 1800, 25));
        vm.setEnv("PSP_VEST_SEC", "1201");
        vm.expectRevert();
        harness.timings();
    }

    function _factory() internal returns (PSPFactory factory) {
        factory = new PSPFactory(
            IPoolManager(address(new MockPoolManager())), IERC20(address(new MockMixETH())),
            new HookDeployer(), new ControllerDeployer(), new StakerDeployer(),
            address(new SineV3Math()),
            CurveMath.packTimingsCapped(7200, 3600, 7200, 0), address(this)
        );
        factory.setDescriptor(address(new PepeDescriptor()));
        factory.configureSineV3(75_000_000_000_000);
    }

    function test_ResumeEveryReservedPhaseAndCompletedGenesisWithoutRepeatingSteps() public {
        // A resumed script must trust factory timing, not changed local env.
        vm.setEnv("PSP_WALLET_CAP_MIX", "999");
        for (uint256 completed; completed < 4; ++completed) {
            PSPFactory factory = _factory();
            factory.reserveGenesis(harness.params(factory.roundTimings()));
            for (uint256 i; i < completed; ++i) factory.birthStep();
            harness.complete(factory);
            assertEq(factory.currentRoundId(), 1);
            assertFalse(factory.reservationActive());
            PSPFactory.Round memory round = factory.getRound(1);
            assertEq(round.controller.PREDEPOSIT_CAP_PER_WALLET(), 0);
            assertEq(round.controller.PREDEPOSIT_DURATION(), 7200);
            assertEq(round.controller.VEST_DURATION(), 3600);
            assertEq(round.hook.detWindow(), 7200);
            harness.checkRound(factory, 1);
            harness.complete(factory);
            assertEq(address(factory.getRound(1).controller), address(round.controller));
        }
    }

    function test_ReserveMissingGenesisWithFactoryTimings() public {
        PSPFactory factory = _factory();
        vm.setEnv("PSP_WALLET_CAP_MIX", "999");
        harness.complete(factory);
        assertEq(factory.currentRoundId(), 1);
        assertEq(factory.getRound(1).controller.PREDEPOSIT_CAP_PER_WALLET(), 0);
    }

    function test_RouterChecksRejectLegacyAndMismatchedImmutableCounterparties() public {
        PSPFactory factory = _factory();
        IMixETH mix = IMixETH(address(factory.mixETH()));
        IPoolManager manager = factory.poolManager();
        PSPZapIn current = new PSPZapIn(mix, manager);
        harness.checkIn(address(current), factory);
        harness.checkOut(address(new PSPZapOut(mix, manager)), factory);
        LegacyDeploymentZap legacy = new LegacyDeploymentZap(mix, manager);
        vm.expectRevert("ZapIn owner attribution unavailable");
        harness.checkIn(address(legacy), factory);
        PSPZapIn wrongMix = new PSPZapIn(IMixETH(address(1234)), manager);
        vm.expectRevert("ZapIn mixETH mismatch");
        harness.checkIn(address(wrongMix), factory);
        PSPZapOut wrongManager = new PSPZapOut(mix, IPoolManager(address(1234)));
        vm.expectRevert("ZapOut PoolManager mismatch");
        harness.checkOut(address(wrongManager), factory);
    }

    function test_ReinvestorCannotTargetAnUnfinishedRound() public {
        PSPFactory factory = _factory();
        factory.reserveGenesis(harness.params(factory.roundTimings()));
        factory.birthStep();
        vm.expectRevert("select the completed current round");
        harness.checkRound(factory, 1);
    }
}
