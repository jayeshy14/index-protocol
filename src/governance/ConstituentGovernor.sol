// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IndexVault } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { TimelockedProposals } from "src/governance/TimelockedProposals.sol";

// ============================================================================
// Errors
// ============================================================================

error ConstituentGovernor_ZeroAddress();
error ConstituentGovernor_NotRegistered(address token);
error ConstituentGovernor_AlreadyConstituent(address token);
error ConstituentGovernor_NotConstituent(address token);
error ConstituentGovernor_AssetHealthy(address token);
error ConstituentGovernor_BelowMinSize(address token, uint256 marketCapUsd, uint256 floorUsd);
error ConstituentGovernor_BelowMinCount(uint256 resulting, uint256 minimum);
error ConstituentGovernor_RateLimited(uint256 changesInWindow, uint256 maxPerWindow);
error ConstituentGovernor_NotGuardianOrOwner(address caller);
error ConstituentGovernor_InvalidParams();

/**
 * @title ConstituentGovernor
 * @notice The membership-curation analog of the supply oracle's
 * `ExcludedAddressRegistry`: once an admin curates which assets belong to an
 * index, that curation becomes a central trust assumption, so it gets a
 * timelocked AND bounded lifecycle. A timelock alone only delays a change; it
 * does not bound what the change can be. Both are enforced here (Section 16).
 *
 * The privileged actor may propose, but every executed change is checked
 * against on-chain invariants that protect holders, so even a compromised owner
 * cannot do arbitrary harm:
 *
 * - Additions are bounded (16.2): the token must be registered with a working
 *   feed and supply source and clear an on-chain market-cap floor, and additions
 *   are rate-limited per window.
 * - Removal is split (16.1, 16.6): a FORCED removal is fast but only allowed
 *   when the contract itself can prove the asset failed (deregistered,
 *   unpriceable, or its supply entry failed); a DISCRETIONARY removal of a
 *   healthy asset takes the slow, vetoable, rate-limited path.
 * - Global invariants (16.3): a minimum constituent count and the per-window
 *   rate limit apply to every path.
 * - Transparency and veto (16.4): every proposal is timelocked, event-emitting
 *   with its justification attached, and publicly readable; the guardian can
 *   cancel a pending change in its window.
 * - Execution safety (16.5): a removal never moves funds. It begins a wind-down
 *   on the vault, the rebalancer exits the position through CoW at the
 *   oracle-anchored minimum-out, and the constituent is deleted only once the
 *   position is dust. The stale-feed special case (the asset you must exit is
 *   the one your oracle cannot price) is the quarantine path deferred to
 *   Section 4; such a forced-removed asset sits marked for wind-down until then.
 */
contract ConstituentGovernor is Ownable2Step, TimelockedProposals {
    using Math for uint256;

    /// @dev Price feeds are 8-decimal, so a whole-token supply times an
    /// 8-decimal price divided by 1e8 yields a whole-USD market cap, matching
    /// the methodology's market-cap convention.
    uint256 private constant PRICE_UNIT = 1e8;

    enum ChangeKind {
        Add,
        ForcedRemove,
        DiscretionaryRemove
    }

    // --- Delay bounds ---

    uint256 public constant MIN_ADD_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public constant MIN_DISCRETIONARY_DELAY = 1 days;

    // --- Wiring ---

    IndexVault public immutable VAULT;
    AssetRegistry public immutable REGISTRY;
    ISupplyOracle public immutable ORACLE;

    /// @notice May veto (cancel) a pending change in its window.
    address public guardian;

    // --- Policy params ---

    /// @notice Timelock on an addition before it can execute.
    uint256 public addDelay;

    /// @notice Timelock on a forced (proven-failure) removal. Short by design.
    uint256 public forcedRemoveDelay;

    /// @notice Timelock on a discretionary (healthy-asset) removal. Long by design.
    uint256 public discretionaryRemoveDelay;

    /// @notice Minimum market cap (whole USD) an added token must clear, so a
    /// microcap cannot be slipped in for the index to trade into.
    uint256 public minConstituentUsd;

    /// @notice Floor on the constituent count after any removal, so an index can
    /// never be shrunk below what keeps it an index and keeps capping feasible.
    uint256 public minConstituentCount;

    // --- Rate limit (membership changes per rolling window) ---

    uint256 public maxChangesPerWindow;
    uint256 public windowLength;
    uint64 public windowStart;
    uint256 public changesInWindow;

    // Proposal scheduling (eta store) lives in TimelockedProposals.

    // ========================================================================
    // Events
    // ========================================================================

    event GuardianSet(address indexed guardian);
    event ParamsSet(
        uint256 addDelay,
        uint256 forcedRemoveDelay,
        uint256 discretionaryRemoveDelay,
        uint256 minConstituentUsd,
        uint256 minConstituentCount
    );
    event RateLimitSet(uint256 maxChangesPerWindow, uint256 windowLength);
    event ProposalCreated(
        bytes32 indexed id, address indexed token, ChangeKind indexed kind, uint256 eta, string justification
    );
    event ProposalCancelled(bytes32 indexed id, address indexed token, ChangeKind indexed kind);
    event ProposalExecuted(bytes32 indexed id, address indexed token, ChangeKind indexed kind);
    event RemovalFinalized(address indexed token);

    constructor(
        IndexVault vault,
        AssetRegistry registry,
        ISupplyOracle oracle,
        address guardian_,
        address initialOwner,
        uint256 addDelay_,
        uint256 forcedRemoveDelay_,
        uint256 discretionaryRemoveDelay_,
        uint256 minConstituentUsd_,
        uint256 minConstituentCount_,
        uint256 maxChangesPerWindow_,
        uint256 windowLength_
    ) Ownable(initialOwner) {
        if (
            address(vault) == address(0) || address(registry) == address(0) || address(oracle) == address(0)
                || guardian_ == address(0)
        ) {
            revert ConstituentGovernor_ZeroAddress();
        }
        VAULT = vault;
        REGISTRY = registry;
        ORACLE = oracle;
        guardian = guardian_;
        emit GuardianSet(guardian_);

        _setParams(addDelay_, forcedRemoveDelay_, discretionaryRemoveDelay_, minConstituentUsd_, minConstituentCount_);
        _setRateLimit(maxChangesPerWindow_, windowLength_);
        windowStart = uint64(block.timestamp);
    }

    // ========================================================================
    // Proposal lifecycle
    // ========================================================================

    /// @notice Deterministic id for a (token, kind) proposal.
    function proposalId(address token, ChangeKind kind) public pure returns (bytes32) {
        return keccak256(abi.encode(token, kind));
    }

    /// @notice Proposes adding a registered token. Static eligibility is checked
    /// now; the size floor, rate limit, and re-validation happen at execution,
    /// since price and supply can move across the timelock.
    function proposeAdd(address token, string calldata justification) external onlyOwner returns (bytes32 id) {
        if (token == address(0)) revert ConstituentGovernor_ZeroAddress();
        if (!REGISTRY.isRegistered(token)) revert ConstituentGovernor_NotRegistered(token);
        if (VAULT.isConstituent(token)) revert ConstituentGovernor_AlreadyConstituent(token);
        id = _createProposal(token, ChangeKind.Add, addDelay, justification);
    }

    /// @notice Proposes a fast removal of a constituent the contract can prove
    /// has failed. Reverts if the asset is in fact healthy and material, so a
    /// good asset can never be removed on this path.
    function proposeForcedRemove(address token, string calldata justification) external onlyOwner returns (bytes32 id) {
        if (!VAULT.isConstituent(token)) revert ConstituentGovernor_NotConstituent(token);
        if (!_isFailed(token)) revert ConstituentGovernor_AssetHealthy(token);
        id = _createProposal(token, ChangeKind.ForcedRemove, forcedRemoveDelay, justification);
    }

    /// @notice Proposes a slow, vetoable removal of a healthy constituent, the
    /// discretionary re-curation lever.
    function proposeDiscretionaryRemove(address token, string calldata justification)
        external
        onlyOwner
        returns (bytes32 id)
    {
        if (!VAULT.isConstituent(token)) revert ConstituentGovernor_NotConstituent(token);
        id = _createProposal(token, ChangeKind.DiscretionaryRemove, discretionaryRemoveDelay, justification);
    }

    /// @notice Cancels a pending proposal. The guardian veto (16.4), also open to
    /// the owner.
    function cancelProposal(address token, ChangeKind kind) external {
        if (msg.sender != guardian && msg.sender != owner()) {
            revert ConstituentGovernor_NotGuardianOrOwner(msg.sender);
        }
        bytes32 id = proposalId(token, kind);
        _cancel(id);
        emit ProposalCancelled(id, token, kind);
    }

    // ========================================================================
    // Execution (permissionless: the timelock, not the caller, is the gate)
    // ========================================================================

    /// @notice Executes an addition: re-validates eligibility and the size floor,
    /// consumes the rate limit, and installs the constituent.
    function executeAdd(address token) external {
        _consumeProposal(token, ChangeKind.Add);

        if (!REGISTRY.isRegistered(token)) revert ConstituentGovernor_NotRegistered(token);
        if (VAULT.isConstituent(token)) revert ConstituentGovernor_AlreadyConstituent(token);

        uint256 mcap = _marketCapUsd(token);
        if (mcap < minConstituentUsd) revert ConstituentGovernor_BelowMinSize(token, mcap, minConstituentUsd);

        _consumeRateLimit();
        VAULT.governorAddConstituent(token);
        emit ProposalExecuted(proposalId(token, ChangeKind.Add), token, ChangeKind.Add);
    }

    /// @notice Executes a forced removal: re-checks the failure proof, then
    /// begins the wind-down. Finalize once the position is dust.
    function executeForcedRemove(address token) external {
        _consumeProposal(token, ChangeKind.ForcedRemove);
        if (!_isFailed(token)) revert ConstituentGovernor_AssetHealthy(token);
        _beginRemoval(token, ChangeKind.ForcedRemove);
    }

    /// @notice Executes a discretionary removal: begins the wind-down after the
    /// long timelock and veto window.
    function executeDiscretionaryRemove(address token) external {
        _consumeProposal(token, ChangeKind.DiscretionaryRemove);
        _beginRemoval(token, ChangeKind.DiscretionaryRemove);
    }

    /// @notice Finalizes a removal once the vault reports the position is dust.
    /// Permissionless: it is a mechanical completion the vault gates on value,
    /// and it enforces the minimum-count invariant at the moment the set shrinks.
    function finalizeRemoval(address token) external {
        uint256 count = VAULT.constituentCount();
        if (count - 1 < minConstituentCount) revert ConstituentGovernor_BelowMinCount(count - 1, minConstituentCount);
        VAULT.governorFinalizeRemoval(token);
        emit RemovalFinalized(token);
    }

    // ========================================================================
    // Admin
    // ========================================================================

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ConstituentGovernor_ZeroAddress();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setParams(
        uint256 addDelay_,
        uint256 forcedRemoveDelay_,
        uint256 discretionaryRemoveDelay_,
        uint256 minConstituentUsd_,
        uint256 minConstituentCount_
    ) external onlyOwner {
        _setParams(addDelay_, forcedRemoveDelay_, discretionaryRemoveDelay_, minConstituentUsd_, minConstituentCount_);
    }

    function setRateLimit(uint256 maxChangesPerWindow_, uint256 windowLength_) external onlyOwner {
        _setRateLimit(maxChangesPerWindow_, windowLength_);
    }

    // ========================================================================
    // Internal
    // ========================================================================

    function _createProposal(address token, ChangeKind kind, uint256 delay, string calldata justification)
        private
        returns (bytes32 id)
    {
        id = proposalId(token, kind);
        uint64 eta = _schedule(id, delay);
        emit ProposalCreated(id, token, kind, eta, justification);
    }

    function _consumeProposal(address token, ChangeKind kind) private {
        _consume(proposalId(token, kind));
    }

    /// @dev Both removal paths share the rate limit and the wind-down begin. The
    /// minimum-count invariant is enforced later, at finalize, where the set
    /// actually shrinks.
    function _beginRemoval(address token, ChangeKind kind) private {
        _consumeRateLimit();
        VAULT.governorBeginWindDown(token);
        emit ProposalExecuted(proposalId(token, kind), token, kind);
    }

    function _consumeRateLimit() private {
        if (block.timestamp >= windowStart + windowLength) {
            windowStart = uint64(block.timestamp);
            changesInWindow = 0;
        }
        if (changesInWindow >= maxChangesPerWindow) {
            revert ConstituentGovernor_RateLimited(changesInWindow, maxChangesPerWindow);
        }
        changesInWindow += 1;
    }

    /// @dev True when the contract can prove the asset failed: deregistered from
    /// the catalog, unpriceable (dead or stale feed), or its supply entry failed
    /// (frozen, uninitialized, or zero). The price and supply reads are wrapped
    /// so a revert is read as failure rather than bubbling up.
    function _isFailed(address token) private view returns (bool) {
        if (!REGISTRY.isRegistered(token)) return true;

        try REGISTRY.getPriceUsd(token) returns (uint256 price) {
            if (price == 0) return true;
        } catch {
            return true;
        }

        try ORACLE.getFreeFloatSupply(token) returns (uint256 supply) {
            if (supply == 0) return true;
        } catch {
            return true;
        }

        return false;
    }

    /// @dev Market cap in whole USD: float-adjusted supply times 8-decimal price.
    /// Reverts if the asset cannot be priced, which correctly blocks adding an
    /// asset the index could not value.
    function _marketCapUsd(address token) private view returns (uint256) {
        uint256 price = REGISTRY.getPriceUsd(token);
        uint256 supply = ORACLE.getFreeFloatSupply(token);
        return supply.mulDiv(price, PRICE_UNIT, Math.Rounding.Floor);
    }

    function _setParams(
        uint256 addDelay_,
        uint256 forcedRemoveDelay_,
        uint256 discretionaryRemoveDelay_,
        uint256 minConstituentUsd_,
        uint256 minConstituentCount_
    ) private {
        if (
            addDelay_ < MIN_ADD_DELAY || addDelay_ > MAX_DELAY || forcedRemoveDelay_ > MAX_DELAY
                || discretionaryRemoveDelay_ < MIN_DISCRETIONARY_DELAY || discretionaryRemoveDelay_ > MAX_DELAY
                || minConstituentUsd_ == 0 || minConstituentCount_ < 2
        ) {
            revert ConstituentGovernor_InvalidParams();
        }
        addDelay = addDelay_;
        forcedRemoveDelay = forcedRemoveDelay_;
        discretionaryRemoveDelay = discretionaryRemoveDelay_;
        minConstituentUsd = minConstituentUsd_;
        minConstituentCount = minConstituentCount_;
        emit ParamsSet(
            addDelay_, forcedRemoveDelay_, discretionaryRemoveDelay_, minConstituentUsd_, minConstituentCount_
        );
    }

    function _setRateLimit(uint256 maxChangesPerWindow_, uint256 windowLength_) private {
        if (maxChangesPerWindow_ == 0 || windowLength_ == 0) revert ConstituentGovernor_InvalidParams();
        maxChangesPerWindow = maxChangesPerWindow_;
        windowLength = windowLength_;
        emit RateLimitSet(maxChangesPerWindow_, windowLength_);
    }
}
