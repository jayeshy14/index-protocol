// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AssetRegistry } from "src/AssetRegistry.sol";
import { IndexVault } from "src/IndexVault.sol";
import { MarketCapMethodology } from "src/methodology/MarketCapMethodology.sol";
import { ExcludedAddressRegistry } from "src/oracle/ExcludedAddressRegistry.sol";
import { SupplyOracle } from "src/oracle/SupplyOracle.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { IMethodology } from "src/interfaces/IMethodology.sol";
import { Rebalancer } from "src/rebalancer/Rebalancer.sol";
import { ConstituentGovernor } from "src/governance/ConstituentGovernor.sol";

/**
 * @title Deploy
 * @notice One-shot deployment and wiring for the index protocol: the supply
 * oracle stack, the asset registry, the market-cap methodology, the async
 * vault, and the CoW rebalancer.
 *
 * The deployer is the temporary owner of every contract that needs owner-gated
 * wiring (feed registration, constituents, weight params, oracle params,
 * rebalancer wiring, relayer approvals) inside the broadcast. Afterwards every
 * such contract is handed to a single top-level OWNER (a multisig, or a
 * TimelockController, in production), so there is one governance authority over
 * the whole system. Every contract is Ownable2Step, so OWNER must call
 * acceptOwnership() on each to complete the handoff. The ConstituentGovernor
 * needs no deploy-time owner calls, so it is owned by OWNER from construction.
 *
 * GUARDIAN is the single guardian for both the supply oracle (pause) and the
 * constituent governor (veto). KEEPER and REPORTER are operational roles set to
 * their final holders directly.
 *
 * Required env:
 *   PRIVATE_KEY   deployer key (also the transient owner during wiring)
 *
 * Optional env (default to the deployer / mainnet canonical addresses):
 *   OWNER         single top-level owner / governance multisig  (default: deployer)
 *   KEEPER        settlement + scheduled-rebalance keeper       (default: deployer)
 *   GUARDIAN      supply-oracle pause + governor veto guardian  (default: deployer)
 *   REPORTER      initial free-float factor reporter            (default: deployer)
 *   USDC          base asset                                    (default: mainnet USDC)
 *   SETTLEMENT    GPv2Settlement                                (default: mainnet GPv2)
 *
 * Usage:
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url mainnet --broadcast --verify
 *
 * Dry run (no broadcast):
 *   forge script script/Deploy.s.sol:Deploy --rpc-url mainnet
 */
contract Deploy is Script {
    // --- Canonical mainnet addresses (override base ones via env) ---------

    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant MAINNET_GPV2_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    address internal constant MAINNET_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant MAINNET_BTC_USD_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // --- Heartbeats -------------------------------------------------------

    uint48 internal constant USDC_HEARTBEAT = 1 days; // USDC/USD ticks slowly
    uint48 internal constant ASSET_HEARTBEAT = 1 hours; // BTC/USD, ETH/USD

    // --- Methodology params (WAD) -----------------------------------------

    uint256 internal constant CAP_TARGET_WAD = 0.25e18; // cap to 25%
    uint256 internal constant CAP_TRIGGER_WAD = 0.3e18; // recap only above 30% actual
    uint256 internal constant FLOOR_WAD = 1e14; // prune sub-1bp dust positions

    // --- Rebalancer trigger params ----------------------------------------

    uint256 internal constant MAX_SLIPPAGE_BPS = 100; // 1% per-order floor
    uint256 internal constant MIN_INTERVAL = 1 hours; // anti-churn floor
    uint256 internal constant CADENCE = 7 days; // scheduled keeper cadence
    uint256 internal constant D_SMALL_BPS = 200; // 2% scheduled drift gate
    uint256 internal constant D_LARGE_BPS = 500; // 5% permissionless emergency gate

    // --- Excluded-address timelock + supply-oracle params -----------------

    uint256 internal constant EXCLUDED_DELAY = 1 days;
    uint256 internal constant MIN_REPORTERS = 1; // bootstrap single-reporter
    uint256 internal constant DIVERGENCE_TOLERANCE_BPS = 500; // 5% multi-source freeze band
    uint256 internal constant REPORT_STALE_AFTER = 1 days;
    uint256 internal constant MAX_COMMIT_AGE = 7 days;
    uint256 internal constant MAX_FACTOR_DELTA_BPS = 1000; // 10% per-commit clamp
    uint256 internal constant MIN_COMMIT_INTERVAL = 1 hours;

    // --- Constituent governance params ------------------------------------

    uint256 internal constant ADD_DELAY = 2 days;
    uint256 internal constant FORCED_REMOVE_DELAY = 6 hours; // fast: only on proven failure
    uint256 internal constant DISCRETIONARY_REMOVE_DELAY = 7 days; // slow: healthy-asset removal
    uint256 internal constant MIN_CONSTITUENT_USD = 100_000_000; // $100M whole-USD size floor
    // Floor on the count after a removal. For a real index set this to
    // ceil(WAD / capTarget) so capping stays feasible (e.g. 4 at a 25% cap) and
    // seed at least that many constituents; the two-asset example relaxes it.
    uint256 internal constant MIN_CONSTITUENT_COUNT = 2;
    uint256 internal constant MAX_CHANGES_PER_WINDOW = 3;
    uint256 internal constant CHANGE_WINDOW = 7 days;

    struct Constituent {
        address token;
        address feed;
        uint48 heartbeat;
    }

    struct Deployment {
        ExcludedAddressRegistry excluded;
        SupplyOracle supplyOracle;
        AssetRegistry registry;
        MarketCapMethodology methodology;
        IndexVault vault;
        Rebalancer rebalancer;
        ConstituentGovernor governor;
    }

    function run() external returns (Deployment memory d) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address owner = vm.envOr("OWNER", deployer);
        address keeper = vm.envOr("KEEPER", deployer);
        address guardian = vm.envOr("GUARDIAN", deployer);
        address reporter = vm.envOr("REPORTER", deployer);

        address usdc = vm.envOr("USDC", MAINNET_USDC);
        address settlement = vm.envOr("SETTLEMENT", MAINNET_GPV2_SETTLEMENT);

        Constituent[] memory constituents = _mainnetConstituents();

        console2.log("Deployer       ", deployer);
        console2.log("Final owner    ", owner);
        console2.log("Keeper         ", keeper);
        console2.log("Guardian       ", guardian);
        console2.log("USDC           ", usdc);
        console2.log("GPv2 settlement", settlement);

        vm.startBroadcast(pk);

        // 1. Supply-oracle stack. The deployer is the transient owner.
        d.excluded = new ExcludedAddressRegistry(deployer, EXCLUDED_DELAY);
        d.supplyOracle = new SupplyOracle(d.excluded, guardian, deployer);
        d.supplyOracle
            .setParams(
                MIN_REPORTERS,
                DIVERGENCE_TOLERANCE_BPS,
                REPORT_STALE_AFTER,
                MAX_COMMIT_AGE,
                MAX_FACTOR_DELTA_BPS,
                MIN_COMMIT_INTERVAL
            );
        d.supplyOracle.addReporter(reporter);

        // 2. Asset registry: base-asset feed plus the constituent catalog.
        d.registry = new AssetRegistry(deployer);
        d.registry.setUsdcFeed(usdc, _usdcFeed(usdc), USDC_HEARTBEAT);
        for (uint256 i = 0; i < constituents.length; i++) {
            d.registry.registerAsset(constituents[i].token, constituents[i].feed, constituents[i].heartbeat);
        }

        // 3. Methodology over the registry + oracle.
        d.methodology = new MarketCapMethodology(d.registry, ISupplyOracle(address(d.supplyOracle)), deployer);
        d.methodology.setWeightParams(CAP_TARGET_WAD, CAP_TRIGGER_WAD, FLOOR_WAD);

        // 4. Vault, then install the constituent set.
        d.vault = new IndexVault(IERC20(usdc), d.registry, keeper, deployer);
        address[] memory tokens = new address[](constituents.length);
        for (uint256 i = 0; i < constituents.length; i++) {
            tokens[i] = constituents[i].token;
        }
        d.vault.setConstituents(tokens);

        // 5. Rebalancer (reads relayer + domain separator from the settlement).
        d.rebalancer = new Rebalancer(
            d.vault,
            IMethodology(address(d.methodology)),
            d.registry,
            usdc,
            settlement,
            keeper,
            MAX_SLIPPAGE_BPS,
            MIN_INTERVAL,
            CADENCE,
            D_SMALL_BPS,
            D_LARGE_BPS
        );

        // 6. Wire the rebalancer into the vault and approve the relayer for
        // every sellable constituent plus USDC (the buy leg).
        d.vault.setRebalancer(address(d.rebalancer), settlement);
        for (uint256 i = 0; i < constituents.length; i++) {
            d.vault.approveRelayer(constituents[i].token);
        }
        d.vault.approveRelayer(usdc);

        // 7. Constituent governor. It needs no deploy-time owner calls, so it is
        // owned by the final owner from construction. Wiring it into the vault
        // locks setConstituents to its pre-governance seeding role above, so this
        // must run after the seed.
        d.governor = new ConstituentGovernor(
            d.vault,
            d.registry,
            ISupplyOracle(address(d.supplyOracle)),
            guardian,
            owner,
            ADD_DELAY,
            FORCED_REMOVE_DELAY,
            DISCRETIONARY_REMOVE_DELAY,
            MIN_CONSTITUENT_USD,
            MIN_CONSTITUENT_COUNT,
            MAX_CHANGES_PER_WINDOW,
            CHANGE_WINDOW
        );
        d.vault.setGovernor(address(d.governor));

        // 8. Hand every deployer-owned contract to the single top-level owner.
        // Done last so all owner-gated wiring above could run under the deployer.
        // Ownable2Step: the new owner must call acceptOwnership() on each.
        if (owner != deployer) {
            d.excluded.transferOwnership(owner);
            d.supplyOracle.transferOwnership(owner);
            d.registry.transferOwnership(owner);
            d.methodology.transferOwnership(owner);
            d.vault.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console2.log("--- deployed ---");
        console2.log("ExcludedAddressRegistry", address(d.excluded));
        console2.log("SupplyOracle           ", address(d.supplyOracle));
        console2.log("AssetRegistry          ", address(d.registry));
        console2.log("MarketCapMethodology   ", address(d.methodology));
        console2.log("IndexVault             ", address(d.vault));
        console2.log("Rebalancer             ", address(d.rebalancer));
        console2.log("ConstituentGovernor    ", address(d.governor));
    }

    /// @dev The starting basket. Edit here (or fork this script per network) to
    /// change the catalog; the wiring loops are constituent-count agnostic.
    function _mainnetConstituents() internal pure returns (Constituent[] memory c) {
        c = new Constituent[](2);
        c[0] = Constituent(MAINNET_WBTC, MAINNET_BTC_USD_FEED, ASSET_HEARTBEAT);
        c[1] = Constituent(MAINNET_WETH, MAINNET_ETH_USD_FEED, ASSET_HEARTBEAT);
    }

    /// @dev Maps the base asset to its USD feed. Only mainnet USDC is wired by
    /// default; override the asset and supply the feed when deploying elsewhere.
    function _usdcFeed(address usdc) internal pure returns (address) {
        if (usdc == MAINNET_USDC) return MAINNET_USDC_USD_FEED;
        revert("Deploy: no USDC feed for this base asset; set it explicitly");
    }
}
