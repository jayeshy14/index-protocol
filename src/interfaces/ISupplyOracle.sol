// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ISupplyOracle
 * @notice Source of float-adjusted circulating supply per constituent. The
 * methodology engine consumes an already-float-adjusted figure and does not
 * itself decide float. The implementation layers on-chain
 * derivation, a multi-source median with divergence freeze, and containment
 * guards behind this interface, so the methodology never needs to know how
 * the number was secured.
 * @dev Supply is reported in whole-token units, never native token decimals.
 *
 * Freeze versus revert: because supply is the slow-moving input (price, the
 * fast input, is Chainlink's job), a residual source that goes quiet does not
 * halt the index. Soft staleness and source divergence FREEZE the constituent
 * at its last-good value rather than reverting; the slow nature of supply
 * makes a pinned figure safe for a bounded window. The view MUST revert only
 * on hard failures: paused, never initialized, or a last-good older than the
 * hard ceiling. That revert propagates into the methodology, which fails
 * closed for the whole rebalance, exactly as a stale price does.
 */
interface ISupplyOracle {
    /// @notice Float-adjusted circulating supply of `token`, in whole tokens.
    function getFreeFloatSupply(address token) external view returns (uint256);
}
