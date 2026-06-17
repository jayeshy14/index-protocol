// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { AssetRegistry } from "src/AssetRegistry.sol";
import { IMethodology } from "src/interfaces/IMethodology.sol";
import { ISupplyOracle } from "src/interfaces/ISupplyOracle.sol";
import { WeightMath } from "src/libraries/WeightMath.sol";

// ============================================================================
// Errors
// ============================================================================

/// @notice Thrown when a constructor argument is the zero address.
error MarketCapMethodology_ZeroAddress();

/// @notice Thrown when total market cap is zero, so weights are undefined.
error MarketCapMethodology_InvalidTotalMarketCap();

/// @notice Thrown when a component's market cap exceeds the sanity bound,
/// which almost always means the supply arrived in native decimals instead
/// of whole tokens.
error MarketCapMethodology_MarketCapExceedsSanityBound(address token, uint256 marketCap);

/// @notice Thrown when cap or floor parameters are inconsistent.
error MarketCapMethodology_InvalidParams();

/**
 * @title MarketCapMethodology
 * @notice Reference IMethodology implementation: float-adjusted market-cap
 * weighting with a hard per-asset cap, iteratively redistributed, and a
 * minimum-weight floor that prunes dust positions. This is standard
 * index-provider methodology (capped market-cap with float adjustment),
 * which almost no on-chain index implements correctly.
 *
 * The cap does security work beyond diversification: large constituents are
 * pinned at the cap regardless of their exact supply, so supply-oracle
 * precision only matters for the mid and long tail, where the value at risk
 * from manipulation is smaller.
 */
contract MarketCapMethodology is IMethodology, Ownable2Step {
    using Math for uint256;

    /// @notice Shared asset catalog for constituent USD prices (8 decimals).
    AssetRegistry public immutable REGISTRY;

    /// @notice Float-adjusted circulating supply source, in whole tokens.
    ISupplyOracle public immutable SUPPLY_ORACLE;

    /// @notice Sanity bound on a single constituent's market cap in whole USD.
    /// No real asset is worth ~1e30 dollars, so anything above it means the
    /// supply arrived in native token decimals instead of whole tokens.
    uint256 public constant MARKET_CAP_SANITY_BOUND = 1e30;

    /// @notice Per-asset weight cap in WAD, the level a constituent is brought
    /// down to when capped. The target computation always caps to this. Default 25%.
    uint256 public capTargetWad = 0.25e18;

    /// @notice Actual-weight threshold (at or above capTargetWad) past which a
    /// capped constituent is rebalanced back to capTargetWad. The gap is
    /// hysteresis: a held weight may drift between target and trigger without
    /// forcing a trade, mirroring the Nasdaq-100 special rebalance (cap to 20%,
    /// trigger at 24%). The weight computation here always caps to capTargetWad;
    /// the rebalancer consumes capTriggerWad as the off-cycle rebalance condition.
    /// Default 30% (a 1.2x gap over the 25% target).
    uint256 public capTriggerWad = 0.3e18;

    /// @notice Minimum weight in WAD below which a constituent is pruned to
    /// zero. Default 0.01%: positions smaller than this cost more in gas and
    /// slippage at rebalance than they contribute to tracking.
    uint256 public floorWad = 1e14;

    event WeightParamsSet(uint256 capTargetWad, uint256 capTriggerWad, uint256 floorWad);

    constructor(AssetRegistry registry, ISupplyOracle supplyOracle, address initialOwner) Ownable(initialOwner) {
        if (address(registry) == address(0) || address(supplyOracle) == address(0)) {
            revert MarketCapMethodology_ZeroAddress();
        }
        REGISTRY = registry;
        SUPPLY_ORACLE = supplyOracle;
    }

    /// @inheritdoc IMethodology
    /// @dev Reverts on any stale price or supply (the registry and supply
    /// oracle both fail closed), so a degraded input can never silently
    /// produce a degraded weighting.
    function getWeights(address[] calldata tokens) external view returns (uint256[] memory) {
        uint256 n = tokens.length;
        uint256[] memory marketCaps = new uint256[](n);
        uint256 total = 0;

        for (uint256 i = 0; i < n; i++) {
            uint256 price = REGISTRY.getPriceUsd(tokens[i]);
            uint256 supply = SUPPLY_ORACLE.getFreeFloatSupply(tokens[i]);
            // Whole-token supply times an 8-decimal price, scaled back down to
            // whole USD so the sanity bound reads in plain dollar terms.
            uint256 marketCap = supply.mulDiv(price, 10 ** REGISTRY.PRICE_DECIMALS(), Math.Rounding.Floor);
            if (marketCap > MARKET_CAP_SANITY_BOUND) {
                revert MarketCapMethodology_MarketCapExceedsSanityBound(tokens[i], marketCap);
            }
            marketCaps[i] = marketCap;
            total += marketCap;
        }
        if (total == 0) revert MarketCapMethodology_InvalidTotalMarketCap();

        uint256[] memory weights = WeightMath.normalize(marketCaps);
        weights = WeightMath.applyCap(weights, capTargetWad);
        return WeightMath.applyFloor(weights, floorWad, capTargetWad);
    }

    /// @notice Sets the cap target, the cap trigger, and the minimum-weight floor.
    /// @dev Methodology-admin lever; sits behind the methodology-admin timelock.
    /// The cap target must be feasible for the constituent set: getWeights reverts
    /// with WeightMath_CapInfeasible when the number of nonzero-market-cap
    /// constituents k satisfies k * capTargetWad < 1e18 (a 25% target needs at
    /// least four viable names). The trigger must sit at or above the target;
    /// equal disables hysteresis (rebalance on any breach of the cap), a wider
    /// gap gives the rebalancer a larger dead-band.
    function setWeightParams(uint256 capTargetWad_, uint256 capTriggerWad_, uint256 floorWad_) external onlyOwner {
        if (
            capTargetWad_ == 0 || capTriggerWad_ > WeightMath.WAD || capTriggerWad_ < capTargetWad_
                || floorWad_ >= capTargetWad_
        ) {
            revert MarketCapMethodology_InvalidParams();
        }
        capTargetWad = capTargetWad_;
        capTriggerWad = capTriggerWad_;
        floorWad = floorWad_;
        emit WeightParamsSet(capTargetWad_, capTriggerWad_, floorWad_);
    }
}
