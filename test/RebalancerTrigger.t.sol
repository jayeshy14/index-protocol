// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IndexVault } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import { MarketCapMethodology } from "src/methodology/MarketCapMethodology.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import {
    Rebalancer,
    Rebalancer_NotKeeper,
    Rebalancer_IntervalNotElapsed,
    Rebalancer_CadenceNotElapsed,
    Rebalancer_BelowDriftThreshold
} from "src/rebalancer/Rebalancer.sol";
import { MockGPv2Settlement } from "test/mocks/MockGPv2Settlement.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";
import { MockSupplyOracle } from "test/mocks/MockSupplyOracle.sol";

/// @notice Slice 3 tests for the dual-threshold trigger policy, starting from a
/// balanced basket so drift can be dialled into the scheduled and emergency
/// bands deliberately.
contract RebalancerTriggerTest is Test {
    uint256 internal constant WAD = 1e18;
    uint48 internal constant HEARTBEAT = 1 days;
    uint256 internal constant SLIPPAGE_BPS = 100;
    uint256 internal constant MIN_INTERVAL = 1 hours;
    uint256 internal constant CADENCE = 7 days;
    uint256 internal constant D_SMALL_BPS = 200;
    uint256 internal constant D_LARGE_BPS = 500;

    AssetRegistry internal registry;
    MarketCapMethodology internal methodology;
    IndexVault internal vault;
    Rebalancer internal rebalancer;

    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal weth;

    MockAggregator internal usdcFeed;
    MockAggregator internal wbtcFeed;
    MockAggregator internal wethFeed;

    address internal keeper = makeAddr("keeper");
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        vm.warp(30 days);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        usdcFeed = new MockAggregator(8, 1e8);
        wbtcFeed = new MockAggregator(8, 100_000e8);
        wethFeed = new MockAggregator(8, 5_000e8);

        registry = new AssetRegistry(address(this));
        registry.setUsdcFeed(address(usdc), address(usdcFeed), HEARTBEAT);
        registry.registerAsset(address(wbtc), address(wbtcFeed), HEARTBEAT);
        registry.registerAsset(address(weth), address(wethFeed), HEARTBEAT);

        MockSupplyOracle supplyOracle = new MockSupplyOracle();
        supplyOracle.setSupply(address(wbtc), 1_000_000);
        supplyOracle.setSupply(address(weth), 20_000_000);

        methodology = new MarketCapMethodology(registry, ISupplyOracle(address(supplyOracle)), address(this));
        methodology.setWeightParams(WAD, WAD, 1); // 50/50

        vault = new IndexVault(IERC20(address(usdc)), registry, keeper, address(this));
        address[] memory constituents = new address[](2);
        constituents[0] = address(wbtc);
        constituents[1] = address(weth);
        vault.setConstituents(constituents);

        MockGPv2Settlement settlement = new MockGPv2Settlement();
        rebalancer = new Rebalancer(
            vault,
            methodology,
            registry,
            address(usdc),
            address(settlement),
            keeper,
            SLIPPAGE_BPS,
            MIN_INTERVAL,
            CADENCE,
            D_SMALL_BPS,
            D_LARGE_BPS
        );

        // Balanced basket: WBTC $150k, WETH $150k, target 50/50, drift 0.
        wbtc.mint(address(vault), 1.5e8);
        weth.mint(address(vault), 30e18);
    }

    // ========================================================================
    // Scheduled path
    // ========================================================================

    function test_Scheduled_RevertsBelowSmallDrift() public {
        // Balanced basket: drift is zero, below the small gate.
        assertEq(rebalancer.maxDriftBps(), 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer_BelowDriftThreshold.selector, 0, D_SMALL_BPS));
        rebalancer.openEpoch();
    }

    function test_Scheduled_OpensInSmallBand() public {
        // Push WBTC overweight into the scheduled band (between small and large).
        wbtc.mint(address(vault), 0.15e8); // WBTC -> $165k, NAV $315k
        uint256 drift = rebalancer.maxDriftBps();
        assertGe(drift, D_SMALL_BPS);
        assertLt(drift, D_LARGE_BPS);

        vm.prank(keeper);
        rebalancer.openEpoch();
        assertEq(rebalancer.epochId(), 1);
    }

    function test_Scheduled_NonKeeperRevertsInSmallBand() public {
        wbtc.mint(address(vault), 0.15e8);
        uint256 drift = rebalancer.maxDriftBps();
        assertLt(drift, D_LARGE_BPS); // not an emergency

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer_NotKeeper.selector, anyone));
        rebalancer.openEpoch();
    }

    function test_Scheduled_CadenceGatesReopen() public {
        wbtc.mint(address(vault), 0.15e8); // scheduled-band drift
        vm.prank(keeper);
        rebalancer.openEpoch();
        uint256 openedAt = block.timestamp;

        // Past the floor but inside the cadence: scheduled reopen is gated.
        vm.warp(openedAt + MIN_INTERVAL);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer_CadenceNotElapsed.selector, openedAt + CADENCE));
        rebalancer.openEpoch();

        // Once the cadence has elapsed, the keeper can open again. Refresh the
        // feeds, since the cadence warp outran their heartbeat.
        vm.warp(openedAt + CADENCE);
        usdcFeed.setAnswer(1e8);
        wbtcFeed.setAnswer(100_000e8);
        wethFeed.setAnswer(5_000e8);
        vm.prank(keeper);
        rebalancer.openEpoch();
        assertEq(rebalancer.epochId(), 2);
    }

    // ========================================================================
    // Emergency path
    // ========================================================================

    function test_Emergency_PermissionlessAtLargeDrift() public {
        wbtc.mint(address(vault), 0.6e8); // WBTC -> $210k, NAV $360k, drift > 500 bps
        assertGe(rebalancer.maxDriftBps(), D_LARGE_BPS);

        vm.prank(anyone);
        rebalancer.openEpoch();
        assertEq(rebalancer.epochId(), 1);
    }

    function test_Emergency_StillRespectsMinIntervalFloor() public {
        wbtc.mint(address(vault), 0.6e8);
        vm.prank(anyone);
        rebalancer.openEpoch();

        // Even an emergency cannot reopen within the anti-churn floor.
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer_IntervalNotElapsed.selector, block.timestamp + MIN_INTERVAL));
        rebalancer.openEpoch();
    }
}
