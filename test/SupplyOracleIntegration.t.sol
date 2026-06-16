// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { ComponentRegistry } from "src/ComponentRegistry.sol";
import { ExcludedAddressRegistry } from "src/oracle/ExcludedAddressRegistry.sol";
import { SupplyOracle } from "src/oracle/SupplyOracle.sol";
import { MarketCapMethodology } from "src/methodology/MarketCapMethodology.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";

/// @notice Proves the ISupplyOracle seam: the real layered SupplyOracle drives
/// MarketCapMethodology end to end, with no mock supply source in the path.
contract SupplyOracleIntegrationTest is Test {
    uint256 internal constant WAD = 1e18;
    uint48 internal constant HEARTBEAT = 1 days;
    uint256 internal constant DELAY = 2 days;

    ComponentRegistry internal components;
    ExcludedAddressRegistry internal excluded;
    SupplyOracle internal oracle;
    MarketCapMethodology internal methodology;

    MockERC20 internal wbtc;
    MockERC20 internal weth;
    MockERC20 internal tailA;
    MockERC20 internal tailB;

    MockAggregator[4] internal feeds;

    address[] internal tokens;
    address internal guardian = makeAddr("guardian");
    address internal repA = makeAddr("repA");
    address internal repB = makeAddr("repB");

    function setUp() public {
        vm.warp(60 days);

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        tailA = new MockERC20("Tail A", "TLA", 18);
        tailB = new MockERC20("Tail B", "TLB", 18);

        // Total supplies (native decimals). All circulating, free-float = 1.0
        // unless an exclusion or factor below 1 is applied.
        wbtc.mint(makeAddr("btcHolders"), 20_000_000e8); // 20M BTC
        weth.mint(makeAddr("ethHolders"), 120_000_000e18); // 120M ETH
        // Split tailA so a vesting tranche can be excluded without zeroing it.
        tailA.mint(makeAddr("tlaHolders"), 500_000_000e18);
        tailA.mint(makeAddr("tlaVesting"), 500_000_000e18);
        tailB.mint(makeAddr("tlbHolders"), 1_000_000_000e18); // 1B

        feeds[0] = new MockAggregator(8, 100_000e8);
        feeds[1] = new MockAggregator(8, 5_000e8);
        feeds[2] = new MockAggregator(8, 2e8);
        feeds[3] = new MockAggregator(8, 2e8);

        components = new ComponentRegistry(address(this));
        components.registerComponent(address(wbtc), address(feeds[0]), HEARTBEAT);
        components.registerComponent(address(weth), address(feeds[1]), HEARTBEAT);
        components.registerComponent(address(tailA), address(feeds[2]), HEARTBEAT);
        components.registerComponent(address(tailB), address(feeds[3]), HEARTBEAT);

        excluded = new ExcludedAddressRegistry(address(this), DELAY);
        oracle = new SupplyOracle(excluded, guardian, address(this));
        oracle.addReporter(repA);
        oracle.addReporter(repB);

        methodology = new MarketCapMethodology(components, ISupplyOracle(address(oracle)), address(this));

        tokens.push(address(wbtc));
        tokens.push(address(weth));
        tokens.push(address(tailA));
        tokens.push(address(tailB));

        // Seed every constituent's free-float factor at 1.0 and commit.
        _reportAndCommitAll(WAD);
    }

    /// @dev Re-stamps every price feed to now, undoing staleness from a warp.
    function _refreshFeeds() internal {
        feeds[0].setAnswer(100_000e8);
        feeds[1].setAnswer(5_000e8);
        feeds[2].setAnswer(2e8);
        feeds[3].setAnswer(2e8);
    }

    function _reportAndCommitAll(uint256 factor) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            vm.prank(repA);
            oracle.report(tokens[i], factor);
            vm.prank(repB);
            oracle.report(tokens[i], factor);
            oracle.commit(tokens[i]);
        }
    }

    function test_WeightsComputeThroughRealOracle() public view {
        uint256[] memory w = methodology.getWeights(tokens);

        // BTC ($2T) and ETH ($600B) dominate and pin at the 25% cap; the two
        // tails ($2B each) split the remainder.
        assertEq(w[0], 0.25e18, "BTC not at cap");
        assertEq(w[1], 0.25e18, "ETH not at cap");
        uint256 sum;
        for (uint256 i = 0; i < 4; i++) {
            sum += w[i];
        }
        assertEq(sum, WAD);
    }

    /// @notice A capped constituent's weight is independent of its
    /// supply-oracle value. Move BTC's free-float factor through the full
    /// committed range and its weight never leaves the cap.
    function test_CapNeutralizesSupplyOracleOnLargeConstituent() public {
        uint256[] memory before = methodology.getWeights(tokens);

        // Drive BTC's factor down 10% (clamped one step) repeatedly.
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(repA);
            oracle.report(address(wbtc), 0.5e18);
            vm.prank(repB);
            oracle.report(address(wbtc), 0.5e18);
            oracle.commit(address(wbtc));
        }

        uint256[] memory afterW = methodology.getWeights(tokens);
        assertEq(before[0], afterW[0], "capped BTC weight moved with supply");
        assertEq(afterW[0], 0.25e18);
    }

    /// @notice A free-float exclusion on a tail name (a vesting contract found
    /// and timelocked in) flows through to a lower weight for that name.
    function test_ExclusionLowersTailWeight() public {
        // Raise the cap so the 4-name index is not saturated (at 25% every
        // name pins to the cap and no supply change can move a weight); at 40%
        // the tails sit below the cap and supply flows through.
        methodology.setWeightParams(0.4e18, 1e14);
        uint256[] memory before = methodology.getWeights(tokens);

        // Exclude tailA's vesting tranche (half its supply) once identified.
        address vestingTLA = makeAddr("tlaVesting");
        excluded.proposeChange(address(tailA), vestingTLA, true);
        vm.warp(block.timestamp + DELAY);
        excluded.executeChange(address(tailA), vestingTLA, true);
        _refreshFeeds(); // the timelock warp outran the 1-day price heartbeat

        // tailA's circulating supply halves, so its market cap and weight fall
        // while the name stays in the index.
        uint256[] memory afterW = methodology.getWeights(tokens);
        assertLt(afterW[2], before[2], "tailA weight did not fall");
        assertGt(afterW[2], 0, "tailA wrongly dropped");
    }

    /// @notice A guardian pause on the supply oracle halts weight computation,
    /// which is what stops a rebalance under suspicious supply data.
    function test_GuardianPauseHaltsMethodology() public {
        vm.prank(guardian);
        oracle.pause();
        vm.expectRevert();
        methodology.getWeights(tokens);
    }
}
