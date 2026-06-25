// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IndexVault, IndexVault_GovernorAlreadySet, IndexVault_PositionNotDust } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import { MarketCapMethodology } from "src/methodology/MarketCapMethodology.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { Rebalancer } from "src/rebalancer/Rebalancer.sol";
import {
    ConstituentGovernor,
    ConstituentGovernor_AssetHealthy,
    ConstituentGovernor_BelowMinSize,
    ConstituentGovernor_BelowMinCount,
    ConstituentGovernor_RateLimited,
    ConstituentGovernor_AlreadyConstituent,
    ConstituentGovernor_NotConstituent,
    ConstituentGovernor_NotGuardianOrOwner
} from "src/governance/ConstituentGovernor.sol";
import { Timelock_NotElapsed, Timelock_NotScheduled } from "src/governance/TimelockedProposals.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockAggregator } from "test/mocks/MockAggregator.sol";
import { MockSupplyOracle } from "test/mocks/MockSupplyOracle.sol";
import { MockGPv2Settlement } from "test/mocks/MockGPv2Settlement.sol";

/// @notice Section 16 constituent-governance guardrails: timelocked, bounded,
/// two-path removal with wind-down execution safety.
contract ConstituentGovernorTest is Test {
    uint256 internal constant WAD = 1e18;
    // Long heartbeat so the multi-day timelock warps in these tests do not trip
    // feed staleness, which is exercised elsewhere and is not the subject here.
    uint48 internal constant HEARTBEAT = 3650 days;

    uint256 internal constant ADD_DELAY = 2 days;
    uint256 internal constant FORCED_DELAY = 6 hours;
    uint256 internal constant DISC_DELAY = 7 days;
    uint256 internal constant MIN_USD = 1_000_000; // $1M whole USD
    uint256 internal constant MIN_COUNT = 2;
    uint256 internal constant MAX_CHANGES = 3;
    uint256 internal constant WINDOW = 7 days;

    AssetRegistry internal registry;
    MarketCapMethodology internal methodology;
    MockSupplyOracle internal supplyOracle;
    IndexVault internal vault;
    Rebalancer internal rebalancer;
    ConstituentGovernor internal governor;

    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal weth;
    MockERC20 internal link;
    MockERC20 internal uni;
    MockERC20 internal dust;

    MockAggregator internal usdcFeed;
    MockAggregator internal wbtcFeed;
    MockAggregator internal wethFeed;
    MockAggregator internal linkFeed;
    MockAggregator internal uniFeed;
    MockAggregator internal dustFeed;

    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(30 days);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        link = new MockERC20("Chainlink", "LINK", 18);
        uni = new MockERC20("Uniswap", "UNI", 18);
        dust = new MockERC20("Dust", "DUST", 18);

        usdcFeed = new MockAggregator(8, 1e8);
        wbtcFeed = new MockAggregator(8, 100_000e8);
        wethFeed = new MockAggregator(8, 5_000e8);
        linkFeed = new MockAggregator(8, 20e8);
        uniFeed = new MockAggregator(8, 10e8);
        dustFeed = new MockAggregator(8, 1e8);

        registry = new AssetRegistry(address(this));
        registry.setUsdcFeed(address(usdc), address(usdcFeed), HEARTBEAT);
        registry.registerAsset(address(wbtc), address(wbtcFeed), HEARTBEAT);
        registry.registerAsset(address(weth), address(wethFeed), HEARTBEAT);
        registry.registerAsset(address(link), address(linkFeed), HEARTBEAT);
        registry.registerAsset(address(uni), address(uniFeed), HEARTBEAT);
        registry.registerAsset(address(dust), address(dustFeed), HEARTBEAT);

        supplyOracle = new MockSupplyOracle();
        supplyOracle.setSupply(address(wbtc), 1_000_000);
        supplyOracle.setSupply(address(weth), 20_000_000);
        supplyOracle.setSupply(address(link), 1_000_000_000);
        supplyOracle.setSupply(address(uni), 1_000_000); // $10M at $10
        supplyOracle.setSupply(address(dust), 1); // $1 at $1, below the floor

        methodology = new MarketCapMethodology(registry, ISupplyOracle(address(supplyOracle)), address(this));
        methodology.setWeightParams(WAD, WAD, 1); // no cap, so 3 constituents are feasible

        vault = new IndexVault(IERC20(address(usdc)), registry, keeper, address(this));

        address[] memory seed = new address[](3);
        seed[0] = address(wbtc);
        seed[1] = address(weth);
        seed[2] = address(link);
        vault.setConstituents(seed);

        MockGPv2Settlement settlement = new MockGPv2Settlement();
        rebalancer = new Rebalancer(
            vault,
            methodology,
            registry,
            address(usdc),
            address(settlement),
            keeper,
            100, // 1% slippage
            1 hours,
            7 days,
            200,
            500
        );
        vault.setRebalancer(address(rebalancer), address(settlement));

        governor = new ConstituentGovernor(
            vault,
            registry,
            ISupplyOracle(address(supplyOracle)),
            guardian,
            address(this),
            ADD_DELAY,
            FORCED_DELAY,
            DISC_DELAY,
            MIN_USD,
            MIN_COUNT,
            MAX_CHANGES,
            WINDOW
        );
        vault.setGovernor(address(governor));
    }

    // ========================================================================
    // Wiring
    // ========================================================================

    function test_SetGovernor_LocksSeedSetter() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(wbtc);
        tokens[1] = address(weth);
        vm.expectRevert(IndexVault_GovernorAlreadySet.selector);
        vault.setConstituents(tokens);
    }

    // ========================================================================
    // Additions (16.2)
    // ========================================================================

    function test_Add_FullLifecycle() public {
        governor.proposeAdd(address(uni), "add UNI to the index");
        vm.warp(block.timestamp + ADD_DELAY);
        governor.executeAdd(address(uni));
        assertTrue(vault.isConstituent(address(uni)));
        assertEq(vault.constituentCount(), 4);
    }

    function test_Add_RevertsBeforeTimelock() public {
        governor.proposeAdd(address(uni), "add UNI");
        vm.warp(block.timestamp + ADD_DELAY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Timelock_NotElapsed.selector,
                governor.proposalId(address(uni), ConstituentGovernor.ChangeKind.Add),
                block.timestamp + 1
            )
        );
        governor.executeAdd(address(uni));
    }

    function test_Add_RevertsBelowMinSize() public {
        governor.proposeAdd(address(dust), "try to slip a microcap in");
        vm.warp(block.timestamp + ADD_DELAY);
        vm.expectRevert(abi.encodeWithSelector(ConstituentGovernor_BelowMinSize.selector, address(dust), 1, MIN_USD));
        governor.executeAdd(address(dust));
    }

    function test_Add_RevertsForExistingConstituent() public {
        vm.expectRevert(abi.encodeWithSelector(ConstituentGovernor_AlreadyConstituent.selector, address(wbtc)));
        governor.proposeAdd(address(wbtc), "already in");
    }

    function test_Add_OnlyOwnerCanPropose() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.proposeAdd(address(uni), "x");
    }

    // ========================================================================
    // Forced removal (16.1, fast, requires on-chain proof)
    // ========================================================================

    function test_ForcedRemove_RevertsForHealthyAsset() public {
        vm.expectRevert(abi.encodeWithSelector(ConstituentGovernor_AssetHealthy.selector, address(wbtc)));
        governor.proposeForcedRemove(address(wbtc), "this asset is fine");
    }

    function test_ForcedRemove_AllowedWhenSupplyFails() public {
        supplyOracle.setSupply(address(link), 0); // supply entry fails
        governor.proposeForcedRemove(address(link), "supply oracle failed for LINK");
        vm.warp(block.timestamp + FORCED_DELAY);
        governor.executeForcedRemove(address(link));
        assertTrue(vault.windingDown(address(link)));
    }

    function test_ForcedRemove_AllowedWhenDeregistered() public {
        registry.removeAsset(address(link));
        governor.proposeForcedRemove(address(link), "LINK deregistered from catalog");
        vm.warp(block.timestamp + FORCED_DELAY);
        governor.executeForcedRemove(address(link));
        assertTrue(vault.windingDown(address(link)));
    }

    function test_ForcedRemove_ProofMustHoldAtExecution() public {
        supplyOracle.setSupply(address(link), 0);
        governor.proposeForcedRemove(address(link), "failed now");
        // The asset recovers during the timelock window.
        supplyOracle.setSupply(address(link), 1_000_000_000);
        vm.warp(block.timestamp + FORCED_DELAY);
        vm.expectRevert(abi.encodeWithSelector(ConstituentGovernor_AssetHealthy.selector, address(link)));
        governor.executeForcedRemove(address(link));
    }

    // ========================================================================
    // Discretionary removal (16.1, slow, vetoable)
    // ========================================================================

    function test_DiscretionaryRemove_BeginsWindDownAfterLongDelay() public {
        governor.proposeDiscretionaryRemove(address(link), "reclassify LINK out");
        vm.warp(block.timestamp + DISC_DELAY);
        governor.executeDiscretionaryRemove(address(link));
        assertTrue(vault.windingDown(address(link)));
        assertTrue(vault.isConstituent(address(link))); // still held until dust
    }

    function test_GuardianCanVeto() public {
        governor.proposeDiscretionaryRemove(address(link), "discretionary");
        vm.prank(guardian);
        governor.cancelProposal(address(link), ConstituentGovernor.ChangeKind.DiscretionaryRemove);
        vm.warp(block.timestamp + DISC_DELAY);
        bytes32 id = governor.proposalId(address(link), ConstituentGovernor.ChangeKind.DiscretionaryRemove);
        vm.expectRevert(abi.encodeWithSelector(Timelock_NotScheduled.selector, id));
        governor.executeDiscretionaryRemove(address(link));
    }

    function test_NonGuardianNonOwnerCannotVeto() public {
        governor.proposeDiscretionaryRemove(address(link), "discretionary");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ConstituentGovernor_NotGuardianOrOwner.selector, stranger));
        governor.cancelProposal(address(link), ConstituentGovernor.ChangeKind.DiscretionaryRemove);
    }

    // ========================================================================
    // Wind-down execution safety (16.5)
    // ========================================================================

    function test_WindDown_ZeroesRebalancerTarget() public {
        // Fund the basket so it has a live NAV and balances.
        wbtc.mint(address(vault), 1e8);
        weth.mint(address(vault), 20e18);
        link.mint(address(vault), 100e18);

        _beginWindDown(address(link));

        vm.prank(keeper);
        rebalancer.openEpoch();
        assertEq(rebalancer.targetUsd(address(link)), 0, "winding-down target must be zero");
        assertGt(rebalancer.overweightUsd(address(link)), 0, "whole position should be the sell budget");
    }

    function test_Finalize_RevertsWhilePositionMaterial() public {
        link.mint(address(vault), 100e18); // ~$2,000, well above the $1 dust floor
        _beginWindDown(address(link));
        vm.expectRevert(
            abi.encodeWithSelector(IndexVault_PositionNotDust.selector, address(link), uint256(100e18) * 20e8 / 1e18)
        );
        governor.finalizeRemoval(address(link));
    }

    function test_Finalize_RemovesDustPosition() public {
        // vault holds zero LINK, so the position is already dust.
        _beginWindDown(address(link));
        governor.finalizeRemoval(address(link));
        assertFalse(vault.isConstituent(address(link)));
        assertFalse(vault.windingDown(address(link)));
        assertEq(vault.constituentCount(), 2);
    }

    function test_Finalize_EnforcesMinCount() public {
        _beginWindDown(address(link));
        governor.finalizeRemoval(address(link)); // 3 -> 2, allowed
        _beginWindDown(address(weth));
        vm.expectRevert(abi.encodeWithSelector(ConstituentGovernor_BelowMinCount.selector, 1, MIN_COUNT));
        governor.finalizeRemoval(address(weth)); // 2 -> 1, blocked
    }

    // ========================================================================
    // Rate limit (16.3)
    // ========================================================================

    function test_RateLimit_BlocksAfterMaxChangesPerWindow() public {
        // Propose three removals together, then execute them in one block so all
        // three land in the same rate-limit window (MAX_CHANGES = 3).
        governor.proposeDiscretionaryRemove(address(link), "1");
        governor.proposeDiscretionaryRemove(address(weth), "2");
        governor.proposeDiscretionaryRemove(address(wbtc), "3");
        vm.warp(block.timestamp + DISC_DELAY);
        governor.executeDiscretionaryRemove(address(link));
        governor.executeDiscretionaryRemove(address(weth));
        governor.executeDiscretionaryRemove(address(wbtc));

        // A fourth change in the same window is rate-limited.
        governor.proposeAdd(address(uni), "fourth change");
        vm.warp(block.timestamp + ADD_DELAY);
        vm.expectRevert(abi.encodeWithSelector(ConstituentGovernor_RateLimited.selector, MAX_CHANGES, MAX_CHANGES));
        governor.executeAdd(address(uni));
    }

    function test_RateLimit_ResetsAfterWindow() public {
        governor.proposeDiscretionaryRemove(address(link), "1");
        governor.proposeDiscretionaryRemove(address(weth), "2");
        governor.proposeDiscretionaryRemove(address(wbtc), "3");
        vm.warp(block.timestamp + DISC_DELAY);
        governor.executeDiscretionaryRemove(address(link));
        governor.executeDiscretionaryRemove(address(weth));
        governor.executeDiscretionaryRemove(address(wbtc));

        // Once a fresh window opens, the fourth change goes through.
        governor.proposeAdd(address(uni), "after window");
        vm.warp(block.timestamp + WINDOW + 1);
        governor.executeAdd(address(uni));
        assertTrue(vault.isConstituent(address(uni)));
    }

    // ========================================================================
    // Helpers
    // ========================================================================

    /// @dev Drives a discretionary removal through to the begun wind-down.
    function _beginWindDown(address token) internal {
        governor.proposeDiscretionaryRemove(token, "wind down");
        vm.warp(block.timestamp + DISC_DELAY);
        governor.executeDiscretionaryRemove(token);
    }
}
