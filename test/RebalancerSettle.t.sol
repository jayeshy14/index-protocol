// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IndexVault, IndexVault_OrderDigestMismatch } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import { MarketCapMethodology } from "src/methodology/MarketCapMethodology.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { GPv2Order } from "src/libraries/GPv2Order.sol";
import { Rebalancer, Rebalancer_ExceedsDelta } from "src/rebalancer/Rebalancer.sol";
import { MockGPv2Settlement } from "test/mocks/MockGPv2Settlement.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";
import { MockSupplyOracle } from "test/mocks/MockSupplyOracle.sol";

/// @notice Slice 2 end-to-end: the vault is the CoW order owner and delegates
/// validation to the rebalancer, and a mock settle runs both legs so an
/// off-target basket moves toward target while NAV stays within the value-loss
/// guard. Proves the full delta to order to settle to closer-to-target loop.
contract RebalancerSettleTest is Test {
    uint256 internal constant WAD = 1e18;
    uint48 internal constant HEARTBEAT = 1 days;
    uint256 internal constant SLIPPAGE_BPS = 100; // 1%
    uint256 internal constant MIN_INTERVAL = 1 hours;
    uint256 internal constant VALUE_LOSS_GUARD_BPS = 50;

    AssetRegistry internal registry;
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

        MockSupplyOracle supplyOracle = new MockSupplyOracle();
        supplyOracle.setSupply(address(wbtc), 1_000_000);
        supplyOracle.setSupply(address(weth), 20_000_000);

        methodology = new MarketCapMethodology(registry, ISupplyOracle(address(supplyOracle)), address(this));
        methodology.setWeightParams(WAD, WAD, 1); // 50/50, no cap

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
            7 days,
            200,
            500
        );

        // Wire the vault as the CoW order owner and approve the relayer for both
        // constituents and USDC.
        vault.setRebalancer(address(rebalancer), address(settlement));
        vault.approveRelayer(address(wbtc));
        vault.approveRelayer(address(weth));
        vault.approveRelayer(address(usdc));

        // Off-target basket: WBTC $200k, WETH $100k. NAV $300k, target $150k each.
        wbtc.mint(address(vault), 2e8);
        weth.mint(address(vault), 20e18);

        // Fund the settlement to pay out both legs.
        usdc.mint(address(settlement), 1_000_000e6);
        weth.mint(address(settlement), 1000e18);
    }

    function _open() internal {
        vm.prank(keeper);
        rebalancer.openEpoch();
    }

    function test_E2E_RebalanceMovesBasketTowardTarget() public {
        uint256 navBefore = vault.totalAssets();
        assertEq(navBefore, 300_000e6);

        _open();

        // Sell leg: sell 0.5 WBTC ($50k overweight) to USDC.
        GPv2Order.Data memory sell =
            rebalancer.buildSellOrder(address(wbtc), 0.5e8, uint32(block.timestamp + 1 hours), bytes32("e1"));
        settlement.settle(sell, address(vault), 0.5e8);

        assertEq(wbtc.balanceOf(address(vault)), 1.5e8, "WBTC not sold to target");
        assertEq(usdc.balanceOf(address(vault)), 49_500e6, "USDC proceeds wrong");

        // Buy leg: spend the proceeds buying WETH ($50k underweight).
        GPv2Order.Data memory buy =
            rebalancer.buildBuyOrder(address(weth), 49_500e6, uint32(block.timestamp + 1 hours), bytes32("e1"));
        settlement.settle(buy, address(vault), 49_500e6);

        assertEq(usdc.balanceOf(address(vault)), 0, "USDC not deployed");
        assertEq(weth.balanceOf(address(vault)), 29.801e18, "WETH not bought");

        // Basket is now much closer to the 50/50 target: WBTC exactly at target,
        // WETH lifted from $100k toward $150k.
        (IndexVault.Holding[] memory holdings,,) = vault.getHoldings();
        assertEq(holdings[0].valueUsd, 150_000e8, "WBTC not at target");
        assertEq(holdings[1].valueUsd, 149_005e8, "WETH not lifted toward target");

        // NAV loss is only the worst-case slippage and is within the guard.
        uint256 navAfter = vault.totalAssets();
        uint256 loss = navBefore - navAfter;
        assertLe(loss * 10_000 / navBefore, VALUE_LOSS_GUARD_BPS, "value loss exceeded the guard");
    }

    function test_E2E_VaultValidatesAndRejectsThroughDelegation() public {
        _open();
        GPv2Order.Data memory order =
            rebalancer.buildSellOrder(address(wbtc), 0.5e8, uint32(block.timestamp + 1 hours), bytes32("e1"));
        bytes32 digest = rebalancer.orderDigest(order);

        // The vault returns the ERC-1271 magic value for a valid rebalance leg.
        assertEq(vault.isValidSignature(digest, abi.encode(order)), bytes4(0x1626ba7e));

        // An order overshooting the delta is rejected by the delegated rebalancer.
        GPv2Order.Data memory bad =
            rebalancer.buildSellOrder(address(wbtc), 0.6e8, uint32(block.timestamp + 1 hours), bytes32("e1"));
        bytes32 badDigest = rebalancer.orderDigest(bad);
        bytes memory badSig = abi.encode(bad);
        vm.expectRevert(abi.encodeWithSelector(Rebalancer_ExceedsDelta.selector, 60_000e8, 50_000e8));
        vault.isValidSignature(badDigest, badSig);
    }

    function test_E2E_VaultRejectsDigestOrderMismatch() public {
        _open();
        GPv2Order.Data memory a =
            rebalancer.buildSellOrder(address(wbtc), 0.5e8, uint32(block.timestamp + 1 hours), bytes32("e1"));
        GPv2Order.Data memory b =
            rebalancer.buildSellOrder(address(wbtc), 0.4e8, uint32(block.timestamp + 1 hours), bytes32("e1"));

        // Present A's digest with B's encoding: the vault rebinds and reverts.
        bytes32 aDigest = rebalancer.orderDigest(a);
        bytes32 bDigest = rebalancer.orderDigest(b);
        bytes memory bSig = abi.encode(b);
        vm.expectRevert(abi.encodeWithSelector(IndexVault_OrderDigestMismatch.selector, bDigest, aDigest));
        vault.isValidSignature(aDigest, bSig);
    }
}
