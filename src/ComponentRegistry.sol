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
error ComponentRegistry_ZeroAddress();

/// @notice Thrown when registering a component that is already registered.
error ComponentRegistry_AlreadyRegistered(address token);

/// @notice Thrown when querying or removing a component that is not registered.
error ComponentRegistry_NotRegistered(address token);

/// @notice Thrown when registering beyond the component cap.
error ComponentRegistry_MaxComponentsReached();

/// @notice Thrown when a heartbeat of zero is supplied.
error ComponentRegistry_ZeroHeartbeat();

/// @notice Thrown when a feed reports a non-positive answer.
error ComponentRegistry_InvalidPrice(address feed, int256 answer);

/// @notice Thrown when a feed has not updated within its heartbeat.
error ComponentRegistry_StalePrice(address feed, uint256 updatedAt, uint256 heartbeat);

/// @notice Thrown when the USDC feed has not been configured.
error ComponentRegistry_UsdcFeedNotSet();

/**
 * @title ComponentRegistry
 * @notice Registry of index constituents and their Chainlink USD price feeds.
 * Each component carries a per-feed heartbeat rather than a single global
 * staleness bound, and every price read is health-checked: a stale or
 * non-positive answer reverts so that price-sensitive vault operations
 * (mint, settle, rebalance) fail closed instead of transacting on bad data.
 * @dev Prices are normalized to 8 decimals regardless of feed decimals.
 * Supply-oracle bindings and reconstitution metadata land here later.
 */
contract ComponentRegistry is Ownable2Step {
    struct Component {
        address token;
        address feed;
        uint48 heartbeat;
        uint8 tokenDecimals;
        uint8 feedDecimals;
    }

    /// @notice Normalized price precision for all reads (Chainlink USD standard).
    uint8 public constant PRICE_DECIMALS = 8;

    /// @notice Operational cap on constituent count, sized for the index-100 target.
    uint256 public constant MAX_COMPONENTS = 100;

    /// @dev Registered basket constituents in registration order.
    address[] private _componentList;

    /// @dev Component data keyed by token address.
    mapping(address token => Component) private _components;

    /// @dev USDC is the settlement asset, priced through its own feed, never a basket constituent.
    Component private _usdc;

    event ComponentRegistered(address indexed token, address indexed feed, uint48 heartbeat);
    event ComponentRemoved(address indexed token);
    event UsdcFeedSet(address indexed usdc, address indexed feed, uint48 heartbeat);

    constructor(address initialOwner) Ownable(initialOwner) { }

    // ========================================================================
    // Admin
    // ========================================================================

    /// @notice Registers a basket constituent with its Chainlink USD feed.
    /// @param token The ERC-20 constituent address.
    /// @param feed The Chainlink aggregator for the token's USD price.
    /// @param heartbeat Maximum tolerated seconds since the feed's last update.
    function registerComponent(address token, address feed, uint48 heartbeat) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert ComponentRegistry_ZeroAddress();
        if (heartbeat == 0) revert ComponentRegistry_ZeroHeartbeat();
        if (_components[token].token != address(0)) revert ComponentRegistry_AlreadyRegistered(token);
        if (_componentList.length >= MAX_COMPONENTS) revert ComponentRegistry_MaxComponentsReached();

        _components[token] = Component({
            token: token,
            feed: feed,
            heartbeat: heartbeat,
            tokenDecimals: IERC20Metadata(token).decimals(),
            feedDecimals: IAggregatorV3(feed).decimals()
        });
        _componentList.push(token);

        emit ComponentRegistered(token, feed, heartbeat);
    }

    /// @notice Removes a constituent from the registry.
    /// @dev The vault may still hold a balance of a removed token; removal only
    /// stops it being valued and traded. Deregistration policy (forced exit of
    /// the position first) is enforced at the rebalancer layer.
    function removeComponent(address token) external onlyOwner {
        if (_components[token].token == address(0)) revert ComponentRegistry_NotRegistered(token);

        uint256 len = _componentList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_componentList[i] == token) {
                _componentList[i] = _componentList[len - 1];
                _componentList.pop();
                break;
            }
        }
        delete _components[token];

        emit ComponentRemoved(token);
    }

    /// @notice Configures the settlement-asset (USDC) price feed.
    function setUsdcFeed(address usdc, address feed, uint48 heartbeat) external onlyOwner {
        if (usdc == address(0) || feed == address(0)) revert ComponentRegistry_ZeroAddress();
        if (heartbeat == 0) revert ComponentRegistry_ZeroHeartbeat();

        _usdc = Component({
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

    /// @notice Returns all registered constituents with cached decimals, for the vault's NAV loop.
    function getComponents() external view returns (Component[] memory components) {
        uint256 len = _componentList.length;
        components = new Component[](len);
        for (uint256 i = 0; i < len; i++) {
            components[i] = _components[_componentList[i]];
        }
    }

    /// @notice Returns a single component record.
    function getComponent(address token) external view returns (Component memory) {
        Component memory c = _components[token];
        if (c.token == address(0)) revert ComponentRegistry_NotRegistered(token);
        return c;
    }

    /// @notice Number of registered constituents.
    function componentCount() external view returns (uint256) {
        return _componentList.length;
    }

    /// @notice Whether `token` is a registered basket constituent.
    function isRegistered(address token) external view returns (bool) {
        return _components[token].token != address(0);
    }

    /// @notice Health-checked USD price of a registered constituent, normalized to 8 decimals.
    function getPriceUsd(address token) external view returns (uint256) {
        Component memory c = _components[token];
        if (c.token == address(0)) revert ComponentRegistry_NotRegistered(token);
        return _readFeed(c);
    }

    /// @notice Health-checked USD price of the settlement asset, normalized to 8 decimals.
    function getUsdcPriceUsd() external view returns (uint256) {
        Component memory c = _usdc;
        if (c.token == address(0)) revert ComponentRegistry_UsdcFeedNotSet();
        return _readFeed(c);
    }

    // ========================================================================
    // Internal
    // ========================================================================

    /// @dev Reads a feed, enforces answer and staleness health, normalizes to 8 decimals.
    function _readFeed(Component memory c) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(c.feed).latestRoundData();
        if (answer <= 0) revert ComponentRegistry_InvalidPrice(c.feed, answer);
        if (block.timestamp > updatedAt + c.heartbeat) {
            revert ComponentRegistry_StalePrice(c.feed, updatedAt, c.heartbeat);
        }

        uint256 price = uint256(answer);
        if (c.feedDecimals == PRICE_DECIMALS) return price;
        if (c.feedDecimals < PRICE_DECIMALS) return price * 10 ** (PRICE_DECIMALS - c.feedDecimals);
        return price / 10 ** (c.feedDecimals - PRICE_DECIMALS);
    }
}
