// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// ============================================================================
// Errors
// ============================================================================

/// @notice Thrown when a constructor or setter receives the zero address.
error ExcludedRegistry_ZeroAddress();

/// @notice Thrown when proposing a change that is already pending.
error ExcludedRegistry_ChangeAlreadyPending(bytes32 id);

/// @notice Thrown when executing or cancelling a change that was never proposed.
error ExcludedRegistry_NoPendingChange(bytes32 id);

/// @notice Thrown when executing a change before its timelock has elapsed.
error ExcludedRegistry_TimelockNotElapsed(bytes32 id, uint256 eta);

/// @notice Thrown when a proposed change is redundant (excluding an address
/// already excluded, or including one not currently excluded).
error ExcludedRegistry_NoOp(address token, address account, bool exclude);

/// @notice Thrown when setting a delay outside the allowed band.
error ExcludedRegistry_InvalidDelay(uint256 delay);

/**
 * @title ExcludedAddressRegistry
 * @notice Layer 1 of the supply oracle (spec Section 8.1): minimize the
 * off-chain surface by deriving circulating supply on-chain wherever possible.
 *
 * Circulating supply is computed directly as
 *
 *     circulating = totalSupply - Σ balanceOf(excludedAddress)
 *
 * which converts "trust a number" into "trust a list of addresses." Every
 * excluded address is a falsifiable public claim (this is a vesting contract,
 * this is the team multisig, this is a burn sink) that any observer can audit,
 * and totalSupply itself is a free, trustless upper bound: no derived figure
 * can exceed it.
 *
 * Because the excluded set is the entire trust surface of Layer 1, every
 * addition and removal is timelocked. A change is visible on-chain for the
 * full delay before it can take effect, so a malicious or mistaken edit can
 * be seen and contested before it moves any weight.
 */
contract ExcludedAddressRegistry is Ownable2Step {
    struct PendingChange {
        uint64 eta;
        bool exclude; // true: add to excluded set; false: remove
        bool exists;
    }

    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 30 days;

    /// @notice Timelock applied to every excluded-set change.
    uint256 public delay;

    /// @dev Per-token excluded address list, in insertion order.
    mapping(address token => address[]) private _excludedList;

    /// @notice Whether `account` is currently excluded for `token`.
    mapping(address token => mapping(address account => bool)) public isExcluded;

    /// @dev Pending changes keyed by changeId(token, account, exclude).
    mapping(bytes32 id => PendingChange) public pendingChanges;

    event DelaySet(uint256 delay);
    event ChangeProposed(bytes32 indexed id, address indexed token, address indexed account, bool exclude, uint256 eta);
    event ChangeCancelled(bytes32 indexed id, address indexed token, address indexed account, bool exclude);
    event ChangeExecuted(bytes32 indexed id, address indexed token, address indexed account, bool exclude);

    constructor(address initialOwner, uint256 initialDelay) Ownable(initialOwner) {
        if (initialDelay < MIN_DELAY || initialDelay > MAX_DELAY) revert ExcludedRegistry_InvalidDelay(initialDelay);
        delay = initialDelay;
        emit DelaySet(initialDelay);
    }

    // ========================================================================
    // Timelocked change lifecycle
    // ========================================================================

    /// @notice Deterministic id for a (token, account, direction) change.
    function changeId(address token, address account, bool exclude) public pure returns (bytes32) {
        return keccak256(abi.encode(token, account, exclude));
    }

    /// @notice Proposes adding or removing `account` from `token`'s excluded
    /// set. The change cannot take effect until `delay` has elapsed.
    function proposeChange(address token, address account, bool exclude) external onlyOwner returns (bytes32 id) {
        if (token == address(0) || account == address(0)) revert ExcludedRegistry_ZeroAddress();
        // Reject redundant changes so the pending queue only holds real edits.
        if (isExcluded[token][account] == exclude) revert ExcludedRegistry_NoOp(token, account, exclude);

        id = changeId(token, account, exclude);
        if (pendingChanges[id].exists) revert ExcludedRegistry_ChangeAlreadyPending(id);

        uint64 eta = uint64(block.timestamp + delay);
        pendingChanges[id] = PendingChange({ eta: eta, exclude: exclude, exists: true });
        emit ChangeProposed(id, token, account, exclude, eta);
    }

    /// @notice Cancels a pending change before it executes. The owner today,
    /// the guardian once Phase 5 wires fast pause powers in.
    function cancelChange(address token, address account, bool exclude) external onlyOwner {
        bytes32 id = changeId(token, account, exclude);
        if (!pendingChanges[id].exists) revert ExcludedRegistry_NoPendingChange(id);
        delete pendingChanges[id];
        emit ChangeCancelled(id, token, account, exclude);
    }

    /// @notice Executes a pending change once its timelock has elapsed.
    /// @dev Permissionless: the timelock, not the caller, is the gate. Anyone
    /// can finalize a change the owner has already publicly committed to.
    function executeChange(address token, address account, bool exclude) external {
        bytes32 id = changeId(token, account, exclude);
        PendingChange memory change = pendingChanges[id];
        if (!change.exists) revert ExcludedRegistry_NoPendingChange(id);
        if (block.timestamp < change.eta) revert ExcludedRegistry_TimelockNotElapsed(id, change.eta);

        delete pendingChanges[id];

        if (exclude) {
            // Guard against a redundant add that slipped in between propose and
            // execute (e.g., the same account added via two ids).
            if (!isExcluded[token][account]) {
                isExcluded[token][account] = true;
                _excludedList[token].push(account);
            }
        } else {
            if (isExcluded[token][account]) {
                isExcluded[token][account] = false;
                _removeFromList(token, account);
            }
        }

        emit ChangeExecuted(id, token, account, exclude);
    }

    /// @notice Sets the timelock delay for future changes.
    function setDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) revert ExcludedRegistry_InvalidDelay(newDelay);
        delay = newDelay;
        emit DelaySet(newDelay);
    }

    // ========================================================================
    // Views and derivation
    // ========================================================================

    /// @notice The current excluded-address set for `token`.
    function getExcluded(address token) external view returns (address[] memory) {
        return _excludedList[token];
    }

    /// @notice Number of excluded addresses for `token`.
    function excludedCount(address token) external view returns (uint256) {
        return _excludedList[token].length;
    }

    /**
     * @notice On-chain-derived circulating supply of `token` in WHOLE tokens:
     * totalSupply minus the balance of every excluded address, scaled down by
     * the token's decimals.
     * @dev The subtraction reverts on underflow, which fails closed: the
     * excluded set is by construction a subset of holders, so a sum exceeding
     * totalSupply signals a corrupted registry rather than a real state.
     */
    function onChainCirculating(address token) external view returns (uint256) {
        uint256 total = IERC20(token).totalSupply();

        address[] storage list = _excludedList[token];
        uint256 excludedSum = 0;
        for (uint256 i = 0; i < list.length; i++) {
            excludedSum += IERC20(token).balanceOf(list[i]);
        }

        uint256 circulatingRaw = total - excludedSum; // underflow reverts: fail closed
        return circulatingRaw / (10 ** IERC20Metadata(token).decimals());
    }

    // ========================================================================
    // Internal
    // ========================================================================

    /// @dev Swap-and-pop removal of `account` from `token`'s excluded list.
    function _removeFromList(address token, address account) private {
        address[] storage list = _excludedList[token];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (list[i] == account) {
                list[i] = list[len - 1];
                list.pop();
                return;
            }
        }
    }
}
