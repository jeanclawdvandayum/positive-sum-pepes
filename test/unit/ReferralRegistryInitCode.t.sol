// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ControllerDeployer} from "../../src/ControllerDeployer.sol";
import {PSPReferralRegistry} from "../../src/PSPReferralRegistry.sol";
import {ReferralRegistryInitCode} from "../../src/ReferralRegistryInitCode.sol";

/// @title ReferralRegistryInitCodeTest
/// @notice Splitting creation-code storage preserves registry identity and constructor checks.
contract ReferralRegistryInitCodeTest is Test {
    ControllerDeployer private deployer;
    address private staking = makeAddr("registry-init-staker");

    function setUp() public {
        deployer = new ControllerDeployer();
    }

    function test_HelperUsesExactRegistryCreationCodeAndConstructorArguments() public view {
        ReferralRegistryInitCode helper = deployer.registryInitOracle();
        assertGt(address(helper).code.length, 0);
        bytes memory expected = bytes.concat(type(PSPReferralRegistry).creationCode, abi.encode(staking, 1000e18));
        assertEq(helper.registryInitCode(staking, 1000e18), expected);
    }

    function test_Create2PredictionKeepsControllerDeployerAsCreator() public {
        bytes32 salt = keccak256("registry-init-identity");
        bytes32 initHash = keccak256(bytes.concat(type(PSPReferralRegistry).creationCode, abi.encode(staking, 1000e18)));
        address expected = vm.computeCreate2Address(salt, initHash, address(deployer));
        address helperAsCreator = vm.computeCreate2Address(salt, initHash, address(deployer.registryInitOracle()));
        assertEq(deployer.predictRegistry(salt, staking, 1000e18), expected);
        assertTrue(helperAsCreator != expected);

        vm.prank(makeAddr("permissionless-registry-deployer"));
        address deployed = deployer.deployRegistryAt(salt, staking, 1000e18);
        assertEq(deployed, expected);
        assertEq(address(PSPReferralRegistry(deployed).staker()), staking);
        assertEq(PSPReferralRegistry(deployed).MIN_STAKE_PSP(), 1000e18);
        assertEq(PSPReferralRegistry(deployed).REFERRAL_REWARDS_VERSION(), 1);

        vm.expectRevert(ControllerDeployer.DeployFailed.selector);
        deployer.deployRegistryAt{gas: 5_000_000}(salt, staking, 1000e18);
    }

    function test_UnsaltedCreateAlsoUsesDeployerNonceAndPreservesRegistryWiring() public {
        uint256 nonce = vm.getNonce(address(deployer));
        address expected = vm.computeCreateAddress(address(deployer), nonce);
        address deployed = deployer.deployRegistry(staking, 1000e18);
        assertEq(deployed, expected);
        assertEq(address(PSPReferralRegistry(deployed).staker()), staking);
        assertEq(PSPReferralRegistry(deployed).MIN_STAKE_PSP(), 1000e18);
    }

    function test_BothDeploymentPathsBubbleInvalidConstructorArguments() public {
        bytes32 salt = keccak256("registry-init-constructor-errors");
        vm.expectRevert(PSPReferralRegistry.ZeroAddress.selector);
        deployer.deployRegistry(address(0), 1000e18);
        vm.expectRevert(PSPReferralRegistry.ZeroAddress.selector);
        deployer.deployRegistry(staking, 0);
        vm.expectRevert(PSPReferralRegistry.ZeroAddress.selector);
        deployer.deployRegistryAt(salt, address(0), 1000e18);
        vm.expectRevert(PSPReferralRegistry.ZeroAddress.selector);
        deployer.deployRegistryAt(salt, staking, 0);
        address expected = deployer.predictRegistry(salt, staking, 1000e18);
        assertEq(deployer.deployRegistryAt(salt, staking, 1000e18), expected);
    }
}
