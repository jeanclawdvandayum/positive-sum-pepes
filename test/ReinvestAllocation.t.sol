// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PSPReinvestor} from "../src/PSPReinvestor.sol";
import {IPSPStaker} from "../src/interfaces/IPSPStaker.sol";
import {IPSPZapIn} from "../src/interfaces/IPSPZapIn.sol";
import {IRoundController} from "../src/interfaces/IRoundController.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract AllocationToken is ERC20 {
    constructor() ERC20("Allocation fixture", "ALLOC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AllocationRound {
    function hookAddress() external view returns (address) {
        return address(this);
    }

    function MIN_BUY_INPUT() external pure returns (uint256) {
        return 1;
    }
}

contract AllocationStaker {
    AllocationToken internal immutable mix;
    AllocationToken internal immutable psp;
    IRoundController public immutable controller;
    address public immutable owner;
    mapping(uint256 => uint256) public amount;
    mapping(uint256 => uint256) public fees;
    address public wrapper;

    constructor(AllocationToken mix_, AllocationToken psp_, IRoundController controller_, address owner_) {
        mix = mix_;
        psp = psp_;
        controller = controller_;
        owner = owner_;
    }

    function configure(address wrapper_, uint256 id, uint256 principal, uint256 credit) external {
        wrapper = wrapper_;
        amount[id] = principal;
        fees[id] = credit;
    }

    function ownerOf(uint256) external view returns (address) {
        return owner;
    }

    function isWithdrawing(uint256) external pure returns (bool) {
        return false;
    }

    function isApprovedForAll(address who, address operator) external view returns (bool) {
        return who == owner && operator == wrapper;
    }

    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }

    function positions(uint256 id) external view returns (IPSPStaker.PositionView memory) {
        return IPSPStaker.PositionView(amount[id], 0, 0, 0, 0);
    }

    function claimAllTo(uint256[] calldata ids, address to) external {
        require(msg.sender == wrapper, "wrapper approval");
        uint256 total;
        for (uint256 i; i < ids.length; ++i) {
            total += fees[ids[i]];
            fees[ids[i]] = 0;
        }
        mix.transfer(to, total);
    }

    function stakeFor(address who, uint256 id, uint256 increment) external {
        require(msg.sender == wrapper && who == owner, "owner attribution");
        psp.transferFrom(msg.sender, address(this), increment);
        amount[id] += increment;
    }
}

contract AllocationZap {
    AllocationToken internal immutable mix;
    AllocationToken internal immutable psp;
    uint256 public bought;
    address public trader;

    constructor(AllocationToken mix_, AllocationToken psp_) {
        mix = mix_;
        psp = psp_;
    }

    function setOutput(uint256 output) external {
        bought = output;
    }

    function buyWithMixFor(PoolKey calldata, uint256 mixIn, uint256 minOut, uint256, address who)
        external
        returns (uint256)
    {
        require(bought >= minOut, "minimum output");
        mix.transferFrom(msg.sender, address(this), mixIn);
        psp.mint(msg.sender, bought);
        trader = who;
        return bought;
    }
}

/// @title Batch reinvestment allocation and donation regression tests
/// @notice The fixture isolates proportional allocation with actual ERC20
///         transfers. Real-V4 tests separately cover curve settlement.
contract ReinvestAllocationTest is Test {
    AllocationToken internal mix = new AllocationToken();
    AllocationToken internal psp = new AllocationToken();
    AllocationRound internal round = new AllocationRound();
    AllocationStaker internal staker;
    AllocationZap internal zap;
    PSPReinvestor internal reinvestor;
    PoolKey internal key;

    function setUp() public {
        staker = new AllocationStaker(mix, psp, IRoundController(address(round)), address(this));
        zap = new AllocationZap(mix, psp);
        reinvestor = new PSPReinvestor(
            IPSPStaker(address(staker)), IPSPZapIn(address(zap)), IERC20(address(mix)), IERC20(address(psp))
        );
        key.hooks = IHooks(address(round));
    }

    function _prepare(uint256[3] memory principal, uint256 bought, uint256 donation)
        internal
        returns (uint256[] memory ids)
    {
        ids = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            ids[i] = i + 1;
            staker.configure(address(reinvestor), i + 1, principal[i], 1e18);
            psp.mint(address(staker), principal[i]);
        }
        mix.mint(address(staker), 3e18);
        psp.mint(address(reinvestor), donation);
        zap.setOutput(bought);
    }

    function test_DonationCannotBlockFractionalBatchAndAllBoughtPspIsStaked() public {
        uint256[] memory ids = _prepare([uint256(100), 100, 100], 10, 1001);
        reinvestor.reinvestAll(ids, key, 10, block.timestamp);
        assertEq(staker.amount(1), 103);
        assertEq(staker.amount(2), 103);
        assertEq(staker.amount(3), 104);
        assertEq(psp.balanceOf(address(reinvestor)), 1001, "donation stays untouched");
        assertEq(psp.balanceOf(address(staker)), 310, "all ten bought wei staked");
        assertEq(mix.balanceOf(address(reinvestor)), 0);
        assertEq(zap.trader(), address(this));
    }

    function test_FinalEmptyPositionDoesNotReceiveProportionalRemainder() public {
        uint256[] memory ids = _prepare([uint256(100), 100, 0], 3, 1001);
        reinvestor.reinvestAll(ids, key, 3, block.timestamp);
        assertEq(staker.amount(1), 101);
        assertEq(staker.amount(2), 102);
        assertEq(staker.amount(3), 0);
        assertEq(psp.balanceOf(address(reinvestor)), 1001);
    }

    function test_LargePositionProductUsesFullPrecision() public {
        uint256 principal = 1e40;
        uint256[] memory ids = _prepare([principal, principal, principal], 1e38, 0);
        reinvestor.reinvestAll(ids, key, 1e38, block.timestamp);
        uint256 firstShare = uint256(1e38) / 3;
        assertEq(staker.amount(1), principal + firstShare);
        assertEq(staker.amount(2), principal + firstShare);
        assertEq(staker.amount(3), principal + 1e38 - 2 * firstShare);
        assertEq(psp.balanceOf(address(reinvestor)), 0);
    }

    function testFuzz_BatchConservesEveryBoughtWeiAndPreservesDonations(
        uint128 aRaw,
        uint128 bRaw,
        uint128 cRaw,
        uint128 outRaw,
        uint128 donated
    ) public {
        uint256[3] memory principal = [uint256(aRaw) + 1, uint256(bRaw) + 1, uint256(cRaw) + 1];
        uint256 bought = uint256(outRaw) + 1;
        uint256 total = principal[0] + principal[1] + principal[2];
        uint256[] memory ids = _prepare(principal, bought, donated);
        reinvestor.reinvestAll(ids, key, bought, block.timestamp);
        uint256 a = staker.amount(1) - principal[0];
        uint256 b = staker.amount(2) - principal[1];
        uint256 c = staker.amount(3) - principal[2];
        assertEq(a + b + c, bought, "complete allocation");
        assertEq(a, Math.mulDiv(bought, principal[0], total));
        assertEq(b, Math.mulDiv(bought, principal[1], total));
        assertEq(c, bought - a - b);
        assertEq(psp.balanceOf(address(reinvestor)), donated, "donation preserved");
        assertEq(mix.balanceOf(address(reinvestor)), 0);
    }
}
