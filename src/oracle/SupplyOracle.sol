// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { ExcludedAddressRegistry } from "src/oracle/ExcludedAddressRegistry.sol";

// ============================================================================
// Errors
// ============================================================================

error SupplyOracle_ZeroAddress();
error SupplyOracle_NotReporter(address caller);
error SupplyOracle_NotGuardian(address caller);
error SupplyOracle_Paused();

/// @notice Thrown when the free-float factor read or reported exceeds 1e18,
/// which would claim more free float than circulating supply.
error SupplyOracle_FactorAboveOne(uint256 factorWad);

/// @notice Thrown when a token has no committed factor yet (never initialized).
error SupplyOracle_NotInitialized(address token);

/// @notice Thrown by the read path when the last commit is older than the hard
/// ceiling, distinct from the soft freeze that serves last-good.
error SupplyOracle_CommitTooOld(address token, uint256 committedAt, uint256 maxAge);

/// @notice Thrown when a commit cannot gather enough fresh reporter values.
error SupplyOracle_NotEnoughFreshReports(address token, uint256 fresh, uint256 required);

/// @notice Thrown when fresh reporter values disagree beyond tolerance: the
/// divergence freeze. The commit reverts, so last-good persists untouched.
error SupplyOracle_SourcesDiverged(address token, uint256 spreadBps, uint256 toleranceBps);

/// @notice Thrown when commit is called again before minCommitInterval has
/// elapsed since the token's last successful commit. This makes the rate-limit
/// per-time rather than per-call, so the factor cannot be walked to the median
/// by repeated permissionless commits inside a single block.
error SupplyOracle_CommitTooSoon(address token, uint256 nextAllowedAt);

error SupplyOracle_AlreadyReporter(address reporter);
error SupplyOracle_UnknownReporter(address reporter);
error SupplyOracle_TooManyReporters();
error SupplyOracle_InvalidParams();

/**
 * @title SupplyOracle
 * @notice Layers 2 and 3 of the supply-oracle design, built
 * on the Layer 1 on-chain derivation in ExcludedAddressRegistry.
 *
 * Free-float supply is expressed as
 *
 *     freeFloat = onChainCirculating * freeFloatFactor / 1e18
 *
 * where onChainCirculating is the trustless Layer 1 figure and freeFloatFactor
 * in (0, 1e18] is the secured residual: the fraction of on-chain-circulating
 * supply that is genuinely free-floating once off-chain lock status (exchange
 * cold storage, OTC locks, off-chain vesting) is accounted for. Expressing the
 * residual as a bounded factor rather than an absolute number is what makes
 * the on-chain floor a hard cap on the output: factor <= 1e18 means free-float
 * can never exceed circulating, by construction.
 *
 * Layer 2, secure the residual. Independent reporters push factor values. A
 * commit gathers the fresh ones, takes their median, and requires at least
 * `minReporters` of them to agree within `divergenceToleranceBps`. If they
 * disagree, the commit reverts and the constituent freezes at its last-good
 * factor rather than acting on disputed data. This interface is shaped so an
 * optimistic oracle can later replace the reporter-median residual per
 * constituent without the methodology engine noticing.
 *
 * Layer 3, contain. The committed factor moves toward the median by at most
 * `maxFactorDeltaBps` per commit, and a `minCommitInterval` cooldown spreads
 * those commits across time, so the factor moves at most one step per interval
 * however often commit is called, and a malicious spike cannot move the index
 * more than one step before a human reacts. The cooldown is load-bearing:
 * without it, commit being permissionless and cooldown-free would let anyone
 * walk the factor to the median with repeated calls in a single block. A hard
 * `maxCommitAge` ceiling fails the read closed if every reporter has gone
 * silent for too long, and the guardian can pause all reads outright.
 */
contract SupplyOracle is ISupplyOracle, Ownable2Step {
    using Math for uint256;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_REPORTERS = 16;

    struct Report {
        uint256 factorWad;
        uint64 timestamp;
    }

    struct Committed {
        uint256 factorWad;
        uint64 timestamp;
        bool initialized;
    }

    /// @notice Layer 1 on-chain circulating-supply source.
    ExcludedAddressRegistry public immutable EXCLUDED;

    /// @notice Guardian with pause-only powers.
    address public guardian;

    /// @notice When true, every read fails closed.
    bool public paused;

    /// @dev Authorized reporter set.
    address[] private _reporterList;
    mapping(address reporter => bool) public isReporter;

    /// @dev Latest pushed value per (token, reporter).
    mapping(address token => mapping(address reporter => Report)) public reports;

    /// @dev Committed (last-good) factor per token.
    mapping(address token => Committed) public committed;

    // --- Layer 2 / Layer 3 parameters ---

    /// @notice Minimum number of agreeing fresh reports to commit (the k in k-of-n).
    uint256 public minReporters = 2;

    /// @notice Maximum spread between agreeing reports, in bps of the median.
    uint256 public divergenceToleranceBps = 200;

    /// @notice A report older than this is not fresh and is ignored on commit.
    uint256 public reportStaleAfter = 1 days;

    /// @notice Hard ceiling: a committed factor older than this fails reads closed.
    uint256 public maxCommitAge = 30 days;

    /// @notice Maximum per-commit move of the factor, in bps of the prior factor.
    uint256 public maxFactorDeltaBps = 1000;

    /// @notice Minimum wall-clock seconds between successful commits for a token.
    /// Combined with the per-commit clamp, this bounds the factor's rate of
    /// change to one maxStep per interval regardless of how often commit is
    /// called, which is what gives a human time to react to a malicious move.
    uint256 public minCommitInterval = 1 hours;

    event GuardianSet(address indexed guardian);
    event PausedSet(bool paused);
    event ReporterAdded(address indexed reporter);
    event ReporterRemoved(address indexed reporter);
    event Reported(address indexed token, address indexed reporter, uint256 factorWad);
    event Committed_(address indexed token, uint256 factorWad, uint256 median, uint256 freshCount);
    event ParamsSet(
        uint256 minReporters,
        uint256 divergenceToleranceBps,
        uint256 reportStaleAfter,
        uint256 maxCommitAge,
        uint256 maxFactorDeltaBps,
        uint256 minCommitInterval
    );

    modifier onlyReporter() {
        if (!isReporter[msg.sender]) revert SupplyOracle_NotReporter(msg.sender);
        _;
    }

    constructor(ExcludedAddressRegistry excluded, address guardian_, address initialOwner) Ownable(initialOwner) {
        if (address(excluded) == address(0) || guardian_ == address(0)) revert SupplyOracle_ZeroAddress();
        EXCLUDED = excluded;
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    // ========================================================================
    // Read path (ISupplyOracle)
    // ========================================================================

    /// @inheritdoc ISupplyOracle
    /// @dev Fails closed on pause, missing initialization, or a last-good
    /// factor past the hard ceiling. Soft staleness (a quiet reporter set
    /// inside maxCommitAge) keeps serving last-good: the freeze, not a revert.
    function getFreeFloatSupply(address token) external view returns (uint256) {
        if (paused) revert SupplyOracle_Paused();

        Committed memory c = committed[token];
        if (!c.initialized) revert SupplyOracle_NotInitialized(token);
        if (block.timestamp > c.timestamp + maxCommitAge) {
            revert SupplyOracle_CommitTooOld(token, c.timestamp, maxCommitAge);
        }

        uint256 circulating = EXCLUDED.onChainCirculating(token);
        // factor <= WAD (enforced on commit), so free-float <= circulating.
        return circulating.mulDiv(c.factorWad, WAD, Math.Rounding.Floor);
    }

    /// @notice The committed free-float factor and its age, for off-chain
    /// monitoring of which constituents are frozen.
    function freeFloatFactor(address token)
        external
        view
        returns (uint256 factorWad, uint256 committedAt, bool frozen)
    {
        Committed memory c = committed[token];
        factorWad = c.factorWad;
        committedAt = c.timestamp;
        // Frozen here means no fresh quorum could update it recently, surfaced
        // for dashboards; the read still serves last-good until maxCommitAge.
        frozen = c.initialized && block.timestamp > c.timestamp + reportStaleAfter;
    }

    // ========================================================================
    // Layer 2: report and commit
    // ========================================================================

    /// @notice A reporter pushes its observed free-float factor for `token`.
    function report(address token, uint256 factorWad) external onlyReporter {
        if (token == address(0)) revert SupplyOracle_ZeroAddress();
        if (factorWad == 0 || factorWad > WAD) revert SupplyOracle_FactorAboveOne(factorWad);
        reports[token][msg.sender] = Report({ factorWad: factorWad, timestamp: uint64(block.timestamp) });
        emit Reported(token, msg.sender, factorWad);
    }

    /**
     * @notice Consolidates fresh reporter values for `token` into a new
     * committed factor. Permissionless: anyone (in practice a keeper) can call
     * it, because every gate is on the data, not the caller.
     * @dev Reverts, leaving last-good untouched, when there are too few fresh
     * reports or when they diverge beyond tolerance. On success the committed
     * factor moves toward the median by at most maxFactorDeltaBps.
     */
    function commit(address token) external {
        if (paused) revert SupplyOracle_Paused();

        // Per-time rate-limit. A token's factor cannot be committed again until
        // minCommitInterval has elapsed since its last successful commit. This
        // is what turns the per-commit clamp below into an actual rate limit:
        // without it, commit being permissionless and cooldown-free would let
        // anyone walk the factor to the median with repeated calls in one block.
        Committed memory prev = committed[token];
        if (prev.initialized && block.timestamp < uint256(prev.timestamp) + minCommitInterval) {
            revert SupplyOracle_CommitTooSoon(token, uint256(prev.timestamp) + minCommitInterval);
        }

        // Gather fresh reporter values.
        uint256 n = _reporterList.length;
        uint256[] memory fresh = new uint256[](n);
        uint256 count = 0;
        uint256 cutoff = block.timestamp - Math.min(block.timestamp, reportStaleAfter);
        for (uint256 i = 0; i < n; i++) {
            Report memory r = reports[token][_reporterList[i]];
            if (r.timestamp != 0 && r.timestamp >= cutoff) {
                fresh[count++] = r.factorWad;
            }
        }
        if (count < minReporters) revert SupplyOracle_NotEnoughFreshReports(token, count, minReporters);

        // Trim to the populated prefix and sort ascending for the median.
        uint256[] memory values = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            values[i] = fresh[i];
        }
        _sort(values);
        uint256 median = _median(values);

        // Divergence freeze: require at least minReporters within tolerance of
        // the median. Otherwise revert so the constituent stays frozen.
        uint256 band = median.mulDiv(divergenceToleranceBps, BPS, Math.Rounding.Ceil);
        uint256 agree = 0;
        for (uint256 i = 0; i < count; i++) {
            uint256 diff = values[i] > median ? values[i] - median : median - values[i];
            if (diff <= band) agree++;
        }
        if (agree < minReporters) {
            // Report the full spread for the revert reason.
            uint256 spread = values[count - 1] - values[0];
            uint256 spreadBps = median == 0 ? 0 : spread.mulDiv(BPS, median, Math.Rounding.Ceil);
            revert SupplyOracle_SourcesDiverged(token, spreadBps, divergenceToleranceBps);
        }

        // Round the agreed median to a coarse float-factor tier (CRSP Effective
        // Float Factor style) so small, noisy float changes do not move target
        // weights: a median that wiggles within a tier produces the same target,
        // and once the committed value has converged to it no further commit
        // moves it.
        uint256 target = _roundFactorWad(median);

        // Layer 3 rate-limit: clamp the move toward the rounded target so a
        // large jump is approached over several commits, each at least
        // minCommitInterval apart (enforced above), rather than landing at once.
        uint256 next = target;
        if (prev.initialized) {
            uint256 maxStep = prev.factorWad.mulDiv(maxFactorDeltaBps, BPS, Math.Rounding.Floor);
            if (target > prev.factorWad + maxStep) {
                next = prev.factorWad + maxStep;
            } else if (target + maxStep < prev.factorWad) {
                next = prev.factorWad - maxStep;
            }
        }
        if (next > WAD) next = WAD; // structural cap; target is already <= WAD

        committed[token] = Committed({ factorWad: next, timestamp: uint64(block.timestamp), initialized: true });
        emit Committed_(token, next, median, count);
    }

    // ========================================================================
    // Admin and guardian
    // ========================================================================

    function addReporter(address reporter) external onlyOwner {
        if (reporter == address(0)) revert SupplyOracle_ZeroAddress();
        if (isReporter[reporter]) revert SupplyOracle_AlreadyReporter(reporter);
        if (_reporterList.length >= MAX_REPORTERS) revert SupplyOracle_TooManyReporters();
        isReporter[reporter] = true;
        _reporterList.push(reporter);
        emit ReporterAdded(reporter);
    }

    function removeReporter(address reporter) external onlyOwner {
        if (!isReporter[reporter]) revert SupplyOracle_UnknownReporter(reporter);
        isReporter[reporter] = false;
        uint256 len = _reporterList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_reporterList[i] == reporter) {
                _reporterList[i] = _reporterList[len - 1];
                _reporterList.pop();
                break;
            }
        }
        emit ReporterRemoved(reporter);
    }

    function reporters() external view returns (address[] memory) {
        return _reporterList;
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert SupplyOracle_ZeroAddress();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// @notice Guardian can pause; owner can unpause (pause-only powers).
    function pause() external {
        if (msg.sender != guardian) revert SupplyOracle_NotGuardian(msg.sender);
        paused = true;
        emit PausedSet(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit PausedSet(false);
    }

    function setParams(
        uint256 minReporters_,
        uint256 divergenceToleranceBps_,
        uint256 reportStaleAfter_,
        uint256 maxCommitAge_,
        uint256 maxFactorDeltaBps_,
        uint256 minCommitInterval_
    ) external onlyOwner {
        if (
            minReporters_ == 0 || minReporters_ > MAX_REPORTERS || divergenceToleranceBps_ > BPS
                || reportStaleAfter_ == 0 || maxCommitAge_ < reportStaleAfter_ || maxFactorDeltaBps_ == 0
                || maxFactorDeltaBps_ > BPS || minCommitInterval_ == 0 || minCommitInterval_ > maxCommitAge_
        ) {
            revert SupplyOracle_InvalidParams();
        }
        minReporters = minReporters_;
        divergenceToleranceBps = divergenceToleranceBps_;
        reportStaleAfter = reportStaleAfter_;
        maxCommitAge = maxCommitAge_;
        maxFactorDeltaBps = maxFactorDeltaBps_;
        minCommitInterval = minCommitInterval_;
        emit ParamsSet(
            minReporters_,
            divergenceToleranceBps_,
            reportStaleAfter_,
            maxCommitAge_,
            maxFactorDeltaBps_,
            minCommitInterval_
        );
    }

    // ========================================================================
    // Internal math
    // ========================================================================

    /// @dev Insertion sort, ascending. Bounded by MAX_REPORTERS, so the
    /// quadratic cost is on a set of at most 16 elements.
    function _sort(uint256[] memory a) private pure {
        for (uint256 i = 1; i < a.length; i++) {
            uint256 key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }
    }

    /// @dev Median of a pre-sorted array. Even length averages the two middle
    /// elements (floor), odd length takes the center.
    function _median(uint256[] memory sorted) private pure returns (uint256) {
        uint256 len = sorted.length;
        uint256 mid = len / 2;
        if (len % 2 == 1) return sorted[mid];
        return (sorted[mid - 1] + sorted[mid]) / 2;
    }

    /// @dev Rounds a free-float factor to a coarse tier, modelled on CRSP's
    /// Effective Float Factor: nearest 5% at or above 10% float, nearest 1%
    /// between 1% and 10%, nearest 0.1% below 1%. A nonzero factor never rounds
    /// to zero. Coarse rounding is what suppresses needless re-weighting on
    /// small, noisy float changes.
    function _roundFactorWad(uint256 f) private pure returns (uint256) {
        if (f == 0) return 0;
        uint256 tier = f >= 1e17 ? 5e16 : (f >= 1e16 ? 1e16 : 1e15);
        uint256 rounded = ((f + tier / 2) / tier) * tier;
        if (rounded > WAD) rounded = WAD;
        if (rounded == 0) rounded = tier;
        return rounded;
    }
}
