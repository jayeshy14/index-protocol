// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IndexVault } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import { MarketCapMethodology } from "src/methodology/MarketCapMethodology.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { GPv2Order } from "src/libraries/GPv2Order.sol";
import {
    Rebalancer,
    Rebalancer_NotKeeper,
    Rebalancer_IntervalNotElapsed,
    Rebalancer_NoEpoch,
    Rebalancer_NotInEpoch,
    Rebalancer_ExceedsDelta,
    Rebalancer_BelowMinOut,
    Rebalancer_WrongReceiver,
    Rebalancer_NotRebalanceLeg
} from "src/rebalancer/Rebalancer.sol";
import { MockGPv2Settlement } from "test/mocks/MockGPv2Settlement.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";
import { MockSupplyOracle } from "test/mocks/MockSupplyOracle.sol";

/// @notice Slice 1 tests for the Rebalancer brain: epoch snapshot, deltas, and
/// both-leg order derivation and validation. No settlement wiring yet.
contract RebalancerTest is Test {
    uint256 internal constant WAD = 1e18;
    uint48 internal constant HEARTBEAT = 1 days;
    uint256 internal constant SLIPPAGE_BPS = 100; // 1%
    uint256 internal constant MIN_INTERVAL = 1 hours;
    uint256 internal constant CADENCE = 7 days;
    uint256 internal constant D_SMALL_BPS = 200;
    uint256 internal constant D_LARGE_BPS = 500;

    AssetRegistry internal registry;
    MockSupplyOracle internal supplyOracle;
    MarketCapMethodology internal methodology;
    IndexVault internal vault;
    Rebalancer internal rebalancer;
    MockGPv2Settlement internal settlement;

    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal weth;

    address internal keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(30 days);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        registry = new AssetRegistry(address(this));
        registry.setUsdcFeed(address(usdc), address(new MockAggregator(8, 1e8)), HEARTBEAT);
        registry.registerAsset(address(wbtc), address(new MockAggregator(8, 100_000e8)), HEARTBEAT);
        registry.registerAsset(address(weth), address(new MockAggregator(8, 5_000e8)), HEARTBEAT);

        // Equal market caps so target weights are 50/50.
        supplyOracle = new MockSupplyOracle();
        supplyOracle.setSupply(address(wbtc), 1_000_000); // $100B
        supplyOracle.setSupply(address(weth), 20_000_000); // $100B

        methodology = new MarketCapMethodology(registry, ISupplyOracle(address(supplyOracle)), address(this));
        // Lift the cap so a two-name index is feasible and weights are raw 50/50.
        methodology.setWeightParams(WAD, WAD, 1);

        vault = new IndexVault(IERC20(address(usdc)), registry, keeper, address(this));
        address[] memory constituents = new address[](2);
        constituents[0] = address(wbtc);
        constituents[1] = address(weth);
        vault.setConstituents(constituents);

        settlement = new MockGPv2Settlement();
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

        // Off-target basket: WBTC $200k, WETH $100k. NAV $300k, target $150k each.
        wbtc.mint(address(vault), 2e8); // $200k
        weth.mint(address(vault), 20e18); // $100k
    }

    function _openEpoch() internal {
        vm.prank(keeper);
        rebalancer.openEpoch();
    }

    // ========================================================================
    // Epoch snapshot and deltas
    // ========================================================================

    function test_OpenEpoch_SnapshotsTargetsAtWeightTimesNav() public {
        _openEpoch();

        assertEq(rebalancer.epochId(), 1);
        assertEq(rebalancer.epochNavUsd(), 300_000e8);
        // 50/50 of $300k = $150k each (8-decimal USD).
        assertEq(rebalancer.targetUsd(address(wbtc)), 150_000e8);
        assertEq(rebalancer.targetUsd(address(weth)), 150_000e8);
    }

    function test_Deltas_OverAndUnderweight() public {
        _openEpoch();
        // WBTC is $200k vs $150k target = $50k overweight.
        assertEq(rebalancer.overweightUsd(address(wbtc)), 50_000e8);
        assertEq(rebalancer.underweightUsd(address(wbtc)), 0);
        // WETH is $100k vs $150k target = $50k underweight.
        assertEq(rebalancer.underweightUsd(address(weth)), 50_000e8);
        assertEq(rebalancer.overweightUsd(address(weth)), 0);
    }

    function test_OpenEpoch_EmergencyIsPermissionless() public {
        // The off-target basket drifts far past the large threshold, so an
        // emergency open is permissionless: a non-keeper can open it.
        assertGt(rebalancer.maxDriftBps(), D_LARGE_BPS);
        vm.prank(makeAddr("anyone"));
        rebalancer.openEpoch();
        assertEq(rebalancer.epochId(), 1);
    }

    function test_OpenEpoch_RespectsMinInterval() public {
        _openEpoch();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer_IntervalNotElapsed.selector, block.timestamp + MIN_INTERVAL));
        rebalancer.openEpoch();

        vm.warp(block.timestamp + MIN_INTERVAL);
        _openEpoch();
        assertEq(rebalancer.epochId(), 2);
    }

    // ========================================================================
    // Sell leg
    // ========================================================================

    function test_SellLeg_ValidWithinBudget() public {
        _openEpoch();
        // Sell 0.5 WBTC ($50k), exactly the overweight budget.
        GPv2Order.Data memory order =
            rebalancer.buildSellOrder(address(wbtc), 0.5e8, uint32(block.timestamp + 1 hours), bytes32("e1"));

        assertEq(order.buyToken, address(usdc));
        assertEq(order.buyAmount, 49_500e6); // $50k less 1% slippage
        rebalancer.validateOrder(order); // does not revert
    }

    function test_SellLeg_RevertsOnOvershoot() public {
        _openEpoch();
        // Sell 0.6 WBTC ($60k) exceeds the $50k overweight budget.
        GPv2Order.Data memory order =
            rebalancer.buildSellOrder(address(wbtc), 0.6e8, uint32(block.timestamp + 1 hours), bytes32("e1"));

        vm.expectRevert(abi.encodeWithSelector(Rebalancer_ExceedsDelta.selector, 60_000e8, 50_000e8));
        rebalancer.validateOrder(order);
    }

    function test_SellLeg_RevertsBelowMinOut() public {
        _openEpoch();
        GPv2Order.Data memory order =
            rebalancer.buildSellOrder(address(wbtc), 0.5e8, uint32(block.timestamp + 1 hours), bytes32("e1"));
        order.buyAmount = 49_500e6 - 1; // one under the oracle-anchored minimum

        vm.expectRevert(abi.encodeWithSelector(Rebalancer_BelowMinOut.selector, order.buyAmount, 49_500e6));
        rebalancer.validateOrder(order);
    }

    // ========================================================================
    // Buy leg
    // ========================================================================

    function test_BuyLeg_ValidWithinBudget() public {
        _openEpoch();
        // Spend $50k USDC buying WETH, exactly the underweight budget.
        GPv2Order.Data memory order =
            rebalancer.buildBuyOrder(address(weth), 50_000e6, uint32(block.timestamp + 1 hours), bytes32("e1"));

        assertEq(order.sellToken, address(usdc));
        assertEq(order.buyToken, address(weth));
        // $50k / $5k = 10 WETH, less 1% = 9.9 WETH.
        assertEq(order.buyAmount, 9.9e18);
        rebalancer.validateOrder(order);
    }

    function test_BuyLeg_RevertsOnOvershoot() public {
        _openEpoch();
        GPv2Order.Data memory order =
            rebalancer.buildBuyOrder(address(weth), 60_000e6, uint32(block.timestamp + 1 hours), bytes32("e1"));

        vm.expectRevert(abi.encodeWithSelector(Rebalancer_ExceedsDelta.selector, 60_000e8, 50_000e8));
        rebalancer.validateOrder(order);
    }

    // ========================================================================
    // Validation guards
    // ========================================================================

    function test_ValidateOrder_RevertsWithoutEpoch() public {
        GPv2Order.Data memory order =
            rebalancer.buildSellOrder(address(wbtc), 0.1e8, uint32(block.timestamp + 1 hours), bytes32("e1"));
        vm.expectRevert(Rebalancer_NoEpoch.selector);
        rebalancer.validateOrder(order);
    }

    function test_ValidateOrder_RevertsWrongReceiver() public {
        _openEpoch();
        GPv2Order.Data memory order =
            rebalancer.buildSellOrder(address(wbtc), 0.5e8, uint32(block.timestamp + 1 hours), bytes32("e1"));
        order.receiver = makeAddr("attacker");
        vm.expectRevert(abi.encodeWithSelector(Rebalancer_WrongReceiver.selector, order.receiver));
        rebalancer.validateOrder(order);
    }

    function test_ValidateOrder_RevertsNonRebalanceLeg() public {
        _openEpoch();
        // Neither side is USDC: not a routed rebalance leg.
        GPv2Order.Data memory order =
            rebalancer.buildSellOrder(address(wbtc), 0.5e8, uint32(block.timestamp + 1 hours), bytes32("e1"));
        order.buyToken = address(weth);
        vm.expectRevert(Rebalancer_NotRebalanceLeg.selector);
        rebalancer.validateOrder(order);
    }

    function test_ValidateOrder_RevertsUnknownConstituent() public {
        _openEpoch();
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        registry.registerAsset(address(stray), address(new MockAggregator(8, 1e8)), HEARTBEAT);
        GPv2Order.Data memory order =
            rebalancer.buildSellOrder(address(stray), 1e18, uint32(block.timestamp + 1 hours), bytes32("e1"));
        vm.expectRevert(abi.encodeWithSelector(Rebalancer_NotInEpoch.selector, address(stray)));
        rebalancer.validateOrder(order);
    }
}
