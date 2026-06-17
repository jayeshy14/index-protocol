// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetRegistry } from "src/AssetRegistry.sol";
import { GPv2Order } from "src/libraries/GPv2Order.sol";
import {
    CoWOrderHandler,
    CoWHandler_DigestMismatch,
    CoWHandler_BelowMinOut,
    CoWHandler_WrongReceiver,
    CoWHandler_WrongBuyToken,
    CoWHandler_SellTokenNotRegistered
} from "src/rebalancer/CoWOrderHandler.sol";
import { MockGPv2Settlement } from "test/mocks/MockGPv2Settlement.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";

/// @notice Spike test: proves the CoW integration mechanics against a faithful
/// mock settlement, with no network. The fork test proves the digest matches
/// the real GPv2Settlement domain separator.
contract CoWOrderHandlerTest is Test {
    uint48 internal constant HEARTBEAT = 1 days;
    uint256 internal constant SLIPPAGE_BPS = 100; // 1%

    AssetRegistry internal registry;
    MockGPv2Settlement internal settlement;
    CoWOrderHandler internal handler;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockAggregator internal usdcFeed;
    MockAggregator internal wethFeed;

    address internal vault = makeAddr("vault");

    function setUp() public {
        vm.warp(30 days);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdcFeed = new MockAggregator(8, 1e8); // $1
        wethFeed = new MockAggregator(8, 2000e8); // $2000

        registry = new AssetRegistry(address(this));
        registry.setUsdcFeed(address(usdc), address(usdcFeed), HEARTBEAT);
        registry.registerAsset(address(weth), address(wethFeed), HEARTBEAT);

        settlement = new MockGPv2Settlement();
        handler = new CoWOrderHandler(vault, registry, address(usdc), address(settlement), SLIPPAGE_BPS);
    }

    function _order(uint256 sellAmount) internal view returns (GPv2Order.Data memory) {
        return handler.buildSellOrder(address(weth), sellAmount, uint32(block.timestamp + 1 hours), bytes32("epoch1"));
    }

    // ========================================================================
    // Order derivation and minOut
    // ========================================================================

    function test_BuildSellOrder_OracleAnchoredMinOut() public view {
        GPv2Order.Data memory order = _order(1e18); // sell 1 WETH

        assertEq(order.sellToken, address(weth));
        assertEq(order.buyToken, address(usdc));
        assertEq(order.receiver, vault);
        assertEq(order.kind, GPv2Order.KIND_SELL);
        assertTrue(order.partiallyFillable);
        assertEq(order.feeAmount, 0);
        // 1 WETH = $2000, less 1% slippage = 1980 USDC (6 decimals).
        assertEq(order.buyAmount, 1980e6);
        assertEq(handler.minOut(address(weth), 1e18), 1980e6);
    }

    // ========================================================================
    // ERC-1271 validation
    // ========================================================================

    function test_IsValidSignature_AcceptsDerivedOrder() public view {
        GPv2Order.Data memory order = _order(1e18);
        bytes32 digest = handler.orderDigest(order);

        bytes4 magic = handler.isValidSignature(digest, abi.encode(order));
        assertEq(magic, bytes4(0x1626ba7e), "did not return the ERC-1271 magic value");
    }

    function test_IsValidSignature_RejectsBelowMinOut() public {
        GPv2Order.Data memory order = _order(1e18);
        order.buyAmount = 1980e6 - 1; // one wei under the oracle-anchored minimum
        bytes32 digest = handler.orderDigest(order);

        vm.expectRevert(abi.encodeWithSelector(CoWHandler_BelowMinOut.selector, order.buyAmount, 1980e6));
        handler.isValidSignature(digest, abi.encode(order));
    }

    function test_IsValidSignature_RejectsWrongReceiver() public {
        GPv2Order.Data memory order = _order(1e18);
        order.receiver = makeAddr("attacker");
        bytes32 digest = handler.orderDigest(order);

        vm.expectRevert(abi.encodeWithSelector(CoWHandler_WrongReceiver.selector, order.receiver));
        handler.isValidSignature(digest, abi.encode(order));
    }

    function test_IsValidSignature_RejectsWrongBuyToken() public {
        GPv2Order.Data memory order = _order(1e18);
        order.buyToken = address(weth);
        bytes32 digest = handler.orderDigest(order);

        vm.expectRevert(abi.encodeWithSelector(CoWHandler_WrongBuyToken.selector, order.buyToken));
        handler.isValidSignature(digest, abi.encode(order));
    }

    function test_IsValidSignature_RejectsUnregisteredSellToken() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        GPv2Order.Data memory order = _order(1e18);
        order.sellToken = address(stray);
        // Keep the order internally consistent so it fails on the registry check.
        bytes32 digest = handler.orderDigest(order);

        vm.expectRevert(abi.encodeWithSelector(CoWHandler_SellTokenNotRegistered.selector, address(stray)));
        handler.isValidSignature(digest, abi.encode(order));
    }

    /// @notice The digest is rebound to the decoded order: a solver cannot pair
    /// the digest of a valid order with the encoding of a different order.
    function test_IsValidSignature_RejectsDigestOrderMismatch() public {
        GPv2Order.Data memory good = _order(1e18);
        GPv2Order.Data memory other = _order(2e18);
        bytes32 goodDigest = handler.orderDigest(good);

        // Present the good digest but encode the other order.
        vm.expectRevert(
            abi.encodeWithSelector(CoWHandler_DigestMismatch.selector, handler.orderDigest(other), goodDigest)
        );
        handler.isValidSignature(goodDigest, abi.encode(other));
    }

    function test_IsValidSignature_Gas() public view {
        GPv2Order.Data memory order = _order(1e18);
        bytes32 digest = handler.orderDigest(order);
        bytes memory sig = abi.encode(order);

        uint256 g = gasleft();
        handler.isValidSignature(digest, sig);
        console2.log("isValidSignature gas:", g - gasleft());
    }

    // ========================================================================
    // End-to-end settlement through the mock
    // ========================================================================

    function test_Settle_FullFillPaysVault() public {
        GPv2Order.Data memory order = _order(1e18);

        // Fund the trader (handler) with WETH and approve the relayer; fund the
        // settlement with USDC to pay out.
        weth.mint(address(handler), 1e18);
        handler.approveSell(address(weth));
        usdc.mint(address(settlement), 100_000e6);

        settlement.settle(order, address(handler), 1e18);

        assertEq(weth.balanceOf(address(handler)), 0, "sell token not pulled");
        assertEq(usdc.balanceOf(vault), 1980e6, "vault not paid the buy amount");
    }

    function test_Settle_PartialFillIsProportional() public {
        GPv2Order.Data memory order = _order(1e18);

        weth.mint(address(handler), 1e18);
        handler.approveSell(address(weth));
        usdc.mint(address(settlement), 100_000e6);

        // Fill half the order.
        settlement.settle(order, address(handler), 0.5e18);

        assertEq(weth.balanceOf(address(handler)), 0.5e18, "wrong sell remainder");
        assertEq(usdc.balanceOf(vault), 990e6, "partial fill not proportional");
    }

    function test_Settle_RejectsTamperedOrderAtSettlement() public {
        GPv2Order.Data memory order = _order(1e18);
        order.buyAmount = 1; // far below minOut

        weth.mint(address(handler), 1e18);
        handler.approveSell(address(weth));
        usdc.mint(address(settlement), 100_000e6);

        // The settlement computes the digest of this tampered order and calls
        // isValidSignature, which rejects it, so settlement reverts.
        vm.expectRevert();
        settlement.settle(order, address(handler), 1e18);
    }
}
