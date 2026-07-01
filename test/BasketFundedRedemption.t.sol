// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IndexVault } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import { MarketCapMethodology } from "src/methodology/MarketCapMethodology.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { GPv2Order } from "src/libraries/GPv2Order.sol";
import { Rebalancer, Rebalancer_NotKeeper } from "src/rebalancer/Rebalancer.sol";
import { MockGPv2Settlement } from "test/mocks/MockGPv2Settlement.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";
import { MockSupplyOracle } from "test/mocks/MockSupplyOracle.sol";

/// @notice Basket-funded redemptions: when a redemption exceeds the buffer, the
/// rebalancer holds back a USDC reserve and sells the basket down to raise it, so
/// settle can pay a large exit that the buffer alone could not cover (Section 3).
contract BasketFundedRedemptionTest is Test {
    uint256 internal constant WAD = 1e18;
    uint48 internal constant HEARTBEAT = 1 days;
    uint256 internal constant SLIPPAGE_BPS = 100;

    AssetRegistry internal registry;
    MarketCapMethodology internal methodology;
    IndexVault internal vault;
    Rebalancer internal rebalancer;
    MockGPv2Settlement internal settlement;

    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal weth;

    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");

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
            1 hours,
            7 days,
            200,
            500
        );
        vault.setRebalancer(address(rebalancer), address(settlement));
        vault.approveRelayer(address(wbtc));
        vault.approveRelayer(address(weth));
        vault.approveRelayer(address(usdc));

        // Settlement funded to pay out the sell legs.
        usdc.mint(address(settlement), 5_000_000e6);
    }

    /// @dev Balanced basket ($150k WBTC + $150k WETH), no idle, alice holds all
    /// shares. Deal bypasses the deposit machinery to set up the redemption case.
    function _seedBalancedWithHolder() internal {
        wbtc.mint(address(vault), 1.5e8);
        weth.mint(address(vault), 30e18);
        deal(address(vault), alice, 300_000e18, true); // adjust totalSupply too
    }

    /// @dev Sells (just under) a constituent's full overweight budget to USDC.
    function _sellOverweight(address token, uint256 price8, uint8 dec) internal {
        uint256 overUsd = rebalancer.overweightUsd(token);
        if (overUsd == 0) return;
        uint256 amount = (overUsd * (10 ** dec) / price8) * 9999 / 10_000;
        GPv2Order.Data memory sell =
            rebalancer.buildSellOrder(token, amount, uint32(block.timestamp + 1 hours), bytes32("fund"));
        settlement.settle(sell, address(vault), amount);
    }

    // ========================================================================
    // Trigger and reserve
    // ========================================================================

    function test_RedemptionFundingNeeded() public {
        _seedBalancedWithHolder();
        assertFalse(vault.redemptionFundingNeeded());

        vm.prank(alice);
        vault.requestRedeem(100_000e18, alice, alice);
        assertTrue(vault.redemptionFundingNeeded());

        // A buffer large enough to cover it flips the flag off.
        usdc.mint(address(vault), 200_000e6);
        assertFalse(vault.redemptionFundingNeeded());
    }

    function test_Funding_OpensEpochBelowDriftGate() public {
        _seedBalancedWithHolder();
        // Balanced basket: drift is zero, below the scheduled gate.
        assertEq(rebalancer.maxDriftBps(), 0);

        vm.prank(alice);
        vault.requestRedeem(100_000e18, alice, alice);
        vm.roll(block.number + 1);

        // A non-keeper cannot open the funding epoch below the emergency band.
        vm.expectRevert(abi.encodeWithSelector(Rebalancer_NotKeeper.selector, address(this)));
        rebalancer.openEpoch();

        // The keeper opens it despite zero drift, because funding is needed.
        vm.prank(keeper);
        rebalancer.openEpoch();
        assertEq(rebalancer.epochId(), 1);
    }

    function test_Funding_ReserveHeldBackInTargets() public {
        _seedBalancedWithHolder();
        vm.prank(alice);
        vault.requestRedeem(100_000e18, alice, alice);
        vm.roll(block.number + 1);

        vm.prank(keeper);
        rebalancer.openEpoch();

        // Targets no longer sum to full NAV: a USDC reserve is held back.
        uint256 sumTargets = rebalancer.targetUsd(address(wbtc)) + rebalancer.targetUsd(address(weth));
        assertLt(sumTargets, rebalancer.epochNavUsd(), "reserve not held back");
        // The basket is now overweight, so it can be sold to raise the reserve.
        assertGt(rebalancer.overweightUsd(address(wbtc)), 0);
        assertGt(rebalancer.overweightUsd(address(weth)), 0);
    }

    // ========================================================================
    // End to end: a large redemption is funded from the basket
    // ========================================================================

    function test_E2E_BasketFundsLargeRedemption() public {
        _seedBalancedWithHolder();

        // Alice exits half the vault, $150k, which the zero buffer cannot cover.
        vm.prank(alice);
        vault.requestRedeem(150_000e18, alice, alice);
        assertTrue(vault.redemptionFundingNeeded());
        assertEq(vault.idleAssets(), 0);
        vm.roll(block.number + 1);

        // Keeper opens the funding rebalance and the basket is sold to raise USDC.
        vm.prank(keeper);
        rebalancer.openEpoch();
        _sellOverweight(address(wbtc), 100_000e8, 8);
        _sellOverweight(address(weth), 5_000e8, 18);

        // The buffer now covers the redemption where it could not before.
        assertGt(vault.idleAssets(), 149_000e6, "basket did not raise enough USDC");

        // Settle pays the redemption from the raised buffer, then Alice claims.
        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vault.settle();

        vm.prank(alice);
        uint256 out = vault.redeem(150_000e18, alice, alice);
        assertGt(out, 148_000e6, "redemption underpaid");
        assertApproxEqAbs(out, 149_250e6, 1_000e6);
    }
}
