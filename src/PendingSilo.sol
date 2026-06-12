// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Thrown when the silo is constructed with a zero vault or asset address.
error PendingSilo_ZeroAddress();

/**
 * @title PendingSilo
 * @notice Isolated holder of in-flight value so the vault's NAV accounting
 * stays clean (Lagoon pattern). The silo holds three kinds of balances:
 * USDC from deposit requests that have not yet settled, vault shares escrowed
 * by redeem requests, and post-settlement balances (minted shares and owed
 * USDC) awaiting their claim step. None of these belong in the vault's
 * totalAssets, and parking them here makes that exclusion structural rather
 * than a bookkeeping subtraction.
 * @dev The silo grants the vault a standing max allowance on the asset, so
 * the vault moves USDC with transferFrom. Shares need no allowance because
 * the vault is the share token and moves silo balances through its own
 * internal ledger.
 */
contract PendingSilo {
    using SafeERC20 for IERC20;

    /// @notice The vault this silo serves.
    address public immutable VAULT;

    constructor(address vault, IERC20 asset) {
        if (vault == address(0) || address(asset) == address(0)) revert PendingSilo_ZeroAddress();
        VAULT = vault;
        asset.forceApprove(vault, type(uint256).max);
    }
}
