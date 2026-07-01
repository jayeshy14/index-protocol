// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IndexVault } from "src/IndexVault.sol";
import { AssetRegistry } from "src/AssetRegistry.sol";
import { IMethodology } from "src/interfaces/IMethodology.sol";
import { GPv2Order } from "src/libraries/GPv2Order.sol";

/// @notice The slice of GPv2Settlement the rebalancer reads at construction.
interface IGPv2Settlement {
    function domainSeparator() external view returns (bytes32);
    function vaultRelayer() external view returns (address);
}

// ============================================================================
// Errors
// ============================================================================

error Rebalancer_ZeroAddress();
error Rebalancer_InvalidSlippage();
error Rebalancer_InvalidTriggerParams();
error Rebalancer_NotKeeper(address caller);
error Rebalancer_IntervalNotElapsed(uint256 nextAllowedAt);
error Rebalancer_CadenceNotElapsed(uint256 nextAllowedAt);
error Rebalancer_BelowDriftThreshold(uint256 driftBps, uint256 requiredBps);
error Rebalancer_NoEpoch();
error Rebalancer_NotInEpoch(address token);
error Rebalancer_NotRebalanceLeg();
error Rebalancer_NotSellKind();
error Rebalancer_NonErc20Balance();
error Rebalancer_WrongReceiver(address receiver);
error Rebalancer_NonZeroFee();
error Rebalancer_NotPartiallyFillable();
error Rebalancer_Expired(uint32 validTo);
error Rebalancer_ExceedsDelta(uint256 orderUsd, uint256 deltaUsd);
error Rebalancer_BelowMinOut(uint256 buyAmount, uint256 minOut);

/**
 * @title Rebalancer
 * @notice The rebalance brain: it sizes per-constituent deltas against a frozen
 * target and derives and validates the CoW orders that close them. The vault is
 * the CoW order owner and delegates order validation here, so this contract
 * holds no funds and never moves them; it only decides which orders are
 * legitimate right now.
 *
 * An epoch freezes the target. `openEpoch` snapshots each constituent's target
 * USD value (weight times NAV at open) and the NAV, so orders validate against a
 * fixed target while the vault's NAV continues to read from actual balances
 * (spec 6.3 and 8.3). This removes the target-drift-during-rebalance problem and
 * keeps `validateOrder` cheap: it reads a stored target rather than recomputing
 * the whole methodology on every solver call.
 *
 * Two legs route through USDC: an overweight constituent is sold to USDC, an
 * underweight constituent is bought from USDC. Each leg is bounded two ways: it
 * cannot trade past the constituent's frozen target (no overshoot), and its
 * minimum-out is anchored to the oracle price less a slippage haircut (no bad
 * fill). Epoch opens are governed by a dual-threshold trigger: a scheduled open
 * (keeper, on cadence, past a small drift gate) or a permissionless emergency
 * open (past a large drift threshold), both under an anti-churn floor.
 *
 * Deferred: the buffer-aware target (the snapshot currently targets weight times
 * full NAV, so a rebalance fully deploys rather than leaving the idle buffer)
 * and a full on-chain solver settle on a fork. Both are tracked separately.
 */
contract Rebalancer {
    using Math for uint256;
    using GPv2Order for GPv2Order.Data;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    IndexVault public immutable VAULT;
    IMethodology public immutable METHODOLOGY;
    AssetRegistry public immutable REGISTRY;
    address public immutable USDC;
    uint256 internal immutable USDC_UNIT;

    address public immutable RELAYER;
    bytes32 public immutable DOMAIN_SEPARATOR;
    uint256 public immutable MAX_SLIPPAGE_BPS;

    /// @notice Address allowed to open rebalance epochs.
    address public immutable KEEPER;

    /// @notice Minimum seconds between epoch opens (anti-churn floor).
    uint256 public immutable MIN_INTERVAL;

    /// @notice Scheduled cadence: the keeper may open a scheduled epoch once this
    /// has elapsed since the last open and drift is at least D_SMALL_BPS.
    uint256 public immutable CADENCE;

    /// @notice Drift gate for a scheduled (keeper, on-cadence) epoch, in bps.
    uint256 public immutable D_SMALL_BPS;

    /// @notice Drift threshold for a permissionless emergency epoch, in bps. A
    /// constituent breaching its cap shows up here as drift past the hysteresis
    /// gap, so the cap-trigger case is covered by this threshold.
    uint256 public immutable D_LARGE_BPS;

    // --- Epoch state ---

    uint256 public epochId;
    uint256 public epochOpenedAt;
    uint256 public epochNavUsd;

    /// @dev Frozen target USD value (8 decimals) per constituent for the epoch.
    mapping(address token => uint256) public targetUsd;

    /// @dev Whether a token was a constituent at the current epoch's open.
    mapping(address token => bool) public inEpoch;

    /// @dev Constituents captured at epoch open, for clearing the maps on reopen.
    address[] private _epochConstituents;

    event EpochOpened(uint256 indexed epochId, uint256 navUsd, uint256 constituentCount);

    constructor(
        IndexVault vault,
        IMethodology methodology,
        AssetRegistry registry,
        address usdc,
        address settlement,
        address keeper,
        uint256 maxSlippageBps,
        uint256 minInterval,
        uint256 cadence,
        uint256 dSmallBps,
        uint256 dLargeBps
    ) {
        if (
            address(vault) == address(0) || address(methodology) == address(0) || address(registry) == address(0)
                || usdc == address(0) || settlement == address(0) || keeper == address(0)
        ) {
            revert Rebalancer_ZeroAddress();
        }
        if (maxSlippageBps >= BPS) revert Rebalancer_InvalidSlippage();
        if (dSmallBps > dLargeBps || dLargeBps > BPS || cadence < minInterval) {
            revert Rebalancer_InvalidTriggerParams();
        }

        VAULT = vault;
        METHODOLOGY = methodology;
        REGISTRY = registry;
        USDC = usdc;
        USDC_UNIT = 10 ** IERC20Like(usdc).decimals();
        RELAYER = IGPv2Settlement(settlement).vaultRelayer();
        DOMAIN_SEPARATOR = IGPv2Settlement(settlement).domainSeparator();
        KEEPER = keeper;
        MAX_SLIPPAGE_BPS = maxSlippageBps;
        MIN_INTERVAL = minInterval;
        CADENCE = cadence;
        D_SMALL_BPS = dSmallBps;
        D_LARGE_BPS = dLargeBps;
    }

    // ========================================================================
    // Epoch
    // ========================================================================

    /// @notice Opens a rebalance epoch, freezing each constituent's target USD
    /// value at weight times NAV. Two triggers under one anti-churn floor: a
    /// scheduled open (keeper, once the cadence has elapsed and drift is at least
    /// the small gate) or a permissionless emergency open (drift at least the
    /// large threshold). Nothing reopens within MIN_INTERVAL of the last open.
    function openEpoch() external {
        if (epochId != 0 && block.timestamp < epochOpenedAt + MIN_INTERVAL) {
            revert Rebalancer_IntervalNotElapsed(epochOpenedAt + MIN_INTERVAL);
        }

        uint256 drift = maxDriftBps();
        // A redemption the buffer cannot cover is a first-class trigger: the
        // keeper may open an epoch to free USDC from the basket regardless of
        // drift or cadence, because redemption liveness cannot wait for the
        // reweight schedule (Section 3). The min-interval floor still applies.
        bool fundingNeeded = VAULT.redemptionFundingNeeded();
        if (drift < D_LARGE_BPS && !fundingNeeded) {
            // Not an emergency and no funding need: scheduled reweight path,
            // keeper plus cadence plus small gate.
            if (msg.sender != KEEPER) revert Rebalancer_NotKeeper(msg.sender);
            if (epochId != 0 && block.timestamp < epochOpenedAt + CADENCE) {
                revert Rebalancer_CadenceNotElapsed(epochOpenedAt + CADENCE);
            }
            if (drift < D_SMALL_BPS) revert Rebalancer_BelowDriftThreshold(drift, D_SMALL_BPS);
        } else if (fundingNeeded && drift < D_LARGE_BPS) {
            // Funding open below the emergency band is keeper-gated.
            if (msg.sender != KEEPER) revert Rebalancer_NotKeeper(msg.sender);
        }

        // Clear the previous snapshot.
        address[] memory prev = _epochConstituents;
        for (uint256 i = 0; i < prev.length; i++) {
            delete targetUsd[prev[i]];
            delete inEpoch[prev[i]];
        }
        delete _epochConstituents;

        // Snapshot the new target over the FRESH constituents only. A quarantined
        // (stale-feed) constituent cannot be priced, so the methodology cannot
        // weight it and the rebalancer cannot anchor a minimum-out to sell it
        // (Section 16.5). It is excluded from the epoch entirely, neither bought
        // nor sold, and held marked-down (Section 4) until its feed recovers; the
        // healthy names rebalance around it instead of the whole epoch halting.
        address[] memory fresh = _freshSubset(VAULT.getConstituents());
        uint256[] memory weights = METHODOLOGY.getWeights(fresh);
        (,, uint256 navUsd) = VAULT.getHoldings();

        // Hold back a USDC reserve for pending redemptions the buffer cannot
        // cover, then weight the constituents over the deployable remainder. This
        // makes the basket overweight relative to its targets, so it is sold to
        // USDC and the redemption is funded before settle pays it (Section 3).
        uint256 reserveUsd = VAULT.rebalanceReserveUsd();
        if (reserveUsd > 0) {
            // Selling the basket nets only (1 - slippage) of oracle value, so
            // gross the reserve up by the max slippage; otherwise the USDC raised
            // would fall a haircut short of the redemption it must fund.
            reserveUsd = reserveUsd.mulDiv(BPS, BPS - MAX_SLIPPAGE_BPS, Math.Rounding.Ceil);
        }
        uint256 deployableNav = navUsd > reserveUsd ? navUsd - reserveUsd : 0;

        for (uint256 i = 0; i < fresh.length; i++) {
            address token = fresh[i];
            // A constituent marked for wind-down targets zero, so the whole
            // position becomes overweight and is sold to USDC at the
            // oracle-anchored minimum-out (Section 16.5, wind-down not dump).
            uint256 target = VAULT.windingDown(token) ? 0 : deployableNav.mulDiv(weights[i], WAD, Math.Rounding.Floor);
            targetUsd[token] = target;
            inEpoch[token] = true;
            _epochConstituents.push(token);
        }

        epochNavUsd = navUsd;
        epochOpenedAt = block.timestamp;
        unchecked {
            epochId++;
        }

        emit EpochOpened(epochId, navUsd, fresh.length);
    }

    // ========================================================================
    // Trigger policy
    // ========================================================================

    /// @notice The largest absolute deviation of any constituent's actual weight
    /// (of NAV) from its live methodology target, in bps. This is the drift the
    /// trigger thresholds gate on. It reads the live target, not the frozen one,
    /// because the trigger decides whether to open an epoch in the first place.
    function maxDriftBps() public view returns (uint256 maxBps) {
        address[] memory cons = VAULT.getConstituents();
        if (cons.length == 0) return 0;

        // Weight over the fresh subset only, so a single stale feed does not
        // revert the drift read (and therefore the trigger). Quarantined names
        // are skipped: they are held, not rebalanced.
        address[] memory fresh = _freshSubset(cons);
        if (fresh.length == 0) return 0;
        uint256[] memory weights = METHODOLOGY.getWeights(fresh);
        (IndexVault.Holding[] memory holdings,, uint256 navUsd) = VAULT.getHoldings();
        if (navUsd == 0) return 0;

        // `holdings` is parallel to the full constituent list; `weights` is over
        // the fresh subset in the same order, so a fresh-index cursor keeps them
        // aligned as the loop skips quarantined names.
        uint256 fi = 0;
        for (uint256 i = 0; i < cons.length; i++) {
            if (VAULT.isQuarantined(cons[i])) continue;
            // A winding-down constituent targets zero, so its full held weight
            // reads as drift and pulls the index toward opening an exit epoch.
            uint256 targetBps = VAULT.windingDown(cons[i]) ? 0 : weights[fi].mulDiv(BPS, WAD, Math.Rounding.Floor);
            uint256 actualBps = holdings[i].weightBps;
            uint256 d = actualBps > targetBps ? actualBps - targetBps : targetBps - actualBps;
            if (d > maxBps) maxBps = d;
            unchecked {
                fi++;
            }
        }
    }

    // ========================================================================
    // Deltas
    // ========================================================================

    /// @notice Current USD value (8 decimals) of the vault's balance of `token`.
    function currentUsd(address token) public view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(VAULT));
        if (balance == 0) return 0;
        uint256 price = REGISTRY.getPriceUsd(token);
        uint8 dec = REGISTRY.getAsset(token).tokenDecimals;
        return balance.mulDiv(price, 10 ** dec, Math.Rounding.Floor);
    }

    /// @notice USD the constituent is over its frozen target (the sell budget).
    function overweightUsd(address token) public view returns (uint256) {
        uint256 cur = currentUsd(token);
        uint256 tgt = targetUsd[token];
        return cur > tgt ? cur - tgt : 0;
    }

    /// @notice USD the constituent is under its frozen target (the buy budget).
    function underweightUsd(address token) public view returns (uint256) {
        uint256 cur = currentUsd(token);
        uint256 tgt = targetUsd[token];
        return tgt > cur ? tgt - cur : 0;
    }

    // ========================================================================
    // Order derivation
    // ========================================================================

    /// @notice The sell-to-USDC order for an overweight constituent.
    function buildSellOrder(address sellToken, uint256 sellAmount, uint32 validTo, bytes32 appData)
        external
        view
        returns (GPv2Order.Data memory order)
    {
        order = _baseOrder(sellToken, USDC, sellAmount, sellMinOut(sellToken, sellAmount), validTo, appData);
    }

    /// @notice The buy-from-USDC order for an underweight constituent.
    function buildBuyOrder(address buyToken, uint256 usdcAmount, uint32 validTo, bytes32 appData)
        external
        view
        returns (GPv2Order.Data memory order)
    {
        order = _baseOrder(USDC, buyToken, usdcAmount, buyMinOut(buyToken, usdcAmount), validTo, appData);
    }

    /// @notice Minimum USDC out for selling `sellAmount` of `sellToken`.
    function sellMinOut(address sellToken, uint256 sellAmount) public view returns (uint256) {
        uint256 price = REGISTRY.getPriceUsd(sellToken);
        uint256 usdcPrice = REGISTRY.getUsdcPriceUsd();
        uint8 dec = REGISTRY.getAsset(sellToken).tokenDecimals;
        uint256 usdValue = sellAmount.mulDiv(price, 10 ** dec, Math.Rounding.Floor);
        uint256 usdcOut = usdValue.mulDiv(USDC_UNIT, usdcPrice, Math.Rounding.Floor);
        return usdcOut.mulDiv(BPS - MAX_SLIPPAGE_BPS, BPS, Math.Rounding.Floor);
    }

    /// @notice Minimum `buyToken` out for spending `usdcAmount` of USDC.
    function buyMinOut(address buyToken, uint256 usdcAmount) public view returns (uint256) {
        uint256 price = REGISTRY.getPriceUsd(buyToken);
        uint256 usdcPrice = REGISTRY.getUsdcPriceUsd();
        uint8 dec = REGISTRY.getAsset(buyToken).tokenDecimals;
        uint256 usdValue = usdcAmount.mulDiv(usdcPrice, USDC_UNIT, Math.Rounding.Floor);
        uint256 tokensOut = usdValue.mulDiv(10 ** dec, price, Math.Rounding.Floor);
        return tokensOut.mulDiv(BPS - MAX_SLIPPAGE_BPS, BPS, Math.Rounding.Floor);
    }

    /// @dev The digest of an order under this rebalancer's domain separator.
    function orderDigest(GPv2Order.Data memory order) external view returns (bytes32) {
        return order.hash(DOMAIN_SEPARATOR);
    }

    // ========================================================================
    // Order validation (the vault's isValidSignature delegates here)
    // ========================================================================

    /// @notice Reverts unless `order` is a legitimate rebalance leg for the open
    /// epoch: a sell of an overweight constituent to USDC, or a buy of an
    /// underweight constituent from USDC, paid to the vault, sized within the
    /// constituent's frozen delta, at or above the oracle-anchored minimum-out.
    function validateOrder(GPv2Order.Data memory order) public view {
        if (epochId == 0) revert Rebalancer_NoEpoch();

        // Common order shape.
        if (order.kind != GPv2Order.KIND_SELL) revert Rebalancer_NotSellKind();
        if (order.sellTokenBalance != GPv2Order.BALANCE_ERC20 || order.buyTokenBalance != GPv2Order.BALANCE_ERC20) {
            revert Rebalancer_NonErc20Balance();
        }
        if (order.receiver != address(VAULT)) revert Rebalancer_WrongReceiver(order.receiver);
        if (order.feeAmount != 0) revert Rebalancer_NonZeroFee();
        if (!order.partiallyFillable) revert Rebalancer_NotPartiallyFillable();
        if (order.validTo < block.timestamp) revert Rebalancer_Expired(order.validTo);

        if (order.buyToken == USDC) {
            // Sell leg: overweight constituent -> USDC.
            address token = order.sellToken;
            if (!inEpoch[token]) revert Rebalancer_NotInEpoch(token);

            uint256 sellUsd = currentUsdOfAmount(token, order.sellAmount);
            uint256 budget = overweightUsd(token);
            if (sellUsd > budget) revert Rebalancer_ExceedsDelta(sellUsd, budget);

            uint256 required = sellMinOut(token, order.sellAmount);
            if (order.buyAmount < required) revert Rebalancer_BelowMinOut(order.buyAmount, required);
        } else if (order.sellToken == USDC) {
            // Buy leg: USDC -> underweight constituent.
            address token = order.buyToken;
            if (!inEpoch[token]) revert Rebalancer_NotInEpoch(token);

            uint256 buyUsd = order.sellAmount.mulDiv(REGISTRY.getUsdcPriceUsd(), USDC_UNIT, Math.Rounding.Floor);
            uint256 budget = underweightUsd(token);
            if (buyUsd > budget) revert Rebalancer_ExceedsDelta(buyUsd, budget);

            uint256 required = buyMinOut(token, order.sellAmount);
            if (order.buyAmount < required) revert Rebalancer_BelowMinOut(order.buyAmount, required);
        } else {
            revert Rebalancer_NotRebalanceLeg();
        }
    }

    /// @notice USD value (8 decimals) of `amount` native units of `token`.
    function currentUsdOfAmount(address token, uint256 amount) public view returns (uint256) {
        uint256 price = REGISTRY.getPriceUsd(token);
        uint8 dec = REGISTRY.getAsset(token).tokenDecimals;
        return amount.mulDiv(price, 10 ** dec, Math.Rounding.Floor);
    }

    // ========================================================================
    // Internal
    // ========================================================================

    /// @dev The constituents whose feeds are fresh (not quarantined), in the same
    /// order as `cons`. Weighting and rebalancing operate over this subset so a
    /// single stale feed does not halt the whole epoch.
    function _freshSubset(address[] memory cons) internal view returns (address[] memory fresh) {
        uint256 n = 0;
        for (uint256 i = 0; i < cons.length; i++) {
            if (!VAULT.isQuarantined(cons[i])) n++;
        }
        fresh = new address[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < cons.length; i++) {
            if (!VAULT.isQuarantined(cons[i])) {
                fresh[j] = cons[i];
                unchecked {
                    j++;
                }
            }
        }
    }

    function _baseOrder(
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    ) internal view returns (GPv2Order.Data memory) {
        return GPv2Order.Data({
            sellToken: sellToken,
            buyToken: buyToken,
            receiver: address(VAULT),
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            validTo: validTo,
            appData: appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: true,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }
}

/// @dev Minimal decimals view to size the USDC unit at construction.
interface IERC20Like {
    function decimals() external view returns (uint8);
}
