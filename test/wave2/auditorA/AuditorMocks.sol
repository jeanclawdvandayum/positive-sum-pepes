// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RoundController} from "../../../src/RoundController.sol";

/// @dev Auditor-owned hook mock exposing the full CurveHook surface the
///      controller touches (mode/supply/reserve/sendFees/redeemPotBacking/
///      drainAll/initializeCurve/setMode) with test knobs for supply/reserve.
///      ABI-compatible with CurveHook-typed calls (enums encode as uint8).
contract AuditorHook {
    error InsufficientFees();

    enum Mode {Predeposit, Active, Flat, Destroyed}

    Mode public mode;
    uint256 public totalSupplyPSP;
    uint256 public reserveMixETH;
    IERC20 public immutable mixETH;

    constructor(IERC20 _mixETH) {
        mixETH = _mixETH;
    }

    function initializeCurve(uint256 _reserve, uint256 _supply) external {
        reserveMixETH = _reserve;
        totalSupplyPSP = _supply;
    }

    function setMode(uint8 m) external {
        mode = Mode(m);
    }

    // test knobs
    function setSupply(uint256 s) external {
        totalSupplyPSP = s;
    }

    function setReserve(uint256 r) external {
        reserveMixETH = r;
    }

    function sendFees(address to, uint256 amount) external {
        uint256 balance = mixETH.balanceOf(address(this));
        uint256 available = balance - reserveMixETH;
        if (amount > available) revert InsufficientFees();
        mixETH.transfer(to, amount);
    }

    function redeemPotBacking(uint256 pspAmount) external returns (uint256 mixETHOut) {
        if (pspAmount == 0 || totalSupplyPSP == 0) return 0;
        mixETHOut = (reserveMixETH * pspAmount) / totalSupplyPSP;
        reserveMixETH -= mixETHOut;
        totalSupplyPSP -= pspAmount;
        mixETH.transfer(msg.sender, mixETHOut);
    }

    function drainAll(address to) external returns (uint256) {
        uint256 balance = mixETH.balanceOf(address(this));
        reserveMixETH = 0;
        if (balance > 0) mixETH.transfer(to, balance);
        return balance;
    }
}

/// @dev Stand-in for PSPFactory: implements exactly the three callbacks the
///      controller invokes via low-level call, with state tracking. Functions
///      are virtual so FailFactory can force spawnNextRound to revert.
contract AuditorFactory {
    uint256 public destroyedRound;
    uint256 public spawnCount;
    uint256 public sidePot;

    event Marked(uint256 roundId);
    event Spawned(uint256 fromRoundId);
    event PotCredited(uint256 amount);

    function markDestroyed(uint256 roundId) external virtual {
        destroyedRound = roundId;
        emit Marked(roundId);
    }

    function spawnNextRound(uint256 fromRoundId) external virtual {
        spawnCount++;
        emit Spawned(fromRoundId);
    }

    function creditSidePot(uint256 amount) external virtual {
        sidePot += amount;
        emit PotCredited(amount);
    }

    receive() external payable {}
}

/// @dev Same as AuditorFactory but spawnNextRound always reverts — used to
///      prove finalizeCarpet's factory-failure path is atomic.
contract FailFactory is AuditorFactory {
    function spawnNextRound(uint256) external virtual override {
        revert("spawn failed");
    }
}

/// @dev Minimal ERC20 that attempts controller reentry from inside transfer()
///      when armed. Simulates a hostile/upgradeable mixETH vault.
contract HostileMixETH {
    address public reentryActor;
    bool public armed;

    uint256 public reentryCount;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function setReentryActor(address a) external {
        reentryActor = a;
    }

    function arm() external {
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    // ERC-4626-ish surface read by RoundController._getTotalAssets (staticcall)
    function totalAssets() external view returns (uint256) {
        return totalSupply;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _maybeReenter(to);
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        _maybeReenter(to);
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "insufficient allowance");
        allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function _maybeReenter(address to) internal {
        if (armed && reentryActor != address(0) && to == reentryActor) {
            reentryCount++;
            ReentryAttacker(reentryActor).pwn();
        }
    }
}

/// @dev The locked staker that the hostile token calls back into mid-payout.
contract ReentryAttacker {
    RoundController public victim;
    uint256 public attempts;
    uint256 public successes;

    function setVictim(RoundController v) external {
        victim = v;
    }

    function pwn() external {
        attempts++;
        try victim.claimFees() {
            successes++;
        } catch {}
        try victim.unlock() {
            successes++;
        } catch {}
    }

    function doPredeposit(uint256 amt) external {
        victim.predepositFor(address(this), amt);
    }

    function doClaimPredeposit() external {
        victim.claimPredepositPSP();
    }

    function doClaimFees() external {
        victim.claimFees();
    }

    function doUnlock() external {
        victim.unlock();
    }
}
