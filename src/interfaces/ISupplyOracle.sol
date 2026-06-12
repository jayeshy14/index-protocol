// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ISupplyOracle
 * @notice Source of float-adjusted circulating supply per constituent. The
 * methodology engine consumes an already-float-adjusted figure and does not
 * itself decide float (spec Section 5.2). The Phase 3 implementation layers
 * on-chain derivation, a multi-source median with divergence freeze, and
 * containment guards behind this interface, so the methodology never needs
 * to know how the number was secured.
 * @dev Supply is reported in whole-token units, never native token decimals.
 * Implementations MUST revert rather than return a stale or disputed value.
 */
interface ISupplyOracle {
    /// @notice Float-adjusted circulating supply of `token`, in whole tokens.
    function getFreeFloatSupply(address token) external view returns (uint256);
}
