// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";

/// @notice Settable supply oracle for methodology tests. Reverts on unset
/// tokens, mirroring the fail-closed contract of the real implementation.
contract MockSupplyOracle is ISupplyOracle {
    error MockSupplyOracle_NotSet(address token);

    mapping(address token => uint256) private _supply;
    mapping(address token => bool) private _isSet;

    function setSupply(address token, uint256 wholeTokens) external {
        _supply[token] = wholeTokens;
        _isSet[token] = true;
    }

    function getFreeFloatSupply(address token) external view returns (uint256) {
        if (!_isSet[token]) revert MockSupplyOracle_NotSet(token);
        return _supply[token];
    }
}
