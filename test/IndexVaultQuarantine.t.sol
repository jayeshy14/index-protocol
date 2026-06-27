// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IndexVault } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import {
    IndexVault_QuarantineBlocksDeposit,
    IndexVault_QuarantineBlocksSettle,
    IndexVault_InvalidQuarantineParams
} from "src/IndexVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";

/// @notice Section 4 Slice 1: constituent quarantine and graceful redemption
/// degradation. A stale constituent feed degrades NAV (so buffer redemptions
/// survive) rather than halting the vault, while mints and settlement fail closed.
contract IndexVaultQuarantineTest is Test {
    uint48 internal constant HEARTBEAT = 1 days;
    uint256 internal constant BPS = 10_000;

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
    address internal stranger = makeAddr("stranger");

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

        vault = new IndexVault(IERC20(address(usdc)), registry, keeper, address(this));
        address[] memory constituents = new address[](2);
        constituents[0] = address(wbtc);
        constituents[1] = address(weth);
        vault.setConstituents(constituents);

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    /// @dev $100k WBTC + $100k WETH held by the vault.
    function _seedBasket() internal {
        wbtc.mint(address(vault), 1e8);
        weth.mint(address(vault), 20e18);
    }

    /// @dev Warps past the heartbeat to stale WBTC, then refreshes USDC and WETH
    /// so only WBTC is quarantined.
    function _quarantineWbtc() internal {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        usdcFeed.setAnswer(1e8);
        wethFeed.setAnswer(5_000e8);
    }

    // ========================================================================
    // NAV degradation
    // ========================================================================

    function test_Quarantine_DegradesNavInsteadOfReverting() public {
        _seedBasket();
        assertEq(vault.totalAssets(), 200_000e6); // fresh baseline

        _quarantineWbtc();

        assertTrue(vault.isQuarantined(address(wbtc)));
        assertFalse(vault.isQuarantined(address(weth)));

        // WBTC marked at base (9000) decayed by age/window: 9000 * (7d - (1d+1)) / 7d
        // = 7714 bps. WBTC $100k -> $77,140; WETH $100k fresh. Total $177,140.
        uint256 ta = vault.totalAssets();
        assertEq(ta, 177_140e6);
        assertLt(ta, 200_000e6);
    }

    function test_Quarantine_DeadFeedMarksToZero() public {
        _seedBasket();
        wbtcFeed.setAnswer(0); // dead feed: non-positive answer

        assertTrue(vault.isQuarantined(address(wbtc)));
        // WBTC values to zero, only fresh WETH ($100k) remains.
        assertEq(vault.totalAssets(), 100_000e6);
    }

    function test_Quarantine_DecaysToZeroOverWindow() public {
        _seedBasket();
        // Past the full decay window, the stale mark falls to zero.
        vm.warp(block.timestamp + 7 days + 1);
        usdcFeed.setAnswer(1e8);
        wethFeed.setAnswer(5_000e8);

        assertTrue(vault.isQuarantined(address(wbtc)));
        assertEq(vault.totalAssets(), 100_000e6); // WBTC fully decayed, WETH fresh
    }

    // ========================================================================
    // The liveness guarantee: buffer redemptions survive a stale feed
    // ========================================================================

    function test_Quarantine_BufferRedeemSurvives() public {
        _seedBasket();
        // Alice deposits while everything is fresh, leaving an idle buffer.
        vm.prank(alice);
        uint256 shares = vault.deposit(10_000e6, alice);
        assertGt(shares, 0);

        _quarantineWbtc();

        // A small buffer redemption still works, at the degraded (haircut) NAV.
        uint256 redeemShares = shares / 4;
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(redeemShares, alice, alice);

        assertGt(assetsOut, 0, "buffer exit must survive a stale feed");
        assertEq(usdc.balanceOf(alice) - before, assetsOut);
    }

    // ========================================================================
    // Mints and settlement fail closed
    // ========================================================================

    function test_Quarantine_MintFailsClosed() public {
        _seedBasket();
        _quarantineWbtc();

        vm.prank(alice);
        vm.expectRevert(IndexVault_QuarantineBlocksDeposit.selector);
        vault.deposit(1_000e6, alice);
    }

    function test_Quarantine_SettleFailsClosed() public {
        _seedBasket();
        vm.prank(alice);
        vault.requestDeposit(10_000e6, alice, alice);

        _quarantineWbtc();
        vm.roll(block.number + 1);

        vm.prank(keeper);
        vm.expectRevert(IndexVault_QuarantineBlocksSettle.selector);
        vault.settle();
    }

    function test_Quarantine_ZeroBalanceDoesNotBlockEntries() public {
        // Vault holds only WETH; WBTC balance is zero.
        weth.mint(address(vault), 20e18);
        _quarantineWbtc(); // WBTC feed stale, but the vault holds none of it

        assertTrue(vault.isQuarantined(address(wbtc)));
        assertFalse(vault.isAnyQuarantined(), "a zero-balance stale feed must not block entries");

        // A deposit goes through because no held constituent is quarantined.
        vm.prank(alice);
        assertGt(vault.deposit(1_000e6, alice), 0);
    }

    // ========================================================================
    // Params
    // ========================================================================

    function test_SetQuarantineParams() public {
        vault.setQuarantineParams(2000, 3 days);
        assertEq(vault.quarantineHaircutBps(), 2000);
        assertEq(vault.quarantineDecayWindow(), 3 days);
    }

    function test_SetQuarantineParams_Validates() public {
        vm.expectRevert(IndexVault_InvalidQuarantineParams.selector);
        vault.setQuarantineParams(uint16(BPS), 3 days); // haircut must be < 100%

        vm.expectRevert(IndexVault_InvalidQuarantineParams.selector);
        vault.setQuarantineParams(1000, 0); // window must be nonzero
    }

    function test_SetQuarantineParams_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setQuarantineParams(2000, 3 days);
    }
}
