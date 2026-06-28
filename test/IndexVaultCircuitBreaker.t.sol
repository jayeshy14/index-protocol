// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IndexVault } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import { IndexVault_Paused, IndexVault_NotGuardian, IndexVault_InvalidNavDeviation } from "src/IndexVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";

/// @notice Section 4 Slice 2: the vault pause / guardian brake and the
/// NAV-per-share circuit breaker (the backstop for a collective mispricing that
/// passes every per-feed check).
contract IndexVaultCircuitBreakerTest is Test {
    uint48 internal constant HEARTBEAT = 1 days;

    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal weth;

    MockAggregator internal usdcFeed;
    MockAggregator internal wbtcFeed;
    MockAggregator internal wethFeed;

    AssetRegistry internal registry;
    IndexVault internal vault;

    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
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
        vault.setGuardian(guardian);

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _seedBasket() internal {
        wbtc.mint(address(vault), 1e8); // $100k
        weth.mint(address(vault), 20e18); // $100k
    }

    function _settle() internal {
        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vault.settle();
    }

    // ========================================================================
    // Guardian and pause control
    // ========================================================================

    function test_Guardian_PauseAndOwnerUnpause() public {
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());

        vault.unpause(); // owner
        assertFalse(vault.paused());
    }

    function test_Pause_OnlyGuardianOrOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IndexVault_NotGuardian.selector, stranger));
        vault.pause();

        // Owner may also pause.
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.unpause();
    }

    // ========================================================================
    // Paused blocks value movement, allows settled claims
    // ========================================================================

    function test_Paused_BlocksEntryAndExit() public {
        _seedBasket();
        vm.prank(guardian);
        vault.pause();

        vm.startPrank(alice);
        vm.expectRevert(IndexVault_Paused.selector);
        vault.deposit(1_000e6, alice);

        vm.expectRevert(IndexVault_Paused.selector);
        vault.requestDeposit(1_000e6, alice, alice);

        vm.expectRevert(IndexVault_Paused.selector);
        vault.requestRedeem(1, alice, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vm.expectRevert(IndexVault_Paused.selector);
        vault.settle();
    }

    function test_Paused_BlocksOrderValidation() public {
        vm.prank(guardian);
        vault.pause();
        // The paused check precedes the rebalancer and decode, so any input reverts.
        vm.expectRevert(IndexVault_Paused.selector);
        vault.isValidSignature(bytes32(0), "");
    }

    function test_Paused_AllowsSettledClaim() public {
        _seedBasket();
        vm.prank(alice);
        vault.requestDeposit(10_000e6, alice, alice);
        _settle();

        // Pause after settlement; the already-settled claim must still pay out.
        vm.prank(guardian);
        vault.pause();

        vm.prank(alice);
        uint256 shares = vault.deposit(10_000e6, alice, alice); // claim form
        assertGt(shares, 0, "settled claim must survive a pause");
    }

    // ========================================================================
    // The NAV-per-share circuit breaker
    // ========================================================================

    function test_CircuitBreaker_TripsOnImplausibleJump() public {
        _seedBasket();
        _settle(); // establishes the NAV-per-share reference at $200k

        // WBTC doubles to $300k: basket $400k, NAV per share +100%, past the 50% band.
        wbtcFeed.setAnswer(300_000e8);

        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vault.settle(); // trips: pauses and returns, no revert

        assertTrue(vault.paused(), "breaker must auto-pause on an implausible jump");
    }

    function test_CircuitBreaker_NoTripWithinBand() public {
        _seedBasket();
        _settle();

        // WBTC to $130k: basket $230k, +15%, well within the 50% band.
        wbtcFeed.setAnswer(130_000e8);

        _settle();
        assertFalse(vault.paused(), "a move within the band must not trip the breaker");
    }

    function test_CircuitBreaker_UnpauseResetsReference() public {
        _seedBasket();
        _settle();
        wbtcFeed.setAnswer(300_000e8); // implausible jump

        vm.warp(block.timestamp + 2 hours);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        vault.settle();
        assertTrue(vault.paused());

        // Owner reviews, accepts the new price as legitimate, and unpauses: the
        // reference resets to the current price so the next settle does not re-trip.
        vault.unpause();
        _settle();
        assertFalse(vault.paused(), "reset reference must prevent an immediate re-trip");
    }

    // ========================================================================
    // Params
    // ========================================================================

    function test_SetMaxNavDeviation_Validates() public {
        vault.setMaxNavDeviation(3000);
        assertEq(vault.maxNavDeviationBps(), 3000);

        vm.expectRevert(IndexVault_InvalidNavDeviation.selector);
        vault.setMaxNavDeviation(0);

        vm.expectRevert(IndexVault_InvalidNavDeviation.selector);
        vault.setMaxNavDeviation(10_001);
    }
}
