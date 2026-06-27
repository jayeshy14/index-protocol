// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Chainlink aggregator surface the registry consumes.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

// ============================================================================
// Errors
// ============================================================================

/// @notice Thrown when a constructor or setter receives the zero address.
error AssetRegistry_ZeroAddress();

/// @notice Thrown when registering an asset that is already registered.
error AssetRegistry_AlreadyRegistered(address token);

/// @notice Thrown when querying or removing an asset that is not registered.
error AssetRegistry_NotRegistered(address token);

/// @notice Thrown when registering beyond the catalog cap.
error AssetRegistry_MaxAssetsReached();

/// @notice Thrown when a heartbeat of zero is supplied.
error AssetRegistry_ZeroHeartbeat();

/// @notice Thrown when a feed reports a non-positive answer.
error AssetRegistry_InvalidPrice(address feed, int256 answer);

/// @notice Thrown when a feed has not updated within its heartbeat.
error AssetRegistry_StalePrice(address feed, uint256 updatedAt, uint256 heartbeat);

/// @notice Thrown when the USDC feed has not been configured.
error AssetRegistry_UsdcFeedNotSet();

/**
 * @title AssetRegistry
 * @notice Shared global catalog of registerable assets and their Chainlink USD
 * price feeds. This is the eligible universe an index can draw from; it is not
 * itself an index. A token is registered here once, and any index vault may
 * then include it in its own curated constituent set. Membership lives in the
 * vault, asset metadata lives here.
 *
 * Each asset carries a per-feed heartbeat rather than a single global staleness
 * bound, and every price read is health-checked: a stale or non-positive answer
 * reverts so that price-sensitive vault operations (mint, settle, rebalance)
 * fail closed instead of transacting on bad data.
 * @dev Prices are normalized to 8 decimals regardless of feed decimals.
 * Supply-oracle source bindings can be attached per asset later.
 */
contract AssetRegistry is Ownable2Step {
    struct Asset {
        address token;
        address feed;
        uint48 heartbeat;
        uint8 tokenDecimals;
        uint8 feedDecimals;
    }

    /// @notice Normalized price precision for all reads (Chainlink USD standard).
    uint8 public constant PRICE_DECIMALS = 8;

    /// @notice Cap on the catalog size, distinct from any one index's size cap.
    /// An index picks a subset of the catalog and applies its own size cap.
    uint256 public constant MAX_ASSETS = 250;

    /// @dev Registered assets in registration order.
    address[] private _assetList;

    /// @dev Asset data keyed by token address.
    mapping(address token => Asset) private _assets;

    /// @dev USDC is the settlement asset, priced through its own feed, never a basket constituent.
    Asset private _usdc;

    event AssetRegistered(address indexed token, address indexed feed, uint48 heartbeat);
    event AssetRemoved(address indexed token);
    event UsdcFeedSet(address indexed usdc, address indexed feed, uint48 heartbeat);

    constructor(address initialOwner) Ownable(initialOwner) { }

    // ========================================================================
    // Admin
    // ========================================================================

    /// @notice Registers an asset with its Chainlink USD feed, adding it to the catalog.
    /// @param token The ERC-20 asset address.
    /// @param feed The Chainlink aggregator for the token's USD price.
    /// @param heartbeat Maximum tolerated seconds since the feed's last update.
    function registerAsset(address token, address feed, uint48 heartbeat) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert AssetRegistry_ZeroAddress();
        if (heartbeat == 0) revert AssetRegistry_ZeroHeartbeat();
        if (_assets[token].token != address(0)) revert AssetRegistry_AlreadyRegistered(token);
        if (_assetList.length >= MAX_ASSETS) revert AssetRegistry_MaxAssetsReached();

        _assets[token] = Asset({
            token: token,
            feed: feed,
            heartbeat: heartbeat,
            tokenDecimals: IERC20Metadata(token).decimals(),
            feedDecimals: IAggregatorV3(feed).decimals()
        });
        _assetList.push(token);

        emit AssetRegistered(token, feed, heartbeat);
    }

    /// @notice Removes an asset from the catalog.
    /// @dev An index vault may still list a removed asset as a constituent; the
    /// vault's own constituent governance handles forced exit of the position.
    /// Removal here only stops the asset being newly includable and priced.
    function removeAsset(address token) external onlyOwner {
        if (_assets[token].token == address(0)) revert AssetRegistry_NotRegistered(token);

        uint256 len = _assetList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_assetList[i] == token) {
                _assetList[i] = _assetList[len - 1];
                _assetList.pop();
                break;
            }
        }
        delete _assets[token];

        emit AssetRemoved(token);
    }

    /// @notice Configures the settlement-asset (USDC) price feed.
    function setUsdcFeed(address usdc, address feed, uint48 heartbeat) external onlyOwner {
        if (usdc == address(0) || feed == address(0)) revert AssetRegistry_ZeroAddress();
        if (heartbeat == 0) revert AssetRegistry_ZeroHeartbeat();

        _usdc = Asset({
            token: usdc,
            feed: feed,
            heartbeat: heartbeat,
            tokenDecimals: IERC20Metadata(usdc).decimals(),
            feedDecimals: IAggregatorV3(feed).decimals()
        });

        emit UsdcFeedSet(usdc, feed, heartbeat);
    }

    // ========================================================================
    // Views
    // ========================================================================

    /// @notice Returns the entire catalog of registered assets.
    function getAssets() external view returns (Asset[] memory assets) {
        uint256 len = _assetList.length;
        assets = new Asset[](len);
        for (uint256 i = 0; i < len; i++) {
            assets[i] = _assets[_assetList[i]];
        }
    }

    /// @notice Returns a single asset record.
    function getAsset(address token) external view returns (Asset memory) {
        Asset memory a = _assets[token];
        if (a.token == address(0)) revert AssetRegistry_NotRegistered(token);
        return a;
    }

    /// @notice Number of registered assets in the catalog.
    function assetCount() external view returns (uint256) {
        return _assetList.length;
    }

    /// @notice Whether `token` is a registered asset.
    function isRegistered(address token) external view returns (bool) {
        return _assets[token].token != address(0);
    }

    /// @notice Health-checked USD price of a registered asset, normalized to 8 decimals.
    function getPriceUsd(address token) external view returns (uint256) {
        Asset memory a = _assets[token];
        if (a.token == address(0)) revert AssetRegistry_NotRegistered(token);
        return _readFeed(a);
    }

    /// @notice Health-checked USD price of the settlement asset, normalized to 8 decimals.
    function getUsdcPriceUsd() external view returns (uint256) {
        Asset memory a = _usdc;
        if (a.token == address(0)) revert AssetRegistry_UsdcFeedNotSet();
        return _readFeed(a);
    }

    /// @notice Non-reverting price read for the vault's quarantine path: returns
    /// the feed's last answer (8 decimals), its `updatedAt`, and whether it is
    /// fresh. A stale feed still surfaces its last-good answer here rather than
    /// reverting, so the vault can value the constituent conservatively instead
    /// of halting NAV. A non-positive answer reports price zero and not fresh.
    function getPriceUsdStatus(address token) external view returns (uint256 price, uint256 updatedAt, bool fresh) {
        Asset memory a = _assets[token];
        if (a.token == address(0)) revert AssetRegistry_NotRegistered(token);
        return _readFeedStatus(a);
    }

    // ========================================================================
    // Internal
    // ========================================================================

    /// @dev Reads a feed, enforces answer and staleness health, normalizes to 8 decimals.
    function _readFeed(Asset memory a) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(a.feed).latestRoundData();
        if (answer <= 0) revert AssetRegistry_InvalidPrice(a.feed, answer);
        if (block.timestamp > updatedAt + a.heartbeat) {
            revert AssetRegistry_StalePrice(a.feed, updatedAt, a.heartbeat);
        }
        return _normalizePrice(uint256(answer), a.feedDecimals);
    }

    /// @dev Non-reverting feed read: normalizes the last answer and reports
    /// freshness. A non-positive answer yields price zero and fresh false.
    function _readFeedStatus(Asset memory a) internal view returns (uint256 price, uint256 updatedAt, bool fresh) {
        int256 answer;
        (, answer,, updatedAt,) = IAggregatorV3(a.feed).latestRoundData();
        if (answer <= 0) return (0, updatedAt, false);
        price = _normalizePrice(uint256(answer), a.feedDecimals);
        fresh = block.timestamp <= updatedAt + a.heartbeat;
    }

    /// @dev Normalizes a raw feed answer to the registry's 8-decimal convention.
    function _normalizePrice(uint256 raw, uint8 feedDecimals) private pure returns (uint256) {
        if (feedDecimals == PRICE_DECIMALS) return raw;
        if (feedDecimals < PRICE_DECIMALS) return raw * 10 ** (PRICE_DECIMALS - feedDecimals);
        return raw / 10 ** (feedDecimals - PRICE_DECIMALS);
    }
}
