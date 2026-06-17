// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IMethodology
 * @notice Pluggable weighting strategy, keyed by token address to match the
 * AssetRegistry. The rebalancer treats the methodology as a black box
 * that maps a constituent set to target weights, so weighting schemes can be
 * swapped without touching vault or rebalancer code.
 */
interface IMethodology {
    /// @notice Target weights for `tokens`, scaled so the array sums to 1e18.
    /// @dev A weight of zero means the constituent should hold no position
    /// (pruned by the minimum-weight floor). MUST revert on bad inputs
    /// (stale price, stale supply) rather than return a degraded weighting.
    function getWeights(address[] calldata tokens) external view returns (uint256[] memory weights);
}
