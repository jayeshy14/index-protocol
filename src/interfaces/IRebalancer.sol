// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { GPv2Order } from "src/libraries/GPv2Order.sol";

/**
 * @title IRebalancer
 * @notice The order-validation surface the vault delegates to. The vault is the
 * CoW order owner and implements ERC-1271, but the decision of whether a given
 * order is a legitimate rebalance leg right now lives in the rebalancer.
 */
interface IRebalancer {
    /// @notice Reverts unless `order` is a valid rebalance leg for the open epoch.
    function validateOrder(GPv2Order.Data calldata order) external view;
}
