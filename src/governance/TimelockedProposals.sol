// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ============================================================================
// Errors
// ============================================================================

/// @notice Thrown when scheduling a proposal id that is already pending.
error Timelock_AlreadyScheduled(bytes32 id);

/// @notice Thrown when consuming or cancelling a proposal that is not pending.
error Timelock_NotScheduled(bytes32 id);

/// @notice Thrown when consuming a proposal before its timelock has elapsed.
error Timelock_NotElapsed(bytes32 id, uint256 eta);

/**
 * @title TimelockedProposals
 * @notice Minimal shared timelock mechanism for the protocol's curated-set
 * governors. A proposal is a bytes32 id with an execute-after timestamp (eta).
 *
 * The id encodes the change, since the deriving contract computes it from the
 * change arguments, so this base stores only the eta and never the payload; the
 * deriving contract reconstructs the change from the same arguments at execution.
 *
 * This base is the delay. The bounds (what a change may be, how often, and by
 * whom) live in the deriving contract, because a delay alone does not bound what
 * a change can be. Rich, justification-carrying events stay in the deriving
 * contracts so each keeps its own readable log.
 */
abstract contract TimelockedProposals {
    /// @dev Execute-after timestamp per proposal id. Zero means not pending.
    mapping(bytes32 id => uint64 eta) private _eta;

    /// @notice The execute-after timestamp for `id`, or zero if not pending.
    function proposalEta(bytes32 id) external view returns (uint64) {
        return _eta[id];
    }

    /// @notice Whether `id` has a live (pending) proposal.
    function isProposalPending(bytes32 id) public view returns (bool) {
        return _eta[id] != 0;
    }

    /// @dev Schedules `id` to become executable after `delay`. Reverts if it is
    /// already pending, so the queue holds at most one proposal per id.
    function _schedule(bytes32 id, uint256 delay) internal returns (uint64 eta) {
        if (_eta[id] != 0) revert Timelock_AlreadyScheduled(id);
        eta = uint64(block.timestamp + delay);
        _eta[id] = eta;
    }

    /// @dev Consumes `id` for execution: reverts unless it is pending and its
    /// timelock has elapsed, then clears it.
    function _consume(bytes32 id) internal {
        uint64 eta = _eta[id];
        if (eta == 0) revert Timelock_NotScheduled(id);
        if (block.timestamp < eta) revert Timelock_NotElapsed(id, eta);
        delete _eta[id];
    }

    /// @dev Cancels a pending proposal (the veto path). Reverts if not pending.
    function _cancel(bytes32 id) internal {
        if (_eta[id] == 0) revert Timelock_NotScheduled(id);
        delete _eta[id];
    }
}
