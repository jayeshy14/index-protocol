// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IndexVault } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import { MarketCapMethodology } from "src/methodology/MarketCapMethodology.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { Rebalancer } from "src/rebalancer/Rebalancer.sol";
import { MockGPv2Settlement } from "test/mocks/MockGPv2Settlement.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";
import { MockSupplyOracle } from "test/mocks/MockSupplyOracle.sol";

/// @notice Section 4 Slice 3: the rebalancer rebalances around a quarantined
/// constituent (it weights and trades over the fresh subset) instead of the
/// whole epoch halting when a single feed goes stale.
contract RebalancerQuarantineTest is Test {
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
        methodology.setWeightParams(WAD, WAD, 1); // no cap, so a single fresh name is feasible

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

        // Balanced basket: WBTC $150k, WETH $150k.
        wbtc.mint(address(vault), 1.5e8);
        weth.mint(address(vault), 30e18);
    }

    /// @dev Stale WBTC's feed, refreshing the others so only WBTC is quarantined.
    function _quarantineWbtc() internal {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        usdcFeed.setAnswer(1e8);
        wethFeed.setAnswer(5_000e8);
    }

    // ========================================================================
    // The trigger survives a stale feed
    // ========================================================================

    function test_Quarantine_MaxDriftDoesNotRevert() public {
        _quarantineWbtc();
        assertTrue(vault.isQuarantined(address(wbtc)));
        // Before the fix this reverted (getWeights priced the stale name); now it
        // computes drift over the fresh subset.
        uint256 drift = rebalancer.maxDriftBps();
        assertGt(drift, 0);
    }

    // ========================================================================
    // openEpoch rebalances around the quarantined name
    // ========================================================================

    function test_Quarantine_OpenEpochExcludesQuarantined() public {
        _quarantineWbtc();

        // WETH is the only fresh name, so the methodology targets it at 100% of
        // NAV; that large drift opens an emergency (permissionless) epoch.
        assertGe(rebalancer.maxDriftBps(), D_LARGE_BPS);
        vm.prank(anyone);
        rebalancer.openEpoch();
        assertEq(rebalancer.epochId(), 1);

        // The quarantined name is excluded from the epoch entirely: not targeted,
        // not orderable. The fresh name carries the whole target.
        assertFalse(rebalancer.inEpoch(address(wbtc)));
        assertEq(rebalancer.targetUsd(address(wbtc)), 0);

        assertTrue(rebalancer.inEpoch(address(weth)));
        assertEq(rebalancer.targetUsd(address(weth)), rebalancer.epochNavUsd());
        assertGt(rebalancer.targetUsd(address(weth)), 0);
    }

    function test_NoQuarantine_BothConstituentsInEpoch() public {
        // Sanity: with all feeds fresh, the normal path is unchanged. Push WBTC
        // overweight so there is drift to open on.
        wbtc.mint(address(vault), 0.6e8);
        vm.prank(anyone);
        rebalancer.openEpoch();

        assertTrue(rebalancer.inEpoch(address(wbtc)));
        assertTrue(rebalancer.inEpoch(address(weth)));
        assertGt(rebalancer.targetUsd(address(wbtc)), 0);
        assertGt(rebalancer.targetUsd(address(weth)), 0);
    }
}
