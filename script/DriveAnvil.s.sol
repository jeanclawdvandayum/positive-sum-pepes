// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPToken} from "../src/PSPToken.sol";
import {RoundController} from "../src/RoundController.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {MockMixETH} from "../test/mocks/MockMixETH.sol";

/// @title DriveAnvil — push a freshly deployed round 1 through its phases so
///        the UI has live state to render: predeposit -> cap-hit launch ->
///        claim -> several curve buys. Anvil-only (uses deal()).
contract DriveAnvil is Script, StdCheats {
    function run() external {
        address factoryAddr = vm.envAddress("DRIVE_FACTORY");
        address zapInAddr = vm.envAddress("DRIVE_ZAPIN");
        PSPFactory factory = PSPFactory(factoryAddr);
        PSPZapIn zapIn = PSPZapIn(zapInAddr);

        (, RoundController controller, CurveHook hook,) = _round(factory);
        IERC20 mix = IERC20(factory.mixETH());

        address alice = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // anvil[0]
        address bob = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // anvil[1]
        address carol = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // anvil[2]

        // ── alice: wrap ETH → predeposit to cap (500) → permissionless launch ──
        vm.startBroadcast(alice);
        MockMixETH(payable(address(mix))).depositETH{value: 600e18}();
        mix.approve(address(controller), 500e18);
        controller.predeposit(500e18);
        controller.launchPooledBuy(); // cap reached → anyone may launch
        controller.claimPredepositPSP(); // genesis PSP auto-locks for alice
        vm.stopBroadcast();
        console.log("launched. mode:", uint256(hook.mode()));

        // ── curve trades: pool key = sorted(mix, psp), dynamic fee, ts60 ──
        (,,, address tokenAddr) = _round(factory);
        (address c0, address c1) =
            address(mix) < tokenAddr ? (address(mix), tokenAddr) : (tokenAddr, address(mix));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.startBroadcast(bob);
        MockMixETH(payable(address(mix))).depositETH{value: 100e18}();
        mix.approve(zapInAddr, type(uint256).max);
        uint256 b1 = zapIn.buyWithMix(key, 25e18, 0, 0);
        uint256 b2 = zapIn.buyWithMix(key, 12e18, 0, 0);
        vm.stopBroadcast();
        console.log("bob bought:", b1, b2);

        vm.startBroadcast(carol);
        MockMixETH(payable(address(mix))).depositETH{value: 60e18}();
        mix.approve(zapInAddr, type(uint256).max);
        uint256 c1out = zapIn.buyWithMix(key, 30e18, 0, 0);
        vm.stopBroadcast();
        console.log("carol bought:", c1out);

        console.log("supply:", hook.totalSupplyPSP());
        console.log("reserve:", hook.reserveMixETH());
        console.log("marginal price:", hook.getMarginalPrice());
    }

    function _round(PSPFactory factory)
        internal
        view
        returns (uint256 id, RoundController controller, CurveHook hook, address token)
    {
        id = factory.currentRoundId();
        (PSPToken t, RoundController c, CurveHook h,,,) = factory.rounds(id);
        return (id, c, h, address(t));
    }
}
