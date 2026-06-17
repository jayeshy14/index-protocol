// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { AssetRegistry } from "src/AssetRegistry.sol";
import { GPv2Order } from "src/libraries/GPv2Order.sol";
import { CoWOrderHandler } from "src/rebalancer/CoWOrderHandler.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";

interface ICoWSettlement {
    function domainSeparator() external view returns (bytes32);
    function vaultRelayer() external view returns (address);
}

/// @notice Mainnet-fork spike: proves the handler reconstructs the exact EIP-712
/// digest the real GPv2Settlement verifies against, and binds to the real
/// relayer. Requires a mainnet RPC; run with `forge test --match-path
/// '*CoWOrderHandlerFork*'` against the `mainnet` endpoint.
contract CoWOrderHandlerForkTest is Test {
    // Canonical CoW deployments (same address across chains).
    address internal constant SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address internal constant RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint48 internal constant HEARTBEAT = 1 days;

    AssetRegistry internal registry;
    CoWOrderHandler internal handler;

    function setUp() public {
        vm.createSelectFork("mainnet");

        registry = new AssetRegistry(address(this));
        registry.setUsdcFeed(USDC, address(new MockAggregator(8, 1e8)), HEARTBEAT);
        registry.registerAsset(WETH, address(new MockAggregator(8, 2000e8)), HEARTBEAT);

        handler = new CoWOrderHandler(makeAddr("vault"), registry, USDC, SETTLEMENT, 100);
    }

    /// @notice The handler bound to the real settlement's domain and relayer.
    function test_Fork_BindsRealDomainAndRelayer() public view {
        bytes32 real = ICoWSettlement(SETTLEMENT).domainSeparator();
        assertEq(handler.DOMAIN_SEPARATOR(), real, "handler domain separator != real settlement");
        assertEq(handler.RELAYER(), RELAYER, "handler relayer != real vault relayer");
        assertEq(ICoWSettlement(SETTLEMENT).vaultRelayer(), RELAYER, "unexpected real relayer");
    }

    /// @notice The digest the handler validates equals the digest computed from
    /// the real settlement's domain separator. This is the make-or-break proof:
    /// our order encoding hashes byte-for-byte to what CoW verifies on-chain.
    function test_Fork_DigestMatchesRealSettlement() public view {
        GPv2Order.Data memory order =
            handler.buildSellOrder(WETH, 1e18, uint32(block.timestamp + 1 hours), bytes32("epoch1"));

        bytes32 viaHandler = handler.orderDigest(order);
        bytes32 viaRealDomain = GPv2Order.hash(order, ICoWSettlement(SETTLEMENT).domainSeparator());

        assertEq(viaHandler, viaRealDomain, "handler digest != real-domain digest");

        // And the handler accepts that digest, returning the ERC-1271 magic value.
        assertEq(handler.isValidSignature(viaHandler, abi.encode(order)), bytes4(0x1626ba7e));
    }

    /// @notice The independently recomputed EIP-712 domain separator (chainId 1,
    /// verifyingContract = settlement, name "Gnosis Protocol", version "v2")
    /// matches what the live contract returns.
    function test_Fork_DomainSeparatorFormula() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gnosis Protocol"),
                keccak256("v2"),
                block.chainid,
                SETTLEMENT
            )
        );
        assertEq(ICoWSettlement(SETTLEMENT).domainSeparator(), expected, "domain formula mismatch");
        assertEq(block.chainid, 1, "not forking mainnet");
    }
}
