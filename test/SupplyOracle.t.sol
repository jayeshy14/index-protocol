// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { ExcludedAddressRegistry } from "src/oracle/ExcludedAddressRegistry.sol";
import {
    ExcludedRegistry_TimelockNotElapsed,
    ExcludedRegistry_NoPendingChange,
    ExcludedRegistry_ChangeAlreadyPending,
    ExcludedRegistry_NoOp
} from "src/oracle/ExcludedAddressRegistry.sol";
import { SupplyOracle } from "src/oracle/SupplyOracle.sol";
import {
    SupplyOracle_Paused,
    SupplyOracle_NotInitialized,
    SupplyOracle_CommitTooOld,
    SupplyOracle_NotEnoughFreshReports,
    SupplyOracle_SourcesDiverged,
    SupplyOracle_FactorAboveOne,
    SupplyOracle_NotReporter,
    SupplyOracle_NotGuardian,
    SupplyOracle_CommitTooSoon
} from "src/oracle/SupplyOracle.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

contract SupplyOracleTest is Test {
    uint256 internal constant WAD = 1e18;

    ExcludedAddressRegistry internal registry;
    SupplyOracle internal oracle;
    MockERC20 internal token;

    address internal owner = address(this);
    address internal guardian = makeAddr("guardian");
    address internal repA = makeAddr("reporterA");
    address internal repB = makeAddr("reporterB");
    address internal repC = makeAddr("reporterC");

    address internal treasury = makeAddr("treasury");
    address internal vesting = makeAddr("vesting");

    uint256 internal constant DELAY = 2 days;

    function setUp() public {
        vm.warp(60 days);

        token = new MockERC20("Token", "TKN", 18);
        // 1,000,000 total: 600k circulating, 300k treasury, 100k vesting.
        token.mint(makeAddr("holders"), 600_000e18);
        token.mint(treasury, 300_000e18);
        token.mint(vesting, 100_000e18);

        registry = new ExcludedAddressRegistry(owner, DELAY);
        oracle = new SupplyOracle(registry, guardian, owner);

        oracle.addReporter(repA);
        oracle.addReporter(repB);
        oracle.addReporter(repC);
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    function _exclude(address account) internal {
        registry.proposeChange(address(token), account, true);
        vm.warp(block.timestamp + DELAY);
        registry.executeChange(address(token), account, true);
    }

    function _reportAll(uint256 a, uint256 b, uint256 c) internal {
        vm.prank(repA);
        oracle.report(address(token), a);
        vm.prank(repB);
        oracle.report(address(token), b);
        vm.prank(repC);
        oracle.report(address(token), c);
    }

    // ========================================================================
    // Layer 1: on-chain derivation and the timelock
    // ========================================================================

    function test_OnChainCirculating_FullSupplyWhenNoExclusions() public view {
        assertEq(registry.onChainCirculating(address(token)), 1_000_000);
    }

    function test_OnChainCirculating_SubtractsExcluded() public {
        _exclude(treasury);
        assertEq(registry.onChainCirculating(address(token)), 700_000);
        _exclude(vesting);
        assertEq(registry.onChainCirculating(address(token)), 600_000);
    }

    function test_OnChainCirculating_TracksLiveBalances() public {
        _exclude(treasury);
        // Treasury unlocks 100k into circulation.
        vm.prank(treasury);
        token.transfer(makeAddr("market"), 100_000e18);
        assertEq(registry.onChainCirculating(address(token)), 800_000);
    }

    function test_Timelock_CannotExecuteEarly() public {
        registry.proposeChange(address(token), treasury, true);
        bytes32 id = registry.changeId(address(token), treasury, true);
        (uint64 eta,,) = registry.pendingChanges(id);

        vm.expectRevert(abi.encodeWithSelector(ExcludedRegistry_TimelockNotElapsed.selector, id, eta));
        registry.executeChange(address(token), treasury, true);

        vm.warp(eta);
        registry.executeChange(address(token), treasury, true);
        assertTrue(registry.isExcluded(address(token), treasury));
    }

    function test_Timelock_ExecuteIsPermissionless() public {
        registry.proposeChange(address(token), treasury, true);
        vm.warp(block.timestamp + DELAY);
        // A non-owner finalizes a change the owner already committed to.
        vm.prank(makeAddr("anyone"));
        registry.executeChange(address(token), treasury, true);
        assertTrue(registry.isExcluded(address(token), treasury));
    }

    function test_Timelock_CancelStopsExecution() public {
        registry.proposeChange(address(token), treasury, true);
        registry.cancelChange(address(token), treasury, true);
        bytes32 id = registry.changeId(address(token), treasury, true);

        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(abi.encodeWithSelector(ExcludedRegistry_NoPendingChange.selector, id));
        registry.executeChange(address(token), treasury, true);
    }

    function test_Timelock_RejectsRedundantAndDuplicate() public {
        registry.proposeChange(address(token), treasury, true);
        bytes32 id = registry.changeId(address(token), treasury, true);
        vm.expectRevert(abi.encodeWithSelector(ExcludedRegistry_ChangeAlreadyPending.selector, id));
        registry.proposeChange(address(token), treasury, true);

        vm.warp(block.timestamp + DELAY);
        registry.executeChange(address(token), treasury, true);

        // Excluding an already-excluded address is a no-op.
        vm.expectRevert(abi.encodeWithSelector(ExcludedRegistry_NoOp.selector, address(token), treasury, true));
        registry.proposeChange(address(token), treasury, true);
    }

    function test_Timelock_RemovalPath() public {
        _exclude(treasury);
        registry.proposeChange(address(token), treasury, false);
        vm.warp(block.timestamp + DELAY);
        registry.executeChange(address(token), treasury, false);
        assertFalse(registry.isExcluded(address(token), treasury));
        assertEq(registry.excludedCount(address(token)), 0);
    }

    // ========================================================================
    // Layer 2: report, commit, median
    // ========================================================================

    function test_Commit_MedianOfFreshReports() public {
        _exclude(treasury);
        _exclude(vesting); // circulating = 600,000
        // Reports cluster within the 2% tolerance; median is the middle value,
        // 0.92, which the EFF rounding snaps to the nearest 5% tier, 0.90.
        _reportAll(0.91e18, 0.92e18, 0.93e18);
        oracle.commit(address(token));

        (uint256 factor,, bool frozen) = oracle.freeFloatFactor(address(token));
        assertEq(factor, 0.9e18, "median not committed at the rounded tier");
        assertFalse(frozen);

        // free-float = 600,000 * 0.90 = 540,000
        assertEq(oracle.getFreeFloatSupply(address(token)), 540_000);
    }

    function test_Commit_RevertsBelowQuorum() public {
        vm.prank(repA);
        oracle.report(address(token), 0.9e18);
        vm.expectRevert(abi.encodeWithSelector(SupplyOracle_NotEnoughFreshReports.selector, address(token), 1, 2));
        oracle.commit(address(token));
    }

    function test_Commit_IgnoresStaleReports() public {
        _reportAll(0.9e18, 0.9e18, 0.9e18);
        // Age every report past the freshness window.
        vm.warp(block.timestamp + oracle.reportStaleAfter() + 1);
        vm.expectRevert(abi.encodeWithSelector(SupplyOracle_NotEnoughFreshReports.selector, address(token), 0, 2));
        oracle.commit(address(token));
    }

    function test_Report_RejectsFactorAboveOne() public {
        vm.prank(repA);
        vm.expectRevert(abi.encodeWithSelector(SupplyOracle_FactorAboveOne.selector, WAD + 1));
        oracle.report(address(token), WAD + 1);
    }

    function test_Report_OnlyReporter() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(abi.encodeWithSelector(SupplyOracle_NotReporter.selector, makeAddr("rando")));
        oracle.report(address(token), 0.9e18);
    }

    // ========================================================================
    // Layer 2: divergence freeze (adversarial)
    // ========================================================================

    /// @notice When the reporter set genuinely splits (no quorum agrees within
    /// tolerance), the commit reverts and the constituent freezes at last-good.
    function test_DivergenceFreeze_NoQuorumKeepsLastGood() public {
        _exclude(treasury);
        _exclude(vesting);
        _reportAll(0.91e18, 0.92e18, 0.93e18);
        oracle.commit(address(token));
        // Median 0.92 rounds to the 0.90 tier, so free-float = 600,000 * 0.90.
        assertEq(oracle.getFreeFloatSupply(address(token)), 600_000 * 90 / 100);

        // All three reporters now disagree wildly: median 0.60, and neither
        // 0.30 nor 0.92 sits within the 2% band, so fewer than two agree.
        vm.warp(block.timestamp + 1 hours);
        _reportAll(0.3e18, 0.6e18, 0.92e18);
        // spread 0.62 over median 0.60 = 10334 bps, far past the 200 tolerance.
        vm.expectRevert(
            abi.encodeWithSelector(SupplyOracle_SourcesDiverged.selector, address(token), uint256(10_334), 200)
        );
        oracle.commit(address(token));

        // Last-good factor untouched: the freeze held (at the rounded 0.90 tier).
        (uint256 factor,,) = oracle.freeFloatFactor(address(token));
        assertEq(factor, 0.9e18);
    }

    /// @notice The median is robust to a single captured reporter: a 2-of-3
    /// honest majority within tolerance commits, the outlier is outvoted.
    function test_DivergenceFreeze_SingleOutlierOutvoted() public {
        _exclude(treasury);
        _exclude(vesting);
        // Two honest at ~0.90, one captured reporter high. Median = 0.90,
        // two reports within the 2% band, so quorum holds and the outlier
        // never moves the committed value.
        _reportAll(0.899e18, 0.9e18, 0.99e18);
        oracle.commit(address(token));
        (uint256 factor,,) = oracle.freeFloatFactor(address(token));
        assertEq(factor, 0.9e18);
    }

    // ========================================================================
    // Layer 3: rate-limit clamp, hard staleness, pause
    // ========================================================================

    /// @notice A large but agreed move is clamped per commit and converges
    /// over several commits, so a malicious spike cannot move the index at once.
    function test_RateLimit_ClampsAndConverges() public {
        _exclude(treasury);
        _exclude(vesting);
        _reportAll(0.9e18, 0.9e18, 0.9e18);
        oracle.commit(address(token));

        // Reporters now all agree on a 50% drop, far beyond the 10% step.
        uint256 step = oracle.maxFactorDeltaBps();
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(block.timestamp + 1 hours);
            _reportAll(0.45e18, 0.45e18, 0.45e18);
            (uint256 before,,) = oracle.freeFloatFactor(address(token));
            oracle.commit(address(token));
            (uint256 afterFactor,,) = oracle.freeFloatFactor(address(token));

            uint256 maxStep = before * step / 10_000;
            // Each commit moves by at most one clamped step.
            assertLe(before - afterFactor, maxStep + 1, "moved more than one step");
        }
        // After enough steps it has converged near the target, not overshot it.
        (uint256 finalFactor,,) = oracle.freeFloatFactor(address(token));
        assertGe(finalFactor, 0.45e18);
        assertLt(finalFactor, 0.6e18);
    }

    /// @notice The rate-limit must be per-time, not per-call. commit is
    /// permissionless, so without a cooldown an attacker could call it
    /// repeatedly in one block, each call reading the freshly-written factor
    /// and advancing another step, walking it to the median in a single block
    /// and erasing the human-reaction window the clamp is meant to preserve.
    function test_RateLimit_PerTimeNotPerCommit_BlocksSameBlockWalk() public {
        _exclude(treasury);
        _exclude(vesting);
        _reportAll(0.9e18, 0.9e18, 0.9e18);
        oracle.commit(address(token)); // initial commit, factor 0.90

        // Reporters agree on a large drop. This is the malicious-spike case the
        // rate-limit exists to slow down.
        vm.warp(block.timestamp + oracle.minCommitInterval());
        _reportAll(0.45e18, 0.45e18, 0.45e18);
        oracle.commit(address(token));
        (uint256 afterOne,,) = oracle.freeFloatFactor(address(token));
        assertEq(afterOne, 0.81e18, "first commit should move exactly one clamped step");

        // A second commit in the SAME block must revert. This is the regression
        // guard: previously it would have advanced another step off the just
        // written 0.81, and a loop could reach 0.45 within the block.
        vm.expectRevert(
            abi.encodeWithSelector(
                SupplyOracle_CommitTooSoon.selector, address(token), block.timestamp + oracle.minCommitInterval()
            )
        );
        oracle.commit(address(token));

        // The factor only advances once the cooldown has elapsed.
        vm.warp(block.timestamp + oracle.minCommitInterval());
        oracle.commit(address(token));
        (uint256 afterTwo,,) = oracle.freeFloatFactor(address(token));
        assertLt(afterTwo, afterOne, "second step should apply only after the cooldown");
        assertEq(afterTwo, afterOne - afterOne * oracle.maxFactorDeltaBps() / 10_000, "not a single clamped step");
    }

    function test_HardStaleness_ReadRevertsPastMaxCommitAge() public {
        _reportAll(0.9e18, 0.9e18, 0.9e18);
        oracle.commit(address(token));
        (, uint256 committedAt,) = oracle.freeFloatFactor(address(token));

        vm.warp(committedAt + oracle.maxCommitAge() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                SupplyOracle_CommitTooOld.selector, address(token), committedAt, oracle.maxCommitAge()
            )
        );
        oracle.getFreeFloatSupply(address(token));
    }

    function test_SoftStaleness_ServesLastGoodInsideCeiling() public {
        _reportAll(0.9e18, 0.9e18, 0.9e18);
        oracle.commit(address(token));

        // Past the report-fresh window but well inside maxCommitAge: frozen
        // flag is set for dashboards, but the read still serves last-good.
        vm.warp(block.timestamp + oracle.reportStaleAfter() + 1);
        (,, bool frozen) = oracle.freeFloatFactor(address(token));
        assertTrue(frozen);
        assertEq(oracle.getFreeFloatSupply(address(token)), 1_000_000 * 9 / 10);
    }

    function test_Read_RevertsBeforeInitialization() public {
        vm.expectRevert(abi.encodeWithSelector(SupplyOracle_NotInitialized.selector, address(token)));
        oracle.getFreeFloatSupply(address(token));
    }

    function test_GuardianPause_FailsReadsClosed() public {
        _reportAll(0.9e18, 0.9e18, 0.9e18);
        oracle.commit(address(token));

        vm.prank(guardian);
        oracle.pause();
        vm.expectRevert(SupplyOracle_Paused.selector);
        oracle.getFreeFloatSupply(address(token));

        // Commits also halt while paused.
        vm.expectRevert(SupplyOracle_Paused.selector);
        oracle.commit(address(token));

        oracle.unpause();
        assertEq(oracle.getFreeFloatSupply(address(token)), 1_000_000 * 9 / 10);
    }

    function test_GuardianPause_OnlyGuardian() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(abi.encodeWithSelector(SupplyOracle_NotGuardian.selector, makeAddr("rando")));
        oracle.pause();
    }

    // ========================================================================
    // Sanity invariant
    // ========================================================================

    /// @notice free-float can never exceed on-chain circulating, because the
    /// factor is capped at WAD. Holds for any agreed report and exclusion set.
    function testFuzz_FreeFloatNeverExceedsCirculating(uint256 factorSeed, bool excludeTreasury) public {
        uint256 factor = bound(factorSeed, 1, WAD);
        if (excludeTreasury) _exclude(treasury);

        _reportAll(factor, factor, factor);
        oracle.commit(address(token));

        uint256 circulating = registry.onChainCirculating(address(token));
        assertLe(oracle.getFreeFloatSupply(address(token)), circulating);
    }

    // ========================================================================
    // Float-factor rounding (CRSP EFF tiers)
    // ========================================================================

    /// @notice A float wiggle within the same tier does not move the committed
    /// factor, while a change that crosses a tier does. This is what suppresses
    /// needless re-weighting on small, noisy float changes.
    function test_FloatRounding_WiggleWithinTierIsNoOp() public {
        _exclude(treasury);
        _exclude(vesting);

        // 0.90 is tier-aligned (nearest 5%).
        _reportAll(0.9e18, 0.9e18, 0.9e18);
        oracle.commit(address(token));
        (uint256 f0,,) = oracle.freeFloatFactor(address(token));
        assertEq(f0, 0.9e18);

        // 0.91 rounds back to the 0.90 tier, so the committed factor does not move.
        vm.warp(block.timestamp + oracle.minCommitInterval());
        _reportAll(0.91e18, 0.91e18, 0.91e18);
        oracle.commit(address(token));
        (uint256 f1,,) = oracle.freeFloatFactor(address(token));
        assertEq(f1, 0.9e18, "in-tier wiggle moved the factor");

        // 0.93 crosses into the 0.95 tier, so the factor does move.
        vm.warp(block.timestamp + oracle.minCommitInterval());
        _reportAll(0.93e18, 0.93e18, 0.93e18);
        oracle.commit(address(token));
        (uint256 f2,,) = oracle.freeFloatFactor(address(token));
        assertEq(f2, 0.95e18, "tier-crossing change did not round to 0.95");
    }

    /// @notice The committed factor is always tier-aligned at steady state, and
    /// a nonzero factor never rounds to zero.
    function testFuzz_FloatRounding_StaysTierAlignedAndNonzero(uint256 factorSeed) public {
        uint256 factor = bound(factorSeed, 1, WAD);
        _reportAll(factor, factor, factor);
        // The first commit has no prior value, so the clamp does not apply and
        // the committed factor is exactly the rounded target.
        oracle.commit(address(token));

        (uint256 committedFactor,,) = oracle.freeFloatFactor(address(token));
        assertGt(committedFactor, 0, "nonzero factor rounded to zero");
        assertLe(committedFactor, WAD);
        // Aligned to one of the three tiers.
        uint256 tier = committedFactor >= 1e17 ? 5e16 : (committedFactor >= 1e16 ? 1e16 : 1e15);
        assertEq(committedFactor % tier, 0, "committed factor not tier-aligned");
    }
}
