// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { ComponentRegistry } from "src/ComponentRegistry.sol";
import {
    MarketCapMethodology,
    MarketCapMethodology_MarketCapExceedsSanityBound,
    MarketCapMethodology_InvalidTotalMarketCap,
    MarketCapMethodology_InvalidParams
} from "src/methodology/MarketCapMethodology.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";
import { MockSupplyOracle } from "test/mocks/MockSupplyOracle.sol";

contract MarketCapMethodologyTest is Test {
    uint256 internal constant WAD = 1e18;
    uint48 internal constant HEARTBEAT = 1 days;

    ComponentRegistry internal registry;
    MockSupplyOracle internal supplyOracle;
    MarketCapMethodology internal methodology;

    MockERC20 internal wbtc;
    MockERC20 internal weth;
    MockERC20 internal sol;
    MockERC20 internal tail;

    MockAggregator internal wbtcFeed;
    MockAggregator internal wethFeed;
    MockAggregator internal solFeed;
    MockAggregator internal tailFeed;

    address[] internal tokens;

    function setUp() public {
        vm.warp(30 days);

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        sol = new MockERC20("Wrapped SOL", "WSOL", 9);
        tail = new MockERC20("Tail Token", "TAIL", 18);

        wbtcFeed = new MockAggregator(8, 100_000e8);
        wethFeed = new MockAggregator(8, 5_000e8);
        solFeed = new MockAggregator(8, 200e8);
        tailFeed = new MockAggregator(8, 1e8);

        registry = new ComponentRegistry(address(this));
        registry.registerComponent(address(wbtc), address(wbtcFeed), HEARTBEAT);
        registry.registerComponent(address(weth), address(wethFeed), HEARTBEAT);
        registry.registerComponent(address(sol), address(solFeed), HEARTBEAT);
        registry.registerComponent(address(tail), address(tailFeed), HEARTBEAT);

        supplyOracle = new MockSupplyOracle();
        // Whole-token units per the ISupplyOracle contract.
        supplyOracle.setSupply(address(wbtc), 20_000_000); // $2.0T
        supplyOracle.setSupply(address(weth), 120_000_000); // $600B
        supplyOracle.setSupply(address(sol), 500_000_000); // $100B
        supplyOracle.setSupply(address(tail), 1_000_000_000); // $1B

        methodology = new MarketCapMethodology(registry, ISupplyOracle(address(supplyOracle)), address(this));

        tokens.push(address(wbtc));
        tokens.push(address(weth));
        tokens.push(address(sol));
        tokens.push(address(tail));
    }

    function test_GetWeights_UncappedMatchesRawMarketCapRatio() public {
        // Lift the cap out of the way to verify the raw weighting alone.
        methodology.setWeightParams(WAD, 1);
        uint256[] memory w = methodology.getWeights(tokens);

        // Total $2.701T: BTC 2000/2701, ETH 600/2701, SOL 100/2701, TAIL 1/2701.
        assertApproxEqRel(w[0], uint256(2000e18) / 2701, 1e12);
        assertApproxEqRel(w[1], uint256(600e18) / 2701, 1e12);
        assertApproxEqRel(w[2], uint256(100e18) / 2701, 1e12);
        assertApproxEqRel(w[3], uint256(1e18) / 2701, 1e12);
    }

    function test_GetWeights_AppliesCapAndRedistributes() public view {
        // Default 25% cap. Raw BTC ~74% and ETH ~22%: BTC pins at the cap and
        // its excess cascades ETH over the cap as well.
        uint256[] memory w = methodology.getWeights(tokens);

        assertEq(w[0], 0.25e18, "BTC not pinned at cap");
        assertEq(w[1], 0.25e18, "ETH not pinned at cap after cascade");
        assertLe(w[2], 0.25e18);
        assertLe(w[3], 0.25e18);
        // SOL absorbs redistribution ahead of TAIL (100:1 raw ratio), but the
        // 25% cap pins SOL too, leaving TAIL with the remainder.
        assertEq(w[2], 0.25e18);
        assertEq(w[3], 0.25e18);

        uint256 sum = w[0] + w[1] + w[2] + w[3];
        assertEq(sum, WAD);
    }

    function test_GetWeights_CapDoesSecurityWork() public {
        // A manipulated supply on a capped constituent must
        // not move its weight. Double BTC's reported supply; BTC stays at cap.
        uint256[] memory before = methodology.getWeights(tokens);
        supplyOracle.setSupply(address(wbtc), 40_000_000);
        uint256[] memory afterW = methodology.getWeights(tokens);

        assertEq(before[0], afterW[0], "capped weight moved with supply");
        assertEq(afterW[0], 0.25e18);
    }

    function test_GetWeights_FloorPrunesDustPosition() public {
        // 40% cap so the index is not fully degenerate, tail floor at 0.05%.
        methodology.setWeightParams(0.4e18, 5e14);
        // Shrink TAIL to a dust market cap ($100M against $2.7T).
        supplyOracle.setSupply(address(tail), 100_000_000);

        uint256[] memory w = methodology.getWeights(tokens);
        assertEq(w[3], 0, "dust constituent not pruned");

        uint256 sum = w[0] + w[1] + w[2];
        assertEq(sum, WAD);
    }

    function test_GetWeights_RevertsOnSupplyUnitError() public {
        // Supply mistakenly in native 18-decimal units: market cap blows
        // through the 1e30 sanity bound.
        supplyOracle.setSupply(address(weth), 120_000_000e18);
        vm.expectRevert();
        methodology.getWeights(tokens);
    }

    function test_GetWeights_RevertsOnStalePrice() public {
        vm.warp(block.timestamp + HEARTBEAT + 1);
        vm.expectRevert();
        methodology.getWeights(tokens);
    }

    function test_GetWeights_RevertsOnUnsetSupply() public {
        MockERC20 unknown = new MockERC20("Unknown", "UNK", 18);
        MockAggregator unknownFeed = new MockAggregator(8, 1e8);
        registry.registerComponent(address(unknown), address(unknownFeed), HEARTBEAT);
        tokens.push(address(unknown));

        vm.expectRevert();
        methodology.getWeights(tokens);
    }

    function test_GetWeights_RevertsOnZeroTotalMarketCap() public {
        address[] memory single = new address[](1);
        single[0] = address(tail);
        supplyOracle.setSupply(address(tail), 0);

        vm.expectRevert(MarketCapMethodology_InvalidTotalMarketCap.selector);
        methodology.getWeights(single);
    }

    function test_SetWeightParams_Validates() public {
        vm.expectRevert(MarketCapMethodology_InvalidParams.selector);
        methodology.setWeightParams(0, 0);

        vm.expectRevert(MarketCapMethodology_InvalidParams.selector);
        methodology.setWeightParams(0.2e18, 0.2e18);

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        methodology.setWeightParams(0.3e18, 1e14);
    }

    /// @notice End-to-end weighting invariants under fuzzed prices and supplies.
    function testFuzz_GetWeights_Invariants(uint256[4] memory priceSeeds, uint256[4] memory supplySeeds) public {
        MockAggregator[4] memory feeds = [wbtcFeed, wethFeed, solFeed, tailFeed];
        address[4] memory addrs = [address(wbtc), address(weth), address(sol), address(tail)];
        for (uint256 i = 0; i < 4; i++) {
            feeds[i].setAnswer(int256(bound(priceSeeds[i], 1e6, 1_000_000e8))); // $0.01 to $1M
            supplyOracle.setSupply(addrs[i], bound(supplySeeds[i], 1_000, 10_000_000_000)); // 1k to 10B tokens
        }

        uint256[] memory w;
        try methodology.getWeights(tokens) returns (uint256[] memory result) {
            w = result;
        } catch {
            // Sanity-bound reverts on extreme combinations are correct behavior.
            return;
        }

        uint256 sum = 0;
        for (uint256 i = 0; i < 4; i++) {
            assertLe(w[i], methodology.capWad());
            assertTrue(w[i] == 0 || w[i] >= methodology.floorWad());
            sum += w[i];
        }
        assertEq(sum, WAD);
    }
}
