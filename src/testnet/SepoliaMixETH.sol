// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SepoliaMixETH — dumb 1:1 ETH wrapper for PSP testnet playtests
/// @notice The real mixETH is an Alchemix yield vault. For playtests this is
///         a HARDCODED 1:1 wrapper: 1 wei ETH = 1 wei mixETH, forever. No
///         yield, no rate variable, no owner, no admin surface — the
///         sharesToAssets rate is always exactly 1e18 by construction.
///
///         PUBLIC MINT (2026-08-28): mixETH on testnet is a playtest unit,
///         not a claim on ETH. The faucet no longer sells mixETH for ETH —
///         anyone mints as much as they want for free (see mint()). The
///         ETH legs (depositETH/redeemETH) stay for interface compatibility
///         with the zap routers, but the testnet UI never touches them:
///         the pool trades mixETH <-> PSP only. redeemETH draws on whatever
///         real ETH was actually deposited (faucet minted shares have none),
///         which is why the UI must keep off the ETH paths.
///
///         NEVER deploy to mainnet: the supply is not backed 1:1 by ETH
///         and the mint is wide open.
contract SepoliaMixETH is ERC20 {
    /// @dev Legacy faucet inventory seed — moot now that mint() is public,
    ///      kept so the deploy script's console output stays truthful.
    uint256 public constant SUPPLY = 10_000_000 ether;

    constructor() ERC20("Sepolia mixETH (PSP test)", "mixETH") {
        _mint(msg.sender, SUPPLY);
    }

    /// @notice Mint any amount of mixETH, for free, to anyone. Testnet-only
    ///         convenience: the whole point of the mock is that mixETH is
    ///         unlimited so playtesters never need native ETH to play.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Wrap ETH at the hardcoded 1:1 rate — exactly msg.value shares.
    function depositETH() external payable returns (uint256 shares) {
        require(msg.value > 0, "Zero deposit");
        shares = msg.value;
        _mint(msg.sender, shares);
    }

    /// @notice Unwrap at the hardcoded 1:1 rate. CEI: burn before the ETH
    ///         call. Only real deposits are redeemable — faucet-minted
    ///         shares have no ETH behind them and will revert here (the
    ///         testnet UI never routes through this).
    function redeemETH(uint256 shareAmount) external returns (uint256 ethOut) {
        require(shareAmount > 0, "Zero amount");
        ethOut = shareAmount; // hardcoded 1:1
        _burn(msg.sender, shareAmount);
        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "ETH transfer failed");
    }

    /// @notice ERC-4626-style view; at 1:1 this is just totalSupply().
    function totalAssets() external view returns (uint256) {
        return totalSupply();
    }

    /// @dev Accept stray ETH (refunds, accidental sends).
    receive() external payable {}
}
