// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { WeightMath } from "src/libraries/WeightMath.sol";

contract WeightMathTest is Test {
    uint256 internal constant WAD = 1e18;

    // ========================================================================
    // applyCap, hand-computed cases
    // ========================================================================

    function test_ApplyCap_NoOpWhenAllUnderCap() public pure {
        uint256[] memory w = _weights3(0.5e18, 0.3e18, 0.2e18);
        w = WeightMath.applyCap(w, 0.6e18);
        assertEq(w[0], 0.5e18);
        assertEq(w[1], 0.3e18);
        assertEq(w[2], 0.2e18);
    }

    /// @notice The iterative cascade: redistribution pushes a previously
    /// uncapped name over the cap, requiring a second round.
    /// 60/30/10 at cap 35: round one caps 60 and lifts 30 to 48.75, round two
    /// caps 48.75 and lifts 10 to 30. Final 35/35/30.
    function test_ApplyCap_IterativeCascade() public pure {
        uint256[] memory w = _weights3(0.6e18, 0.3e18, 0.1e18);
        w = WeightMath.applyCap(w, 0.35e18);
        assertEq(w[0], 0.35e18);
        assertEq(w[1], 0.35e18);
        assertEq(w[2], 0.3e18);
    }

    /// @notice Exact-fit degenerate case: with n * cap == WAD every
    /// constituent ends pinned at the cap.
    function test_ApplyCap_DegenerateAllAtCap() public pure {
        uint256[] memory w = new uint256[](4);
        w[0] = 0.7e18;
        w[1] = 0.1e18;
        w[2] = 0.1e18;
        w[3] = 0.1e18;
        w = WeightMath.applyCap(w, 0.25e18);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(w[i], 0.25e18);
        }
    }

    function test_ApplyCap_RevertsWhenInfeasible() public {
        uint256[] memory w = _weights3(0.6e18, 0.3e18, 0.1e18);
        vm.expectRevert(abi.encodeWithSelector(WeightMath.WeightMath_CapInfeasible.selector, 3, 0.3e18));
        this.applyCapExternal(w, 0.3e18);
    }

    // ========================================================================
    // applyCap, property fuzz
    // ========================================================================

    /// @notice For any normalized weight vector and feasible cap: the output
    /// sums to exactly WAD, no weight exceeds the cap, and the loop converges
    /// without reverting.
    function testFuzz_ApplyCap_Invariants(uint256[8] memory raw, uint256 capSeed) public view {
        uint256[] memory scores = new uint256[](8);
        scores[0] = bound(raw[0], 1, 1e24); // at least one nonzero score
        for (uint256 i = 1; i < 8; i++) {
            scores[i] = bound(raw[i], 0, 1e24);
        }
        uint256 cap = bound(capSeed, WAD / 8 + 1, WAD);

        uint256[] memory w = WeightMath.normalize(scores);
        uint256 support = 0;
        for (uint256 i = 0; i < 8; i++) {
            if (w[i] > 0) support++;
        }

        try this.applyCapExternal(w, cap) returns (uint256[] memory capped) {
            assertGe(support * cap, WAD, "succeeded despite infeasible support");
            uint256 sum = 0;
            for (uint256 i = 0; i < 8; i++) {
                assertLe(capped[i], cap, "weight exceeds cap");
                sum += capped[i];
            }
            assertEq(sum, WAD, "weights do not sum to WAD");
        } catch {
            // The only legitimate failure is genuinely infeasible support.
            assertLt(support * cap, WAD, "reverted despite feasible support");
        }
    }

    /// @notice Capping must preserve relative ordering: a larger input weight
    /// never ends below a smaller one.
    function testFuzz_ApplyCap_PreservesOrdering(uint256[8] memory raw, uint256 capSeed) public view {
        uint256[] memory scores = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            // Descending construction keeps the expected order explicit.
            scores[i] = bound(raw[i], 1, 1e24) / (i + 1);
            if (scores[i] == 0) scores[i] = 1;
        }
        // Sort descending so input ordering is known.
        for (uint256 i = 0; i < 8; i++) {
            for (uint256 j = i + 1; j < 8; j++) {
                if (scores[j] > scores[i]) (scores[i], scores[j]) = (scores[j], scores[i]);
            }
        }
        uint256 cap = bound(capSeed, WAD / 8 + 1, WAD);

        uint256[] memory w = WeightMath.normalize(scores);
        uint256[] memory capped;
        try this.applyCapExternal(w, cap) returns (uint256[] memory result) {
            capped = result;
        } catch {
            return; // degenerate support, covered by the invariants fuzz
        }

        for (uint256 i = 1; i < 8; i++) {
            // Dust placement targets max headroom, so allow 8 wei of slack.
            assertGe(capped[i - 1] + 8, capped[i], "capping inverted ordering");
        }
    }

    // ========================================================================
    // applyFloor
    // ========================================================================

    function test_ApplyFloor_PrunesDustAndRenormalizes() public pure {
        uint256[] memory w = new uint256[](4);
        w[0] = 0.55e18;
        w[1] = 0.3e18;
        w[2] = 0.15e18 - 1e10;
        w[3] = 1e10; // dust position, below the 1e14 floor
        w = WeightMath.applyFloor(w, 1e14, 0.6e18);

        assertEq(w[3], 0, "dust position not pruned");
        uint256 sum = 0;
        for (uint256 i = 0; i < 4; i++) {
            assertLe(w[i], 0.6e18);
            sum += w[i];
        }
        assertEq(sum, WAD);
        // Survivors scaled up pro-rata.
        assertGt(w[0], 0.55e18);
        assertGt(w[1], 0.3e18);
    }

    function test_ApplyFloor_ReappliesCapAfterRedistribution() public pure {
        uint256[] memory w = new uint256[](4);
        w[0] = 0.59e18; // close to cap; pruning pushes it over
        w[1] = 0.2e18;
        w[2] = 0.2e18;
        w[3] = 0.01e18 - 1; // just below a 1% floor
        w = WeightMath.applyFloor(w, 0.01e18, 0.6e18);

        assertEq(w[3], 0);
        uint256 sum = 0;
        for (uint256 i = 0; i < 4; i++) {
            assertLe(w[i], 0.6e18, "cap violated after floor redistribution");
            sum += w[i];
        }
        assertEq(sum, WAD);
    }

    function testFuzz_ApplyFloor_Invariants(uint256[8] memory raw, uint256 capSeed, uint256 floorSeed) public view {
        uint256[] memory scores = new uint256[](8);
        scores[0] = bound(raw[0], 1e20, 1e24); // anchor survivor above any floor
        for (uint256 i = 1; i < 8; i++) {
            scores[i] = bound(raw[i], 0, 1e24);
        }
        uint256 cap = bound(capSeed, WAD / 4, WAD); // headroom even after pruning
        uint256 floor = bound(floorSeed, 1, 1e14);

        uint256[] memory w;
        try this.capAndFloorExternal(scores, cap, floor) returns (uint256[] memory result) {
            w = result;
        } catch {
            return; // pruning shrank support below feasibility; fail-closed is correct
        }

        uint256 sum = 0;
        for (uint256 i = 0; i < 8; i++) {
            assertTrue(w[i] == 0 || w[i] >= floor, "weight between zero and floor");
            assertLe(w[i], cap);
            sum += w[i];
        }
        assertEq(sum, WAD);
    }

    // ========================================================================
    // Reconstitution buffer rule
    // ========================================================================

    function test_BufferRule_EntryAndExitBands() public pure {
        // N = 100, b = 10: entry at rank 90, exit below rank 110.
        assertTrue(WeightMath.qualifiesForEntry(90, 100, 10));
        assertFalse(WeightMath.qualifiesForEntry(91, 100, 10));
        assertFalse(WeightMath.qualifiesForEntry(100, 100, 10));

        assertFalse(WeightMath.qualifiesForExit(100, 100, 10));
        assertFalse(WeightMath.qualifiesForExit(110, 100, 10));
        assertTrue(WeightMath.qualifiesForExit(111, 100, 10));
    }

    /// @notice The buffer creates hysteresis: ranks inside (N - b, N + b] are
    /// sticky in whichever state they already hold.
    function testFuzz_BufferRule_NoChurnInsideBand(uint256 rank) public pure {
        rank = bound(rank, 91, 110);
        assertFalse(WeightMath.qualifiesForEntry(rank, 100, 10));
        assertFalse(WeightMath.qualifiesForExit(rank, 100, 10));
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    /// @dev External wrapper so expectRevert and try/catch can target a library call.
    function applyCapExternal(uint256[] memory w, uint256 cap) external pure returns (uint256[] memory) {
        return WeightMath.applyCap(w, cap);
    }

    /// @dev External wrapper for the full normalize-cap-floor pipeline.
    function capAndFloorExternal(uint256[] memory scores, uint256 cap, uint256 floor)
        external
        pure
        returns (uint256[] memory)
    {
        uint256[] memory w = WeightMath.normalize(scores);
        w = WeightMath.applyCap(w, cap);
        return WeightMath.applyFloor(w, floor, cap);
    }

    function _weights3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory w) {
        w = new uint256[](3);
        w[0] = a;
        w[1] = b;
        w[2] = c;
    }
}
