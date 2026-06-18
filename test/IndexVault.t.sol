// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import { IndexVault } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import {
    IndexVault_NotKeeper,
    IndexVault_SettleIntervalNotPassed,
    IndexVault_RequestBlockDelayNotPassed,
    IndexVault_InsufficientSettlementLiquidity,
    IndexVault_RequestNotSettled,
    IndexVault_NotAuthorized,
    IndexVault_InvalidBufferBand,
    IndexVault_AssetNotRegistered,
    IndexVault_DuplicateConstituent
} from "src/IndexVault.sol";
import { AssetRegistry_StalePrice } from "src/AssetRegistry.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";

contract IndexVaultTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal weth;

    MockAggregator internal usdcFeed;
    MockAggregator internal wbtcFeed;
    MockAggregator internal wethFeed;

    AssetRegistry internal registry;
    IndexVault internal vault;

    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint48 internal constant HEARTBEAT = 1 days;

    function setUp() public {
        // Anchor time away from zero so heartbeat math never underflows.
        vm.warp(30 days);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        usdcFeed = new MockAggregator(8, 1e8); // $1.00
        wbtcFeed = new MockAggregator(8, 100_000e8); // $100k
        wethFeed = new MockAggregator(8, 5_000e8); // $5k

        registry = new AssetRegistry(address(this));
        registry.setUsdcFeed(address(usdc), address(usdcFeed), HEARTBEAT);
        registry.registerAsset(address(wbtc), address(wbtcFeed), HEARTBEAT);
        registry.registerAsset(address(weth), address(wethFeed), HEARTBEAT);

        vault = new IndexVault(IERC20(address(usdc)), registry, keeper, address(this));

        // Curate this index's constituents (a subset of the catalog).
        address[] memory constituents = new address[](2);
        constituents[0] = address(wbtc);
        constituents[1] = address(weth);
        vault.setConstituents(constituents);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Simulates a deployed basket: 1 WBTC ($100k) + 20 WETH ($100k)
    /// held by the vault, as the rebalancer would leave it.
    function _seedBasket() internal {
        wbtc.mint(address(vault), 1e8);
        weth.mint(address(vault), 20e18);
    }

    /// @dev Advances past the settle cadence floor and the one-block delay.
    function _advanceForSettle() internal {
        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 1);
    }

    function _settle() internal {
        _advanceForSettle();
        vm.prank(keeper);
        vault.settle();
    }

    // ========================================================================
    // NAV
    // ========================================================================

    function test_Metadata() public view {
        assertEq(vault.decimals(), 18);
        assertEq(vault.asset(), address(usdc));
    }

    function test_TotalAssets_PricesBasketAtOracle() public {
        assertEq(vault.totalAssets(), 0);
        _seedBasket();
        // $100k WBTC + $100k WETH at a $1.00 USDC price = 200_000e6 USDC units.
        assertEq(vault.totalAssets(), 200_000e6);

        usdc.mint(address(vault), 10_000e6);
        assertEq(vault.totalAssets(), 210_000e6);
    }

    function test_TotalAssets_TracksPriceMoves() public {
        _seedBasket();
        wbtcFeed.setAnswer(120_000e8);
        assertEq(vault.totalAssets(), 220_000e6);
    }

    function test_TotalAssets_RevertsOnStaleFeed() public {
        _seedBasket();
        vm.warp(block.timestamp + HEARTBEAT + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetRegistry_StalePrice.selector, address(usdcFeed), block.timestamp - HEARTBEAT - 1, HEARTBEAT
            )
        );
        vault.totalAssets();
    }

    // ========================================================================
    // Synchronous lane
    // ========================================================================

    function test_SyncDeposit_MintsAtNav() public {
        _seedBasket();
        uint256 assets = 10_000e6;
        uint256 expectedShares = vault.previewDeposit(assets);

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice);

        assertEq(shares, expectedShares);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), 210_000e6);
        // Round trip within rounding dust.
        assertApproxEqAbs(vault.convertToAssets(shares), assets, 2);
    }

    function test_SyncDeposit_RevertsBeyondBufferCapacity() public {
        _seedBasket();
        // Capacity: (800 * 200_000e6) / (10_000 - 800) ~= 17_391e6.
        uint256 capacity = vault.maxDeposit(alice);
        assertApproxEqAbs(capacity, 17_391_304_347, 1e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, capacity + 1, capacity)
        );
        vault.deposit(capacity + 1, alice);
    }

    function test_SyncDeposit_DisabledOnEmptyVault() public view {
        // With no basket, the vault is 100% idle by construction, so the
        // buffer band routes all deposits through the async lane.
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_SyncWithdraw_WithinBuffer() public {
        _seedBasket();
        vm.prank(alice);
        uint256 shares = vault.deposit(10_000e6, alice);

        uint256 capacity = vault.syncWithdrawCapacity();
        assertGt(capacity, 0);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(capacity / 2, alice, alice);
        assertEq(usdc.balanceOf(alice) - balBefore, capacity / 2);
        assertLt(vault.balanceOf(alice), shares);
    }

    function test_SyncWithdraw_RevertsBeyondBufferCapacity() public {
        _seedBasket();
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        uint256 maxAssets = vault.maxWithdraw(alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, maxAssets + 1, maxAssets)
        );
        vault.withdraw(maxAssets + 1, alice, alice);
    }

    // ========================================================================
    // Async deposit lifecycle
    // ========================================================================

    function test_RequestDeposit_MovesAssetsToSilo() public {
        uint256 epoch = vault.currentEpoch();

        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(50_000e6, alice, alice);

        assertEq(requestId, epoch);
        assertEq(usdc.balanceOf(address(vault.SILO())), 50_000e6);
        assertEq(vault.pendingDepositRequest(requestId, alice), 50_000e6);
        assertEq(vault.claimableDepositRequest(requestId, alice), 0);
        // Pending deposits must not contaminate NAV.
        assertEq(vault.totalAssets(), 0);
    }

    function test_RequestDeposit_TopUpSameEpoch() public {
        vm.startPrank(alice);
        uint256 id1 = vault.requestDeposit(10_000e6, alice, alice);
        uint256 id2 = vault.requestDeposit(5_000e6, alice, alice);
        vm.stopPrank();

        assertEq(id1, id2);
        assertEq(vault.pendingDepositRequest(id1, alice), 15_000e6);
    }

    function test_AsyncDepositLifecycle_SettleTimePricing() public {
        _seedBasket();
        vm.prank(alice);
        uint256 requestId = vault.requestDeposit(50_000e6, alice, alice);

        // Basket appreciates 10% before settlement; shares must be priced at
        // the settle-time NAV, not the request-time NAV.
        wbtcFeed.setAnswer(110_000e8);
        wethFeed.setAnswer(5_500e8);

        _settle();

        uint256 claimable = vault.claimableDepositRequest(requestId, alice);
        assertEq(claimable, 50_000e6);
        assertEq(vault.pendingDepositRequest(requestId, alice), 0);

        vm.prank(alice);
        uint256 shares = vault.deposit(50_000e6, alice, alice);

        assertEq(vault.balanceOf(alice), shares);
        // 50k into a 220k vault: the claim is worth its deposit at settle NAV.
        assertApproxEqAbs(vault.convertToAssets(shares), 50_000e6, 2);
        // Settlement pulled the pending USDC into the buffer.
        assertEq(usdc.balanceOf(address(vault)), 50_000e6);
    }

    function test_ClaimDeposit_RevertsBeforeSettle() public {
        vm.prank(alice);
        vault.requestDeposit(10_000e6, alice, alice);

        vm.prank(alice);
        vm.expectRevert(IndexVault_RequestNotSettled.selector);
        vault.deposit(10_000e6, alice, alice);
    }

    function test_RequestDeposit_AutoClaimsSettledRequest() public {
        _seedBasket();
        vm.prank(alice);
        vault.requestDeposit(10_000e6, alice, alice);
        _settle();

        assertEq(vault.balanceOf(alice), 0);
        vm.prank(alice);
        vault.requestDeposit(5_000e6, alice, alice);

        // The settled request was claimed to alice before the new one filed.
        assertGt(vault.balanceOf(alice), 0);
        assertEq(vault.pendingDepositRequest(vault.currentEpoch(), alice), 5_000e6);
    }

    // ========================================================================
    // Async redeem lifecycle
    // ========================================================================

    /// @dev Funds alice with shares and the vault with a 50k USDC buffer.
    function _setUpAliceShares() internal returns (uint256 shares) {
        _seedBasket();
        vm.prank(alice);
        vault.requestDeposit(50_000e6, alice, alice);
        _settle();
        vm.prank(alice);
        shares = vault.deposit(50_000e6, alice, alice);
    }

    function test_AsyncRedeemLifecycle_SettleTimePricing() public {
        uint256 shares = _setUpAliceShares();

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        // Shares escrowed in the silo, still part of supply until settlement.
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault.SILO())), shares);
        assertEq(vault.pendingRedeemRequest(requestId, alice), shares);

        // Basket drops 10% before settlement; payout must reflect settle NAV.
        wbtcFeed.setAnswer(90_000e8);
        wethFeed.setAnswer(4_500e8);
        uint256 supplyBefore = vault.totalSupply();
        _advanceForSettle();
        uint256 expectedAssets = (shares * (vault.totalAssets() + 1)) / (supplyBefore + 1e12);

        vm.prank(keeper);
        vault.settle();

        assertEq(vault.claimableRedeemRequest(requestId, alice), shares);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertEq(assets, expectedAssets);
        assertEq(usdc.balanceOf(alice) - balBefore, expectedAssets);
        // Escrowed shares were burned at settlement.
        assertEq(vault.totalSupply(), supplyBefore - shares);
    }

    function test_Settle_RevertsWhenBufferCannotCoverRedemptions() public {
        uint256 shares = _setUpAliceShares();

        // Queue a full redemption, then double WBTC so the claim's settle-time
        // value outgrows the 50k idle buffer.
        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        wbtcFeed.setAnswer(200_000e8);

        _advanceForSettle();
        uint256 required = _convertToAssetsRaw(shares);
        uint256 available = usdc.balanceOf(address(vault));
        assertGt(required, available);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IndexVault_InsufficientSettlementLiquidity.selector, required, available)
        );
        vault.settle();
    }

    /// @dev Mirrors the vault's settlement conversion for assertion building.
    function _convertToAssetsRaw(uint256 shares) internal view returns (uint256) {
        return (shares * (vault.totalAssets() + 1)) / (vault.totalSupply() + 1e12);
    }

    // ========================================================================
    // Settlement guards
    // ========================================================================

    function test_Settle_OnlyKeeperBeforeBackstop() public {
        _advanceForSettle();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IndexVault_NotKeeper.selector, alice));
        vault.settle();
    }

    function test_Settle_PermissionlessAfterMaxDelay() public {
        vm.warp(block.timestamp + vault.maxSettleDelay() + 1);
        vm.roll(block.number + 1);
        // Keep feeds fresh; the warp exceeds their heartbeat.
        usdcFeed.setAnswer(1e8);
        wbtcFeed.setAnswer(100_000e8);
        wethFeed.setAnswer(5_000e8);
        vm.prank(alice);
        vault.settle();
        assertEq(vault.currentEpoch(), 2);
    }

    function test_Settle_RevertsBeforeMinInterval() public {
        _settle();
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vm.expectRevert(IndexVault_SettleIntervalNotPassed.selector);
        vault.settle();
    }

    function test_Settle_RevertsSameBlockAsRequest() public {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        vault.requestDeposit(10_000e6, alice, alice);

        vm.prank(keeper);
        vm.expectRevert(IndexVault_RequestBlockDelayNotPassed.selector);
        vault.settle();
    }

    function test_Settle_EmptyEpochAdvances() public {
        _settle();
        assertEq(vault.currentEpoch(), 2);
        _settle();
        assertEq(vault.currentEpoch(), 3);
    }

    /// @notice A balanced epoch (large deposit and large redemption together)
    /// settles by netting: the deposit inflow funds the redemption outflow, even
    /// though the prior idle buffer alone could not cover it. Regression for the
    /// settle-ordering deadlock.
    function test_Settle_NetsDepositsAgainstRedemptions() public {
        // Establish supply: alice deposits $300k async and claims.
        vm.prank(alice);
        vault.requestDeposit(300_000e6, alice, alice);
        _settle();
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(300_000e6, alice, alice);

        // Simulate a rebalance having deployed ~$290k of idle into the basket,
        // leaving only $10k idle. NAV is unchanged at $300k, so NAV per share
        // holds, but the buffer is now small relative to share value.
        deal(address(usdc), address(vault), 10_000e6);
        wbtc.mint(address(vault), 2.9e8); // +$290k basket (WBTC at $100k)
        assertEq(vault.totalAssets(), 300_000e6);

        // Balanced epoch: bob deposits $100k, alice redeems ~30% (~$90k). The
        // $10k buffer cannot cover the redemption, but the deposit inflow can.
        uint256 redeemShares = aliceShares * 30 / 100;
        vm.prank(bob);
        vault.requestDeposit(100_000e6, bob, bob);
        vm.prank(alice);
        vault.requestRedeem(redeemShares, alice, alice);

        // Pre-fix this reverted on the liquidity check; now it settles.
        _settle();
        assertEq(vault.currentEpoch(), 3);

        // Both sides claim.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = vault.redeem(redeemShares, alice, alice);
        assertApproxEqRel(paid, 90_000e6, 0.01e18);
        assertEq(usdc.balanceOf(alice) - aliceBefore, paid);

        vm.prank(bob);
        assertGt(vault.deposit(100_000e6, bob, bob), 0);
    }

    function test_Settle_RevertsOnStaleFeed() public {
        _seedBasket();
        vm.prank(alice);
        vault.requestDeposit(10_000e6, alice, alice);

        vm.warp(block.timestamp + HEARTBEAT + 1);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vm.expectRevert();
        vault.settle();
    }

    // ========================================================================
    // Operator model
    // ========================================================================

    function test_Operator_CanRequestForOwner() public {
        vm.prank(alice);
        vault.setOperator(bob, true);
        assertTrue(vault.isOperator(alice, bob));

        vm.prank(bob);
        vault.requestDeposit(10_000e6, alice, alice);
        assertEq(vault.pendingDepositRequest(vault.currentEpoch(), alice), 10_000e6);
    }

    function test_NonOperator_CannotRequestForOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IndexVault_NotAuthorized.selector, alice, bob));
        vault.requestDeposit(10_000e6, alice, alice);
    }

    function test_NonOperator_CannotClaimForController() public {
        _seedBasket();
        vm.prank(alice);
        vault.requestDeposit(10_000e6, alice, alice);
        _settle();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IndexVault_NotAuthorized.selector, alice, bob));
        vault.deposit(10_000e6, bob, alice);
    }

    // ========================================================================
    // Admin
    // ========================================================================

    function test_SetBufferBand_ValidatesOrdering() public {
        vm.expectRevert(IndexVault_InvalidBufferBand.selector);
        vault.setBufferBand(600, 500, 800);

        vault.setBufferBand(200, 400, 700);
        assertEq(vault.bufferLowBps(), 200);
        assertEq(vault.bufferHighBps(), 700);
    }

    // ========================================================================
    // Invariant-style fuzz
    // ========================================================================

    /// @notice A same-price deposit and full redemption round trip must never
    /// return more assets than were put in.
    function testFuzz_SyncRoundTrip_NoFreeValue(uint256 assets) public {
        _seedBasket();
        assets = bound(assets, 1e6, vault.maxDeposit(alice));

        vm.startPrank(alice);
        uint256 shares = vault.deposit(assets, alice);
        uint256 redeemable = vault.maxRedeem(alice);
        uint256 toRedeem = shares < redeemable ? shares : redeemable;
        uint256 assetsOut = vault.redeem(toRedeem, alice, alice);
        vm.stopPrank();

        assertLe(assetsOut, assets);
    }

    /// @notice Async round trip at constant prices: claimed redemption value
    /// must not exceed the deposited amount.
    function testFuzz_AsyncRoundTrip_NoFreeValue(uint256 assets) public {
        _seedBasket();
        assets = bound(assets, 1e6, 500_000e6);

        vm.prank(alice);
        vault.requestDeposit(assets, alice, alice);
        _settle();
        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice, alice);

        vm.prank(alice);
        vault.requestRedeem(shares, alice, alice);
        _settle();

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertLe(usdc.balanceOf(alice) - balBefore, assets);
    }

    // ========================================================================
    // Constituents (curated membership) and multi-index
    // ========================================================================

    function _constituentArray(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function test_GetConstituents_ReflectsCuratedSet() public view {
        address[] memory cons = vault.getConstituents();
        assertEq(cons.length, 2);
        assertEq(cons[0], address(wbtc));
        assertEq(cons[1], address(weth));
        assertEq(vault.constituentCount(), 2);
        assertTrue(vault.isConstituent(address(wbtc)));
        assertFalse(vault.isConstituent(address(usdc)));
    }

    function test_SetConstituents_RevertsOnUnregisteredAsset() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        vm.expectRevert(abi.encodeWithSelector(IndexVault_AssetNotRegistered.selector, address(stray)));
        vault.setConstituents(_constituentArray(address(wbtc), address(stray)));
    }

    function test_SetConstituents_RevertsOnDuplicate() public {
        vm.expectRevert(abi.encodeWithSelector(IndexVault_DuplicateConstituent.selector, address(wbtc)));
        vault.setConstituents(_constituentArray(address(wbtc), address(wbtc)));
    }

    function test_SetConstituents_ReplacesPreviousSet() public {
        // Re-curate to WETH only; WBTC should drop out of the set entirely.
        address[] memory one = new address[](1);
        one[0] = address(weth);
        vault.setConstituents(one);

        assertEq(vault.constituentCount(), 1);
        assertTrue(vault.isConstituent(address(weth)));
        assertFalse(vault.isConstituent(address(wbtc)));

        // A WBTC balance is now invisible to NAV; only WETH is valued.
        _seedBasket(); // mints 1 WBTC + 20 WETH
        assertEq(vault.totalAssets(), 100_000e6); // only the $100k WETH counts
    }

    function test_GetHoldings_ValuesAndWeightsSumToBasket() public {
        _seedBasket(); // 1 WBTC ($100k) + 20 WETH ($100k), no idle
        (IndexVault.Holding[] memory holdings, uint256 idleUsd, uint256 totalUsd) = vault.getHoldings();

        assertEq(holdings.length, 2);
        assertEq(idleUsd, 0);
        assertEq(totalUsd, 200_000e8); // $200k in 8-decimal USD
        assertEq(holdings[0].token, address(wbtc));
        assertEq(holdings[0].valueUsd, 100_000e8);
        assertEq(holdings[1].valueUsd, 100_000e8);
        // Equal value, so 5000 bps each; weights sum to 1e4.
        assertEq(holdings[0].weightBps, 5000);
        assertEq(holdings[1].weightBps, 5000);
        assertEq(holdings[0].weightBps + holdings[1].weightBps, 10_000);
    }

    function test_GetHoldings_AccountsForIdleInWeights() public {
        _seedBasket(); // $200k basket
        usdc.mint(address(vault), 200_000e6); // add $200k idle

        (IndexVault.Holding[] memory holdings, uint256 idleUsd, uint256 totalUsd) = vault.getHoldings();
        assertEq(idleUsd, 200_000e8);
        assertEq(totalUsd, 400_000e8);
        // Each constituent is now 25% of NAV; idle is the other 50%.
        assertEq(holdings[0].weightBps, 2500);
        assertEq(holdings[1].weightBps, 2500);
    }

    /// @notice Two index vaults share one registry but curate different sets
    /// and keep fully independent NAV. This is the multi-index property.
    function test_MultiIndex_TwoVaultsShareRegistryIndependently() public {
        // Second index on the same catalog, WETH-only.
        IndexVault vault2 = new IndexVault(IERC20(address(usdc)), registry, keeper, address(this));
        address[] memory one = new address[](1);
        one[0] = address(weth);
        vault2.setConstituents(one);

        // Fund each vault's basket differently.
        _seedBasket(); // vault: 1 WBTC + 20 WETH = $200k
        weth.mint(address(vault2), 10e18); // vault2: 10 WETH = $50k

        assertEq(vault.totalAssets(), 200_000e6);
        assertEq(vault2.totalAssets(), 50_000e6);

        // Their constituent sets are independent.
        assertEq(vault.constituentCount(), 2);
        assertEq(vault2.constituentCount(), 1);
        assertTrue(vault.isConstituent(address(wbtc)));
        assertFalse(vault2.isConstituent(address(wbtc)));
    }
}
