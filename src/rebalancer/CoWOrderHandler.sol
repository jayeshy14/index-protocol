// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { AssetRegistry } from "src/AssetRegistry.sol";
import { GPv2Order } from "src/libraries/GPv2Order.sol";

/// @notice The slice of GPv2Settlement this handler reads.
interface IGPv2Settlement {
    function domainSeparator() external view returns (bytes32);
    function vaultRelayer() external view returns (address);
}

// ============================================================================
// Errors
// ============================================================================

error CoWHandler_ZeroAddress();
error CoWHandler_DigestMismatch(bytes32 expected, bytes32 presented);
error CoWHandler_NotSellKind();
error CoWHandler_WrongBuyToken(address buyToken);
error CoWHandler_WrongReceiver(address receiver);
error CoWHandler_NonZeroFee();
error CoWHandler_NotPartiallyFillable();
error CoWHandler_Expired(uint32 validTo);
error CoWHandler_SellTokenNotRegistered(address sellToken);
error CoWHandler_NonErc20Balance();
error CoWHandler_BelowMinOut(uint256 buyAmount, uint256 minOut);
error CoWHandler_InvalidSlippage();

/**
 * @title CoWOrderHandler (Stage 3 spike)
 * @notice Proof-of-concept that the protocol can be a first-class CoW trader.
 * It implements ERC-1271 `isValidSignature` so the real GPv2Settlement accepts
 * orders it has not pre-signed, validating each presented order against
 * on-chain state rather than a fixed instruction: the order must be a sell of a
 * registered constituent into USDC, paid to the vault, with a buy amount at or
 * above an oracle-anchored minimum-out. This isolates and de-risks the CoW
 * integration mechanics (EIP-712 digest, the magic-value flow, the relayer
 * approval, oracle-bounded execution) ahead of the full rebalancer.
 *
 * Scope of the spike: only the overweight-sell leg (constituent to USDC), no
 * delta sizing, no epoch lifecycle, no partial-fill NAV reconciliation, and the
 * handler itself holds the sell tokens and approves the relayer. In the real
 * integration this logic is the vault's (or delegated by it), so the order
 * owner, the token holder, and the validator are one address.
 */
contract CoWOrderHandler {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using GPv2Order for GPv2Order.Data;

    /// @dev ERC-1271 magic value: bytes4(keccak256("isValidSignature(bytes32,bytes)")).
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    uint256 internal constant BPS = 10_000;

    /// @notice Address that receives sale proceeds (the vault).
    address public immutable VAULT;

    /// @notice Shared asset catalog used for oracle prices.
    AssetRegistry public immutable REGISTRY;

    /// @notice Settlement asset (USDC) and its whole unit.
    address public immutable USDC;
    uint256 internal immutable USDC_UNIT;

    /// @notice CoW settlement and its relayer (the puller of sell tokens).
    IGPv2Settlement public immutable SETTLEMENT;
    address public immutable RELAYER;

    /// @notice Domain separator read from the settlement at construction, so the
    /// handler reconstructs the exact digest the settlement verifies against.
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice Maximum tolerated slippage below the oracle price, in bps.
    uint256 public immutable MAX_SLIPPAGE_BPS;

    constructor(address vault, AssetRegistry registry, address usdc, address settlement, uint256 maxSlippageBps) {
        if (vault == address(0) || address(registry) == address(0) || usdc == address(0) || settlement == address(0)) {
            revert CoWHandler_ZeroAddress();
        }
        if (maxSlippageBps >= BPS) revert CoWHandler_InvalidSlippage();
        VAULT = vault;
        REGISTRY = registry;
        USDC = usdc;
        USDC_UNIT = 10 ** IERC20Metadata(usdc).decimals();
        SETTLEMENT = IGPv2Settlement(settlement);
        RELAYER = IGPv2Settlement(settlement).vaultRelayer();
        DOMAIN_SEPARATOR = IGPv2Settlement(settlement).domainSeparator();
        MAX_SLIPPAGE_BPS = maxSlippageBps;
    }

    // ========================================================================
    // ERC-1271
    // ========================================================================

    /// @notice Validates a CoW order presented by a solver during settlement.
    /// @param digest The order digest the settlement computed for the trade.
    /// @param signature The ABI-encoded `GPv2Order.Data` for that trade.
    /// @return The ERC-1271 magic value if the order is one the handler authorizes.
    /// @dev The digest is rebound to the decoded order, so a solver cannot pair
    /// a digest for order A with the encoding of a different, valid order B.
    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        GPv2Order.Data memory order = abi.decode(signature, (GPv2Order.Data));

        bytes32 expected = order.hash(DOMAIN_SEPARATOR);
        if (expected != digest) revert CoWHandler_DigestMismatch(expected, digest);

        _validateSellOrder(order);
        return MAGICVALUE;
    }

    // ========================================================================
    // Order derivation and validation
    // ========================================================================

    /// @notice Builds the canonical sell-to-USDC order the handler will accept
    /// for `sellAmount` of `sellToken`, for a solver to discover and fill. This
    /// is the spike's analog of a Composable CoW `getTradeableOrder`.
    function buildSellOrder(address sellToken, uint256 sellAmount, uint32 validTo, bytes32 appData)
        external
        view
        returns (GPv2Order.Data memory order)
    {
        order = GPv2Order.Data({
            sellToken: sellToken,
            buyToken: USDC,
            receiver: VAULT,
            sellAmount: sellAmount,
            buyAmount: minOut(sellToken, sellAmount),
            validTo: validTo,
            appData: appData,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: true,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    /// @notice Oracle-anchored minimum USDC out for selling `sellAmount` of
    /// `sellToken`: the oracle USD value converted to USDC, less the slippage
    /// haircut. A solver cannot fill below this.
    function minOut(address sellToken, uint256 sellAmount) public view returns (uint256) {
        uint256 price = REGISTRY.getPriceUsd(sellToken); // 8-decimal USD
        uint256 usdcPrice = REGISTRY.getUsdcPriceUsd(); // 8-decimal USD
        uint8 sellDecimals = REGISTRY.getAsset(sellToken).tokenDecimals;

        // sellAmount (native) -> 8-decimal USD -> USDC native units.
        uint256 usdValue = sellAmount.mulDiv(price, 10 ** sellDecimals, Math.Rounding.Floor);
        uint256 usdcOut = usdValue.mulDiv(USDC_UNIT, usdcPrice, Math.Rounding.Floor);
        return usdcOut.mulDiv(BPS - MAX_SLIPPAGE_BPS, BPS, Math.Rounding.Floor);
    }

    /// @dev The digest of an order under this handler's domain separator.
    function orderDigest(GPv2Order.Data memory order) external view returns (bytes32) {
        return order.hash(DOMAIN_SEPARATOR);
    }

    /// @notice Approves the relayer to pull `token` for selling. Permissionless:
    /// it only enables selling, and every sale is bounded by order validation.
    function approveSell(address token) external {
        IERC20(token).forceApprove(RELAYER, type(uint256).max);
    }

    function _validateSellOrder(GPv2Order.Data memory order) internal view {
        if (order.kind != GPv2Order.KIND_SELL) revert CoWHandler_NotSellKind();
        if (order.sellTokenBalance != GPv2Order.BALANCE_ERC20 || order.buyTokenBalance != GPv2Order.BALANCE_ERC20) {
            revert CoWHandler_NonErc20Balance();
        }
        if (order.buyToken != USDC) revert CoWHandler_WrongBuyToken(order.buyToken);
        if (order.receiver != VAULT) revert CoWHandler_WrongReceiver(order.receiver);
        if (order.feeAmount != 0) revert CoWHandler_NonZeroFee();
        if (!order.partiallyFillable) revert CoWHandler_NotPartiallyFillable();
        if (order.validTo < block.timestamp) revert CoWHandler_Expired(order.validTo);
        if (!REGISTRY.isRegistered(order.sellToken)) revert CoWHandler_SellTokenNotRegistered(order.sellToken);

        uint256 required = minOut(order.sellToken, order.sellAmount);
        if (order.buyAmount < required) revert CoWHandler_BelowMinOut(order.buyAmount, required);
    }
}
