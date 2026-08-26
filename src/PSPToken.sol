// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title PSPToken — ERC-20 token for Positive Sum Pepes rounds
/// @notice Controller is the sole minter/burner. Set once via setController().
contract PSPToken is ERC20, ERC20Permit {
    error OnlyController();
    error ZeroAddress();
    error AlreadySet();
    error OnlyFactory();

    event ControllerSet(address indexed controller);

    address public controller;
    address public immutable factory;
    bool private controllerInitialized;

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
}
