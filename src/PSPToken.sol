// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title PSPToken — ERC-20 token for Positive Sum Pepes rounds
/// @notice Controller is the sole minter/burner. Set once via setController().
/// @dev Greenlist bookkeeping (greenlist-IBCO): a `holder` bool + count track who
///      currently holds PSP; `freezeHolders()` (controller, at detonation) stops
///      updating the map so it becomes the "held PSP at detonation" snapshot the
///      NEXT round's green phase reads. Trustless auto-greenlist: no operator,
///      no enumeration, no merkle root needed for the holder portion.
contract PSPToken is ERC20, ERC20Permit {
    error OnlyController();
    error ZeroAddress();
    error AlreadySet();
    error OnlyFactory();

    event ControllerSet(address indexed controller);
    event HoldersFrozen(uint256 snapshotCount);

    address public controller;
    address public immutable factory;
    bool private controllerInitialized;

    /// @dev holder-of-record at the last update; stops tracking once frozen.
    mapping(address => bool) public holder;
    /// @dev holders at the freeze (or live count before it) — feeds the next
    ///      round's greenPerWallet = 500 mixETH / N.
    uint256 public holderCount;
    /// @dev set once, at detonation; the map is the snapshot from here on.
    bool public holdersFrozen;

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    constructor(string memory name_, string memory symbol_, address _factory)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
    }

    /// @notice Set controller once. Only callable by factory.
    function setController(address _controller) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (controllerInitialized) revert AlreadySet();
        if (_controller == address(0)) revert ZeroAddress();
        controller = _controller;
        controllerInitialized = true;
        emit ControllerSet(_controller);
    }

    function mint(address to, uint256 amount) external onlyController {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyController {
        _burn(from, amount);
    }

    /// @notice Stop tracking holders: the map becomes the at-detonation snapshot.
    /// @dev Controller calls this inside detonate(). Idempotent; count is what the
    ///      next round's birth divides 500 mixETH by.
    function freezeHolders() external onlyController {
        if (holdersFrozen) return;
        holdersFrozen = true;
        emit HoldersFrozen(holderCount);
    }

    /// @dev OZ v5 transfer hook: maintain the holder set while live.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (holdersFrozen) return;
        if (to != address(0) && !holder[to]) {
            holder[to] = true;
            holderCount++;
        }
        // A sender emptied out (or burned) — they no longer hold.
        if (from != address(0) && holder[from] && balanceOf(from) == 0) {
            holder[from] = false;
            holderCount--;
        }
    }
}
