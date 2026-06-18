// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title WeightMath
 * @notice Pure index-weighting math: iterative cap-and-redistribute, exact
 * renormalization, and the minimum-weight floor. This is the textbook capped
 * market-cap methodology: a hard per-asset cap with the
 * overflow redistributed pro-rata to uncapped constituents, iterated because
 * redistribution can push a previously-uncapped name over the cap.
 *
 * Exact invariants, enforced rather than approximated:
 * - Output weights sum to exactly WAD.
 * - No output weight exceeds the cap (rounding dust is parked greedily in
 *   whatever constituents have headroom, never on top of a capped one).
 * - Reverts when the nonzero support k satisfies k * cap < WAD, since
 *   capping is then infeasible.
 */
library WeightMath {
    /// @notice Weight precision: 1e18 is 100%.
    uint256 internal constant WAD = 1e18;

    /// @notice Thrown when the cap cannot absorb full weight: the number of
    /// nonzero-weight constituents k satisfies k * cap < WAD, so no vector
    /// can simultaneously sum to WAD and respect the cap.
    error WeightMath_CapInfeasible(uint256 support, uint256 cap);

    /// @notice Thrown when the input weights sum to zero.
    error WeightMath_ZeroTotalWeight();

    /// @notice Thrown when renormalization dust cannot be placed under the cap.
    /// Unreachable when the feasibility check passed; kept as a hard backstop.
    error WeightMath_DustPlacementFailed();

    /**
     * @notice Normalizes raw scores (for example market caps) into weights
     * summing to at most WAD. Floor rounding keeps the result conservative;
     * the deficit is repaired exactly in the capping stage.
     */
    function normalize(uint256[] memory raw) internal pure returns (uint256[] memory weights) {
        uint256 n = raw.length;
        uint256 total = 0;
        for (uint256 i = 0; i < n; i++) {
            total += raw[i];
        }
        if (total == 0) revert WeightMath_ZeroTotalWeight();

        weights = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            weights[i] = Math.mulDiv(raw[i], WAD, total, Math.Rounding.Floor);
        }
    }

    /**
     * @notice Applies a hard per-asset cap with iterative pro-rata
     * redistribution, then renormalizes so the result sums to exactly WAD.
     * @dev Mutates and returns `weights`. The outer loop is bounded by n:
     * every iteration permanently pins at least one new constituent at the
     * cap, and a fully-pinned set exits through the break.
     * @param weights Weights summing to approximately WAD (floor dust tolerated).
     * @param cap Maximum weight per constituent, in WAD.
     */
    function applyCap(uint256[] memory weights, uint256 cap) internal pure returns (uint256[] memory) {
        uint256 n = weights.length;

        // Feasibility is decided by the nonzero support, not the array length:
        // zero-weight entries can absorb neither excess nor dust, so k of them
        // at the cap must be able to carry full weight.
        uint256 support = 0;
        for (uint256 i = 0; i < n; i++) {
            if (weights[i] > 0) support++;
        }
        if (support * cap < WAD) revert WeightMath_CapInfeasible(support, cap);

        for (uint256 round = 0; round < n; round++) {
            // Collect excess above the cap and pin offenders at the cap.
            uint256 excess = 0;
            for (uint256 i = 0; i < n; i++) {
                if (weights[i] > cap) {
                    excess += weights[i] - cap;
                    weights[i] = cap;
                }
            }
            if (excess == 0) break;

            // Redistribute pro-rata across strictly-uncapped constituents.
            uint256 base = 0;
            for (uint256 i = 0; i < n; i++) {
                if (weights[i] < cap) base += weights[i];
            }
            if (base == 0) break; // degenerate: everyone pinned at the cap

            for (uint256 i = 0; i < n; i++) {
                if (weights[i] < cap) {
                    weights[i] += Math.mulDiv(excess, weights[i], base, Math.Rounding.Floor);
                }
            }
        }

        return _renormalizeUnderCap(weights, cap);
    }

    /**
     * @notice Zeroes out constituents below the minimum-weight floor (dust
     * positions whose gas and slippage cost exceeds their contribution),
     * redistributes their weight pro-rata across survivors, and re-applies
     * the cap since redistribution only pushes weights upward.
     * @dev Survivor weights only increase, so a single pruning pass cannot
     * create new sub-floor names; no fixpoint iteration is needed.
     */
    function applyFloor(uint256[] memory weights, uint256 floor, uint256 cap) internal pure returns (uint256[] memory) {
        uint256 n = weights.length;
        uint256 surviving = 0;
        for (uint256 i = 0; i < n; i++) {
            if (weights[i] < floor) {
                weights[i] = 0;
            } else {
                surviving += weights[i];
            }
        }
        if (surviving == 0) revert WeightMath_ZeroTotalWeight();

        for (uint256 i = 0; i < n; i++) {
            if (weights[i] > 0) {
                weights[i] = Math.mulDiv(weights[i], WAD, surviving, Math.Rounding.Floor);
            }
        }

        return applyCap(weights, cap);
    }

    /**
     * @dev Brings the weight sum to exactly WAD by placing the floor-rounding
     * deficit greedily into the constituents with the most cap headroom. Total
     * headroom is n * cap - sum, which the feasibility check guarantees covers
     * the deficit, so no weight ever ends above the cap.
     */
    function _renormalizeUnderCap(uint256[] memory weights, uint256 cap) private pure returns (uint256[] memory) {
        uint256 n = weights.length;
        uint256 sum = 0;
        for (uint256 i = 0; i < n; i++) {
            sum += weights[i];
        }
        if (sum == WAD) return weights;
        if (sum > WAD) {
            // Floor rounding everywhere means the sum can only fall short; a
            // surplus indicates corrupted input, take the hard exit.
            revert WeightMath_DustPlacementFailed();
        }

        uint256 deficit = WAD - sum;
        for (uint256 round = 0; round < n && deficit > 0; round++) {
            // Carry the dust to the largest-weight constituent that still has
            // headroom below the cap. Placing it on the top names rather than
            // the most-headroom (smallest) names keeps the dust from inverting
            // the tail ordering, since the redistribution above already
            // preserves order. The tie-break is strict (`>`), so among equal
            // maxima the earliest (highest-ranked) name wins: lifting the lower-
            // ranked one would push it above its equal-weight, higher-ranked
            // sibling and invert the order by exactly the dust size. Zero-weight
            // entries are skipped so dust can never resurrect a constituent the
            // floor pruned.
            uint256 bestIdx = type(uint256).max;
            uint256 bestWeight = 0;
            for (uint256 i = 0; i < n; i++) {
                if (weights[i] == 0 || weights[i] >= cap) continue;
                if (weights[i] > bestWeight) {
                    bestWeight = weights[i];
                    bestIdx = i;
                }
            }
            if (bestIdx == type(uint256).max) revert WeightMath_DustPlacementFailed();

            uint256 headroom = cap - weights[bestIdx];
            uint256 add = deficit < headroom ? deficit : headroom;
            weights[bestIdx] += add;
            deficit -= add;
        }
        if (deficit > 0) revert WeightMath_DustPlacementFailed();

        return weights;
    }

    // ========================================================================
    // Reconstitution buffer rule
    // ========================================================================

    /**
     * @notice Membership buffer rule: a non-member only enters when it rises
     * above rank targetSize - buffer. With N = 100 and b = 10, entry happens
     * at rank 90, not on every transient crossing of rank 100.
     * @param rank 1-based float-adjusted market-cap rank.
     */
    function qualifiesForEntry(uint256 rank, uint256 targetSize, uint256 buffer) internal pure returns (bool) {
        return rank <= targetSize - buffer;
    }

    /**
     * @notice Membership buffer rule: an incumbent is only dropped when it
     * falls below rank targetSize + buffer (rank 110 in the N = 100, b = 10
     * configuration), which suppresses churn at the index boundary.
     */
    function qualifiesForExit(uint256 rank, uint256 targetSize, uint256 buffer) internal pure returns (bool) {
        return rank > targetSize + buffer;
    }
}
