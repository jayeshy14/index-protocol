// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Settable Chainlink aggregator mock for oracle-driven NAV tests.
contract MockAggregator {
    uint8 public immutable decimals;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    /// @notice Sets the answer without refreshing updatedAt, to simulate staleness.
    function setStaleAnswer(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
        _roundId++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
