// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { AssetRegistry } from "src/AssetRegistry.sol";
import { PendingSilo } from "src/PendingSilo.sol";
import { IERC7540 } from "src/interfaces/IERC7540.sol";
import { IRebalancer } from "src/interfaces/IRebalancer.sol";
import { GPv2Order } from "src/libraries/GPv2Order.sol";

/// @notice The slice of GPv2Settlement the vault reads when wiring CoW.
interface ICoWSettlement {
    function domainSeparator() external view returns (bytes32);
    function vaultRelayer() external view returns (address);
}

// ============================================================================
// Errors
// ============================================================================

/// @notice Thrown when a constructor argument is the zero address.
error IndexVault_ZeroAddress();

/// @notice Thrown when a zero amount is supplied where a positive amount is required.
error IndexVault_ZeroAmount();

/// @notice Thrown when the caller is neither the controller nor an approved operator.
error IndexVault_NotAuthorized(address controller, address sender);

/// @notice Thrown when settle is called by a non-keeper before the staleness backstop elapses.
error IndexVault_NotKeeper(address sender);

/// @notice Thrown when settle is called before the minimum settlement interval has passed.
error IndexVault_SettleIntervalNotPassed();

/// @notice Thrown when settle is attempted in the same block as a request (flash-loan protection).
error IndexVault_RequestBlockDelayNotPassed();

/// @notice Thrown when the idle buffer cannot cover the epoch's pending redemptions.
/// @dev Until the rebalancer can free USDC from the basket, settlement
/// requires the buffer to cover net outflows.
error IndexVault_InsufficientSettlementLiquidity(uint256 required, uint256 available);

/// @notice Thrown when claiming from a request that is not yet settled.
error IndexVault_RequestNotSettled();

/// @notice Thrown when claiming more than the request holds.
error IndexVault_ExceedsClaimable(uint256 requested, uint256 claimable);

/// @notice Thrown when buffer band parameters are inconsistent.
error IndexVault_InvalidBufferBand();

/// @notice Thrown when settlement timing parameters are inconsistent.
error IndexVault_InvalidSettleParams();

/// @notice Thrown when a CoW order is presented before the rebalancer is wired.
error IndexVault_RebalancerNotSet();

/// @notice Thrown when the order presented to isValidSignature does not hash to
/// the digest the settlement computed (rebinding the digest to the order).
error IndexVault_OrderDigestMismatch(bytes32 expected, bytes32 presented);

/// @notice Thrown when curating a constituent not registered in the AssetRegistry.
error IndexVault_AssetNotRegistered(address token);

/// @notice Thrown when the same token appears twice in a constituent set.
error IndexVault_DuplicateConstituent(address token);

/// @notice Thrown when a constituent set exceeds the per-index cap.
error IndexVault_TooManyConstituents(uint256 count, uint256 cap);

/// @notice Thrown when a governor-gated function is called by another address.
error IndexVault_NotGovernor(address caller);

/// @notice Thrown when seeding constituents after governance has been wired.
error IndexVault_GovernorAlreadySet();

/// @notice Thrown when a membership change targets a non-constituent.
error IndexVault_NotConstituent(address token);

/// @notice Thrown when finalizing removal of a constituent not marked for wind-down.
error IndexVault_NotWindingDown(address token);

/// @notice Thrown when finalizing removal before the position has been wound down to dust.
error IndexVault_PositionNotDust(address token, uint256 valueUsd);

/// @notice Thrown when a deposit or mint is attempted while a held constituent
/// is quarantined. Mints fail closed because a conservative NAV would over-issue.
error IndexVault_QuarantineBlocksDeposit();

/// @notice Thrown when settlement is attempted while a held constituent is
/// quarantined. The async batch is deferred until the feed recovers.
error IndexVault_QuarantineBlocksSettle();

/// @notice Thrown when quarantine parameters are out of range.
error IndexVault_InvalidQuarantineParams();

/**
 * @title IndexVault
 * @notice Pooled, single-asset (USDC) index vault. ERC-7540 asynchronous
 * superset of ERC-4626 with two-lane liquidity:
 *
 * - Synchronous lane. Flows small enough to keep the idle USDC buffer inside
 *   its band settle immediately through the standard ERC-4626 entry points,
 *   priced at the current oracle NAV per share.
 * - Asynchronous lane. Flows that would push the buffer outside its band are
 *   routed through ERC-7540 request and claim. Requests queue per settlement
 *   epoch, a keeper batch-settles them at the epoch's NAV, and users claim
 *   afterwards. Pending value sits in an isolated PendingSilo so it never
 *   contaminates NAV.
 *
 * NAV is oracle-based: the USD value of this index's curated constituents
 * (priced through the shared AssetRegistry's health-checked Chainlink feeds)
 * plus the idle USDC buffer, expressed in USDC units. Any stale feed makes
 * price-sensitive operations revert rather than transact on bad data.
 *
 * Pending redemptions are priced at settle time, not request time, which is
 * fairer to remaining holders.
 */
contract IndexVault is ERC4626, Ownable2Step, IERC7540, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using GPv2Order for GPv2Order.Data;

    /// @dev ERC-1271 magic value: bytes4(keccak256("isValidSignature(bytes32,bytes)")).
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;

    // ========================================================================
    // Types
    // ========================================================================

    /// @dev Per-epoch settlement record. Pending totals accumulate while the
    /// epoch is open; minted/paid totals are fixed at settlement and define
    /// the claim conversion ratio for every request filed in the epoch.
    struct EpochData {
        uint256 pendingDepositAssets;
        uint256 pendingRedeemShares;
        uint256 depositSharesMinted;
        uint256 redeemAssetsPaid;
        bool settled;
    }

    /// @dev A controller's open deposit request. One open request per side per
    /// controller; a settled request auto-claims when a new one is filed.
    struct DepositRequestState {
        uint256 epochId;
        uint256 assets;
    }

    /// @dev A controller's open redeem request.
    struct RedeemRequestState {
        uint256 epochId;
        uint256 shares;
    }

    /// @dev One row of the live basket composition, returned by getHoldings.
    struct Holding {
        address token;
        uint256 balance; // native token units held by the vault
        uint256 valueUsd; // 8-decimal USD value of the holding
        uint256 weightBps; // weight against NAV (basket plus idle) in bps
    }

    // ========================================================================
    // Constants and immutables
    // ========================================================================

    uint256 private constant BPS = 10_000;

    /// @notice Shared asset catalog this index draws constituents from and prices NAV through.
    AssetRegistry public immutable REGISTRY;

    /// @notice Per-index cap on the number of constituents, distinct from the
    /// catalog cap in the registry. Sized for the index-100 target.
    uint256 public constant MAX_CONSTITUENTS = 100;

    /// @notice Isolated holder of pending and claimable value.
    PendingSilo public immutable SILO;

    /// @dev One whole unit of the settlement asset (10^6 for USDC), cached for
    /// the USD-to-USDC conversion in totalAssets.
    uint256 private immutable _ASSET_UNIT;

    // ========================================================================
    // Storage
    // ========================================================================

    /// @notice Address allowed to settle epochs on schedule.
    address public keeper;

    /// @notice Buffer band in bps of NAV. Inside the band, flows are synchronous.
    uint16 public bufferLowBps = 300;
    uint16 public bufferTargetBps = 500;
    uint16 public bufferHighBps = 800;

    /// @notice Minimum seconds between settlements (keeper cadence floor).
    uint48 public minSettleInterval = 1 hours;

    /// @notice After this many seconds without settlement, anyone may settle,
    /// so pending requests can never be stuck on an absent keeper.
    uint48 public maxSettleDelay = 3 days;

    /// @notice Rebalancer that validates CoW orders the vault signs. The vault
    /// is the order owner and delegates order validation here.
    address public rebalancer;

    /// @notice CoW settlement domain separator, cached when the rebalancer is wired.
    bytes32 public cowDomainSeparator;

    /// @notice CoW vault relayer the vault approves to pull tokens for rebalancing.
    address public cowRelayer;

    /// @notice Current open settlement epoch. Requests file into this epoch.
    uint256 public currentEpoch = 1;

    /// @notice Timestamp of the last settlement.
    uint256 public lastSettleTimestamp;

    /// @dev Block of the most recent request; settlement must occur in a later
    /// block, which closes the flash-loan and same-block oracle-manipulation
    /// vector (a request can never be priced in the block that created it).
    uint256 private _lastRequestBlock;

    /// @dev Settlement records per epoch.
    mapping(uint256 epochId => EpochData) private _epochs;

    /// @dev Open deposit request per controller.
    mapping(address controller => DepositRequestState) private _depositRequests;

    /// @dev Open redeem request per controller.
    mapping(address controller => RedeemRequestState) private _redeemRequests;

    /// @dev ERC-7540 operator approvals.
    mapping(address controller => mapping(address operator => bool)) private _operators;

    /// @dev This index's curated constituent set, a subset of the registry catalog.
    address[] private _constituents;

    /// @notice Whether `token` is a constituent of this index.
    mapping(address token => bool) public isConstituent;

    /// @dev Token decimals cached at curation time, so the NAV loop needs no
    /// external decimals call per constituent.
    mapping(address token => uint8) private _constituentDecimals;

    /// @notice Membership governor. Once set, constituent changes flow through
    /// its timelocked, bounded lifecycle and `setConstituents` is locked to its
    /// pre-governance seeding role. Zero means governance is not yet wired.
    address public governor;

    /// @notice Whether `token` is marked for wind-down. A winding-down
    /// constituent stays in the set and in NAV while the rebalancer exits its
    /// position to USDC at the oracle-anchored minimum-out, so it is sold rather
    /// than dropped. It is deleted only once the position is dust.
    mapping(address token => bool) public windingDown;

    /// @notice Position USD value (8-decimal, matching NAV) below which a
    /// winding-down constituent is considered fully exited and may be removed.
    uint256 public dustThresholdUsd = 1e8;

    /// @notice Haircut applied the moment a constituent's feed goes stale and it
    /// enters quarantine, sized to the plausible adverse move over the window.
    uint16 public quarantineHaircutBps = 1000; // 10%

    /// @notice Window over which a quarantined constituent's mark decays from
    /// (1 - haircut) to zero, measured from the feed's last fresh timestamp. The
    /// longer a feed stays dead, the closer its mark falls to zero.
    uint48 public quarantineDecayWindow = 7 days;

    // ========================================================================
    // Events
    // ========================================================================

    event Settled(
        uint256 indexed epochId,
        uint256 totalAssetsBefore,
        uint256 totalSupplyBefore,
        uint256 depositAssets,
        uint256 depositSharesMinted,
        uint256 redeemShares,
        uint256 redeemAssetsPaid
    );
    event DepositClaimed(address indexed controller, address indexed receiver, uint256 assets, uint256 shares);
    event RedeemClaimed(address indexed controller, address indexed receiver, uint256 shares, uint256 assets);
    event KeeperSet(address indexed keeper);
    event BufferBandSet(uint16 lowBps, uint16 targetBps, uint16 highBps);
    event SettleParamsSet(uint48 minInterval, uint48 maxDelay);
    event ConstituentsSet(address[] tokens);
    event RebalancerSet(address indexed rebalancer, address indexed settlement);
    event RelayerApproved(address indexed token);
    event GovernorSet(address indexed governor);
    event ConstituentAdded(address indexed token);
    event WindDownBegun(address indexed token);
    event ConstituentRemoved(address indexed token);
    event DustThresholdSet(uint256 dustThresholdUsd);
    event QuarantineParamsSet(uint16 haircutBps, uint48 decayWindow);

    // ========================================================================
    // Construction
    // ========================================================================

    constructor(IERC20 usdc, AssetRegistry registry, address keeper_, address initialOwner)
        ERC4626(usdc)
        ERC20("Index Vault Share", "IDXV")
        Ownable(initialOwner)
    {
        if (address(registry) == address(0) || keeper_ == address(0)) revert IndexVault_ZeroAddress();
        REGISTRY = registry;
        keeper = keeper_;
        SILO = new PendingSilo(address(this), usdc);
        _ASSET_UNIT = 10 ** (decimals() - _decimalsOffset());
        lastSettleTimestamp = block.timestamp;
    }

    // ========================================================================
    // NAV
    // ========================================================================

    /**
     * @notice Total managed assets in USDC units: the oracle USD value of all
     * basket constituents plus the idle USDC buffer. Value parked in the
     * PendingSilo (unsettled deposit USDC, escrowed shares awaiting burn,
     * claimable balances) is structurally excluded.
     * @dev Escrowed redeem shares remain in totalSupply until their epoch
     * settles, and the value backing them remains in the vault, so the
     * NAV-per-share ratio stays consistent for both lanes.
     */
    function totalAssets() public view override returns (uint256) {
        // The USDC numeraire feed still fails closed: it is the unit NAV is quoted
        // in, not a constituent, so its staleness is a hard failure, not a quarantine.
        uint256 usdcPrice = REGISTRY.getUsdcPriceUsd();

        address[] memory cons = _constituents;
        uint256 basketUsd = 0;
        for (uint256 i = 0; i < cons.length; i++) {
            uint256 balance = IERC20(cons[i]).balanceOf(address(this));
            if (balance == 0) continue;
            (uint256 valueUsd,) = _constituentValueUsd(cons[i], balance);
            basketUsd += valueUsd;
        }

        // basketUsd has 8 decimals (registry PRICE_DECIMALS); dividing the USD
        // value by the USDC/USD price converts it into USDC units (6 decimals).
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return basketUsd.mulDiv(_ASSET_UNIT, usdcPrice, Math.Rounding.Floor) + idle;
    }

    /// @notice Idle USDC currently held as buffer.
    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @dev USD value (8-decimal) of `balance` of `token`, degrading on a stale
    /// or dead feed instead of reverting. A fresh feed values at full price; a
    /// stale feed values at its last-good price times a mark factor that starts
    /// at (1 - haircut) and decays linearly to zero over quarantineDecayWindow; a
    /// dead feed (non-positive answer) values at zero. Returns whether the
    /// constituent is quarantined (feed not fresh).
    function _constituentValueUsd(address token, uint256 balance)
        private
        view
        returns (uint256 valueUsd, bool quarantined)
    {
        (uint256 price, uint256 updatedAt, bool fresh) = REGISTRY.getPriceUsdStatus(token);
        uint256 fullUsd = price == 0 ? 0 : balance.mulDiv(price, 10 ** _constituentDecimals[token], Math.Rounding.Floor);
        if (fresh) return (fullUsd, false);

        // Quarantined: conservative mark on the last-good price.
        uint256 markBps = _quarantineMarkBps(updatedAt);
        return (fullUsd.mulDiv(markBps, BPS, Math.Rounding.Floor), true);
    }

    /// @dev Quarantine mark factor in bps: (BPS - haircut) when the feed has just
    /// gone stale, decaying linearly to zero across quarantineDecayWindow. Age is
    /// measured from the feed's last fresh timestamp, which is marginally more
    /// conservative than measuring from the heartbeat boundary, the safe direction.
    function _quarantineMarkBps(uint256 updatedAt) private view returns (uint256) {
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age >= quarantineDecayWindow) return 0;
        uint256 base = BPS - quarantineHaircutBps;
        return base.mulDiv(quarantineDecayWindow - age, quarantineDecayWindow, Math.Rounding.Floor);
    }

    /// @notice Whether `token` is a constituent whose feed is currently stale or
    /// dead, so it is being valued conservatively in NAV.
    function isQuarantined(address token) public view returns (bool) {
        if (!isConstituent[token]) return false;
        (,, bool fresh) = REGISTRY.getPriceUsdStatus(token);
        return !fresh;
    }

    /// @notice Whether any constituent the vault actually holds is quarantined.
    /// Deposits, mints, and settlement gate on this: a quarantined (undervalued)
    /// basket must not be minted against, or it would over-issue shares and dilute
    /// the holders who stay. A zero-balance constituent cannot affect NAV, so a
    /// stale feed on one the vault does not hold does not block entries.
    function isAnyQuarantined() public view returns (bool) {
        address[] memory cons = _constituents;
        for (uint256 i = 0; i < cons.length; i++) {
            if (IERC20(cons[i]).balanceOf(address(this)) == 0) continue;
            (,, bool fresh) = REGISTRY.getPriceUsdStatus(cons[i]);
            if (!fresh) return true;
        }
        return false;
    }

    // ========================================================================
    // Constituents (curated membership)
    // ========================================================================

    /// @notice Seeds this index's constituent set before governance is wired.
    /// Curated by the admin or multisig, because category membership is a
    /// definitional choice, not a rank. Every token must be registered in the
    /// shared AssetRegistry.
    /// @dev Pre-governance seeding only: once a `governor` is set, this reverts
    /// and every membership change must flow through the governor's timelocked,
    /// bounded lifecycle (forced-versus-discretionary removal, rate-limit,
    /// minimum-count, wind-down). Weighting over this set stays autonomous.
    function setConstituents(address[] calldata tokens) external onlyOwner {
        if (governor != address(0)) revert IndexVault_GovernorAlreadySet();
        if (tokens.length > MAX_CONSTITUENTS) revert IndexVault_TooManyConstituents(tokens.length, MAX_CONSTITUENTS);

        // Clear the previous set.
        address[] memory prev = _constituents;
        for (uint256 i = 0; i < prev.length; i++) {
            isConstituent[prev[i]] = false;
            delete _constituentDecimals[prev[i]];
        }
        delete _constituents;

        // Install the new set, validating registration and rejecting duplicates.
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (!REGISTRY.isRegistered(token)) revert IndexVault_AssetNotRegistered(token);
            if (isConstituent[token]) revert IndexVault_DuplicateConstituent(token);
            isConstituent[token] = true;
            _constituentDecimals[token] = REGISTRY.getAsset(token).tokenDecimals;
            _constituents.push(token);
        }

        emit ConstituentsSet(tokens);
    }

    /// @dev Restricts membership mutation to the governor, which enforces the
    /// timelocked, bounded change lifecycle (Section 16). The vault holds the
    /// set and applies changes; the governor owns the policy.
    modifier onlyGovernor() {
        if (msg.sender != governor) revert IndexVault_NotGovernor(msg.sender);
        _;
    }

    /// @notice Adds a single registered token to the constituent set. The
    /// governor has already checked the addition bounds (size floor, rate limit).
    function governorAddConstituent(address token) external onlyGovernor {
        if (_constituents.length >= MAX_CONSTITUENTS) {
            revert IndexVault_TooManyConstituents(_constituents.length + 1, MAX_CONSTITUENTS);
        }
        if (!REGISTRY.isRegistered(token)) revert IndexVault_AssetNotRegistered(token);
        if (isConstituent[token]) revert IndexVault_DuplicateConstituent(token);

        isConstituent[token] = true;
        _constituentDecimals[token] = REGISTRY.getAsset(token).tokenDecimals;
        _constituents.push(token);
        emit ConstituentAdded(token);
    }

    /// @notice Marks a constituent for wind-down. It stays in the set and in NAV
    /// so its value is never orphaned; the rebalancer zeroes its target and sells
    /// the position to USDC at the oracle-anchored minimum-out. This is the
    /// "wind-down, not dump" execution path (Section 16.5).
    function governorBeginWindDown(address token) external onlyGovernor {
        if (!isConstituent[token]) revert IndexVault_NotConstituent(token);
        windingDown[token] = true;
        emit WindDownBegun(token);
    }

    /// @notice Deletes a winding-down constituent once its position is dust, so
    /// removal only ever drops a position the vault no longer meaningfully holds.
    /// @dev Reverts while the position still has material value, which also means
    /// a constituent whose feed is dead cannot be finalized here (it cannot be
    /// priced or wound down): that is the quarantine case deferred to Section 4.
    function governorFinalizeRemoval(address token) external onlyGovernor {
        if (!windingDown[token]) revert IndexVault_NotWindingDown(token);

        uint256 valueUsd = _positionValueUsd(token);
        if (valueUsd > dustThresholdUsd) revert IndexVault_PositionNotDust(token, valueUsd);

        _removeConstituent(token);
        windingDown[token] = false;
        emit ConstituentRemoved(token);
    }

    /// @dev Swap-and-pop removal of `token` from the constituent set, clearing
    /// its membership and cached decimals.
    function _removeConstituent(address token) private {
        uint256 len = _constituents.length;
        for (uint256 i = 0; i < len; i++) {
            if (_constituents[i] == token) {
                _constituents[i] = _constituents[len - 1];
                _constituents.pop();
                break;
            }
        }
        isConstituent[token] = false;
        delete _constituentDecimals[token];
    }

    /// @dev USD value (8-decimal, matching the NAV term) of the vault's current
    /// balance of `token`. Reverts on a stale feed, exactly as NAV does.
    function _positionValueUsd(address token) private view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return 0;
        uint256 price = REGISTRY.getPriceUsd(token);
        return balance.mulDiv(price, 10 ** _constituentDecimals[token], Math.Rounding.Floor);
    }

    /// @notice This index's current constituent set.
    function getConstituents() external view returns (address[] memory) {
        return _constituents;
    }

    /// @notice Number of constituents in this index.
    function constituentCount() external view returns (uint256) {
        return _constituents.length;
    }

    /**
     * @notice Live basket composition: per-constituent balance, USD value, and
     * weight against NAV, plus the idle USDC value and total NAV in USD. One
     * call answers both what is in the index and in what proportion right now.
     * @dev Weights are bps of total NAV (basket USD plus idle USD), 8-decimal
     * USD throughout. Prices are health-checked, so this reverts on a stale feed.
     */
    function getHoldings() external view returns (Holding[] memory holdings, uint256 idleUsd, uint256 totalUsd) {
        uint256 usdcPrice = REGISTRY.getUsdcPriceUsd();

        address[] memory cons = _constituents;
        holdings = new Holding[](cons.length);
        uint256 basketUsd = 0;
        for (uint256 i = 0; i < cons.length; i++) {
            address token = cons[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            // Degrade on a stale feed, matching totalAssets, so holdings reads
            // and NAV agree and neither halts on a single quarantined constituent.
            (uint256 valueUsd,) = balance == 0 ? (uint256(0), false) : _constituentValueUsd(token, balance);
            holdings[i] = Holding({ token: token, balance: balance, valueUsd: valueUsd, weightBps: 0 });
            basketUsd += valueUsd;
        }

        // Idle USDC (6 decimals) valued into 8-decimal USD via the USDC price.
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        idleUsd = idle.mulDiv(usdcPrice, _ASSET_UNIT, Math.Rounding.Floor);
        totalUsd = basketUsd + idleUsd;

        if (totalUsd > 0) {
            for (uint256 i = 0; i < holdings.length; i++) {
                holdings[i].weightBps = holdings[i].valueUsd.mulDiv(BPS, totalUsd, Math.Rounding.Floor);
            }
        }
    }

    // ========================================================================
    // Two-lane gating (ERC-4626 max overrides)
    // ========================================================================

    /**
     * @notice Largest synchronous deposit that keeps the post-deposit buffer at
     * or below the high band. Solving (idle + a) <= high * (ta + a) for a.
     */
    function syncDepositCapacity() public view returns (uint256) {
        uint256 ta = totalAssets();
        uint256 idle = idleAssets();
        uint256 highScaled = uint256(bufferHighBps) * ta;
        if (idle * BPS >= highScaled) return 0;
        return (highScaled - idle * BPS) / (BPS - bufferHighBps);
    }

    /**
     * @notice Largest synchronous withdrawal that keeps the post-withdrawal
     * buffer at or above the low band. Solving (idle - a) >= low * (ta - a) for a.
     */
    function syncWithdrawCapacity() public view returns (uint256) {
        uint256 ta = totalAssets();
        uint256 idle = idleAssets();
        uint256 lowScaled = uint256(bufferLowBps) * ta;
        if (idle * BPS <= lowScaled) return 0;
        uint256 capacity = (idle * BPS - lowScaled) / (BPS - bufferLowBps);
        return capacity > idle ? idle : capacity;
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        return syncDepositCapacity();
    }

    /// @inheritdoc ERC4626
    function maxMint(address) public view override returns (uint256) {
        return _convertToShares(syncDepositCapacity(), Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626
    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), syncWithdrawCapacity());
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(balanceOf(owner), _convertToShares(syncWithdrawCapacity(), Math.Rounding.Floor));
    }

    // ========================================================================
    // ERC-7540 operator model
    // ========================================================================

    /// @inheritdoc IERC7540
    function setOperator(address operator, bool approved) external returns (bool) {
        _operators[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    /// @inheritdoc IERC7540
    function isOperator(address controller, address operator) public view returns (bool) {
        return _operators[controller][operator];
    }

    /// @dev Reverts unless the caller is the controller or its approved operator.
    function _requireAuthorized(address controller) internal view {
        if (msg.sender != controller && !isOperator(controller, msg.sender)) {
            revert IndexVault_NotAuthorized(controller, msg.sender);
        }
    }

    // ========================================================================
    // ERC-7540 requests
    // ========================================================================

    /// @inheritdoc IERC7540
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (assets == 0) revert IndexVault_ZeroAmount();
        if (msg.sender != owner && !isOperator(owner, msg.sender)) {
            revert IndexVault_NotAuthorized(owner, msg.sender);
        }

        DepositRequestState storage request = _depositRequests[controller];
        if (request.assets > 0) {
            if (_epochs[request.epochId].settled) {
                // A settled, unclaimed request blocks the slot; claim it to the
                // controller before filing the new one.
                _claimDeposit(controller, controller, request.assets);
            }
            // Otherwise the open request is in the current epoch (epochs settle
            // monotonically) and the new amount simply tops it up.
        }

        IERC20(asset()).safeTransferFrom(owner, address(SILO), assets);

        requestId = currentEpoch;
        request.epochId = requestId;
        request.assets += assets;
        _epochs[requestId].pendingDepositAssets += assets;
        _lastRequestBlock = block.number;

        emit DepositRequest(controller, owner, requestId, msg.sender, assets);
    }

    /// @inheritdoc IERC7540
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares == 0) revert IndexVault_ZeroAmount();
        if (msg.sender != owner && !isOperator(owner, msg.sender)) {
            _spendAllowance(owner, msg.sender, shares);
        }

        RedeemRequestState storage request = _redeemRequests[controller];
        if (request.shares > 0 && _epochs[request.epochId].settled) {
            _claimRedeem(controller, controller, request.shares);
        }

        // Escrow the shares in the silo; they stay in totalSupply until the
        // epoch settles and burns them, keeping NAV per share consistent.
        _transfer(owner, address(SILO), shares);

        requestId = currentEpoch;
        request.epochId = requestId;
        request.shares += shares;
        _epochs[requestId].pendingRedeemShares += shares;
        _lastRequestBlock = block.number;

        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    // ========================================================================
    // ERC-7540 request views
    // ========================================================================

    /// @inheritdoc IERC7540
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256) {
        DepositRequestState storage request = _depositRequests[controller];
        if (request.epochId != requestId || _epochs[requestId].settled) return 0;
        return request.assets;
    }

    /// @inheritdoc IERC7540
    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256) {
        DepositRequestState storage request = _depositRequests[controller];
        if (request.epochId != requestId || !_epochs[requestId].settled) return 0;
        return request.assets;
    }

    /// @inheritdoc IERC7540
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        RedeemRequestState storage request = _redeemRequests[controller];
        if (request.epochId != requestId || _epochs[requestId].settled) return 0;
        return request.shares;
    }

    /// @inheritdoc IERC7540
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        RedeemRequestState storage request = _redeemRequests[controller];
        if (request.epochId != requestId || !_epochs[requestId].settled) return 0;
        return request.shares;
    }

    // ========================================================================
    // ERC-7540 claims
    // ========================================================================

    /// @inheritdoc IERC7540
    function deposit(uint256 assets, address receiver, address controller)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _requireAuthorized(controller);
        shares = _claimDeposit(controller, receiver, assets);
    }

    /// @inheritdoc IERC7540
    function mint(uint256 shares, address receiver, address controller) external nonReentrant returns (uint256 assets) {
        _requireAuthorized(controller);
        DepositRequestState storage request = _depositRequests[controller];
        EpochData storage epoch = _epochs[request.epochId];
        if (!epoch.settled) revert IndexVault_RequestNotSettled();

        // Debit the assets backing exactly `shares` (rounded up, so the caller
        // pays the ceil) and transfer exactly `shares`. Going through
        // _claimDeposit would ceil to assets then floor back to shares, leaving
        // the caller a wei of shares short; this delivers the amount requested.
        // The assets bound is at or below request.assets, so no over-claim.
        assets = shares.mulDiv(epoch.pendingDepositAssets, epoch.depositSharesMinted, Math.Rounding.Ceil);
        if (assets > request.assets) revert IndexVault_ExceedsClaimable(assets, request.assets);
        request.assets -= assets;
        _transfer(address(SILO), receiver, shares);
        emit DepositClaimed(controller, receiver, assets, shares);
    }

    /**
     * @notice ERC-4626 redeem with ERC-7540 claim semantics layered on. If the
     * third parameter names a controller with a settled redeem request, this
     * claims that request's USDC; otherwise it is a standard synchronous
     * redemption against the buffer.
     */
    function redeem(uint256 shares, address receiver, address controllerOrOwner) public override returns (uint256) {
        RedeemRequestState storage request = _redeemRequests[controllerOrOwner];
        if (request.shares > 0 && _epochs[request.epochId].settled) {
            _requireAuthorized(controllerOrOwner);
            return _claimRedeem(controllerOrOwner, receiver, shares);
        }
        return super.redeem(shares, receiver, controllerOrOwner);
    }

    /// @dev Converts `assets` of a settled deposit request into shares at the
    /// epoch's settlement ratio and transfers them out of the silo.
    function _claimDeposit(address controller, address receiver, uint256 assets) internal returns (uint256 shares) {
        DepositRequestState storage request = _depositRequests[controller];
        EpochData storage epoch = _epochs[request.epochId];
        if (!epoch.settled) revert IndexVault_RequestNotSettled();
        if (assets > request.assets) revert IndexVault_ExceedsClaimable(assets, request.assets);

        shares = assets.mulDiv(epoch.depositSharesMinted, epoch.pendingDepositAssets, Math.Rounding.Floor);
        request.assets -= assets;

        _transfer(address(SILO), receiver, shares);
        emit DepositClaimed(controller, receiver, assets, shares);
    }

    /// @dev Converts `shares` of a settled redeem request into USDC at the
    /// epoch's settlement ratio and pays out of the silo.
    function _claimRedeem(address controller, address receiver, uint256 shares) internal returns (uint256 assets) {
        RedeemRequestState storage request = _redeemRequests[controller];
        EpochData storage epoch = _epochs[request.epochId];
        if (!epoch.settled) revert IndexVault_RequestNotSettled();
        if (shares > request.shares) revert IndexVault_ExceedsClaimable(shares, request.shares);

        assets = shares.mulDiv(epoch.redeemAssetsPaid, epoch.pendingRedeemShares, Math.Rounding.Floor);
        request.shares -= shares;

        IERC20(asset()).safeTransferFrom(address(SILO), receiver, assets);
        emit RedeemClaimed(controller, receiver, shares, assets);
    }

    // ========================================================================
    // Settlement
    // ========================================================================

    /**
     * @notice Settles the current epoch: prices the basket at oracle NAV,
     * converts the epoch's pending deposits to shares and pending redemptions
     * to USDC at the same pre-settlement ratio, and opens the next epoch.
     * Both queues clear at one price, so settlement order cannot advantage
     * either side.
     * @dev Keeper-only on the normal cadence. After maxSettleDelay without a
     * settlement, callable by anyone as a liveness backstop. Must be at least
     * one block after the most recent request (flash-loan protection).
     */
    function settle() external nonReentrant {
        if (msg.sender != keeper) {
            if (block.timestamp < lastSettleTimestamp + maxSettleDelay) revert IndexVault_NotKeeper(msg.sender);
        }
        if (block.timestamp < lastSettleTimestamp + minSettleInterval) revert IndexVault_SettleIntervalNotPassed();
        if (block.number <= _lastRequestBlock) revert IndexVault_RequestBlockDelayNotPassed();
        // Defer the whole async batch while any held constituent is quarantined:
        // the deposit leg must not mint against a conservative NAV, and netting
        // both legs at a degraded ratio is unsafe. Sync buffer redemptions remain
        // open through the degraded NAV; large flows wait for the feed to recover.
        if (isAnyQuarantined()) revert IndexVault_QuarantineBlocksSettle();

        uint256 epochId = currentEpoch;
        EpochData storage epoch = _epochs[epochId];

        // Snapshot the pre-settlement ratio once; both conversions price off it.
        uint256 ta = totalAssets();
        uint256 supply = totalSupply();
        uint256 virtualShares = 10 ** _decimalsOffset();

        uint256 depositAssets = epoch.pendingDepositAssets;
        uint256 redeemShares = epoch.pendingRedeemShares;

        uint256 sharesToMint =
            depositAssets == 0 ? 0 : depositAssets.mulDiv(supply + virtualShares, ta + 1, Math.Rounding.Floor);
        uint256 assetsToPay =
            redeemShares == 0 ? 0 : redeemShares.mulDiv(ta + 1, supply + virtualShares, Math.Rounding.Floor);

        uint256 idle = idleAssets();

        epoch.settled = true;
        epoch.depositSharesMinted = sharesToMint;
        epoch.redeemAssetsPaid = assetsToPay;
        currentEpoch = epochId + 1;
        lastSettleTimestamp = block.timestamp;

        // Settle the deposit leg first: pull the epoch's pending deposit USDC
        // into the buffer and mint its shares. This nets the two sides, so a
        // balanced epoch's deposit inflow can fund its redemption outflow,
        // rather than the redemption check seeing only the prior buffer and
        // deadlocking an epoch that is busy on both sides.
        if (depositAssets > 0) {
            IERC20(asset()).safeTransferFrom(address(SILO), address(this), depositAssets);
            _mint(address(SILO), sharesToMint);
        }

        // Redemption leg against the topped-up buffer.
        if (redeemShares > 0) {
            uint256 available = idle + depositAssets;
            if (assetsToPay > available) revert IndexVault_InsufficientSettlementLiquidity(assetsToPay, available);
            _burn(address(SILO), redeemShares);
            IERC20(asset()).safeTransfer(address(SILO), assetsToPay);
        }

        emit Settled(epochId, ta, supply, depositAssets, sharesToMint, redeemShares, assetsToPay);
    }

    // ========================================================================
    // Admin
    // ========================================================================

    /// @notice Sets the settlement keeper.
    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert IndexVault_ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Wires the membership governor. Once set, `setConstituents` is
    /// locked and every membership change flows through the governor's
    /// timelocked, bounded lifecycle. Owner-gated, since in production the owner
    /// is itself a governance multisig or timelock.
    function setGovernor(address governor_) external onlyOwner {
        if (governor_ == address(0)) revert IndexVault_ZeroAddress();
        governor = governor_;
        emit GovernorSet(governor_);
    }

    /// @notice Sets the dust value below which a wound-down position may be
    /// removed from the set.
    function setDustThreshold(uint256 dustThresholdUsd_) external onlyOwner {
        dustThresholdUsd = dustThresholdUsd_;
        emit DustThresholdSet(dustThresholdUsd_);
    }

    /// @notice Sets the quarantine haircut and decay window used to value a
    /// constituent whose feed has gone stale.
    function setQuarantineParams(uint16 haircutBps, uint48 decayWindow) external onlyOwner {
        if (haircutBps >= BPS || decayWindow == 0) revert IndexVault_InvalidQuarantineParams();
        quarantineHaircutBps = haircutBps;
        quarantineDecayWindow = decayWindow;
        emit QuarantineParamsSet(haircutBps, decayWindow);
    }

    /// @notice Sets the buffer band. Low and high gate the sync lanes; target
    /// is the level the rebalancer tops the buffer back toward.
    function setBufferBand(uint16 lowBps, uint16 targetBps, uint16 highBps) external onlyOwner {
        if (lowBps == 0 || lowBps > targetBps || targetBps > highBps || highBps >= BPS) {
            revert IndexVault_InvalidBufferBand();
        }
        bufferLowBps = lowBps;
        bufferTargetBps = targetBps;
        bufferHighBps = highBps;
        emit BufferBandSet(lowBps, targetBps, highBps);
    }

    /// @notice Sets settlement timing: keeper cadence floor and the liveness backstop.
    function setSettleParams(uint48 minInterval, uint48 maxDelay) external onlyOwner {
        if (minInterval == 0 || maxDelay <= minInterval) revert IndexVault_InvalidSettleParams();
        minSettleInterval = minInterval;
        maxSettleDelay = maxDelay;
        emit SettleParamsSet(minInterval, maxDelay);
    }

    // ========================================================================
    // CoW rebalancing (the vault is the order owner)
    // ========================================================================

    /// @notice Wires the rebalancer and caches the CoW settlement's domain
    /// separator and relayer, so the vault can validate orders and approve the
    /// relayer to pull tokens for rebalancing.
    function setRebalancer(address rebalancer_, address settlement) external onlyOwner {
        if (rebalancer_ == address(0) || settlement == address(0)) revert IndexVault_ZeroAddress();
        rebalancer = rebalancer_;
        cowDomainSeparator = ICoWSettlement(settlement).domainSeparator();
        cowRelayer = ICoWSettlement(settlement).vaultRelayer();
        emit RebalancerSet(rebalancer_, settlement);
    }

    /// @notice Approves the CoW relayer to pull `token` from the vault. Needed
    /// for each constituent (to sell) and for USDC (to buy). Owner-gated; the
    /// trades it enables are bounded by the rebalancer's order validation and
    /// the per-order minimum-out.
    function approveRelayer(address token) external onlyOwner {
        if (cowRelayer == address(0)) revert IndexVault_RebalancerNotSet();
        IERC20(token).forceApprove(cowRelayer, type(uint256).max);
        emit RelayerApproved(token);
    }

    /// @notice ERC-1271 validation so the CoW settlement accepts the vault's
    /// orders without a pre-signature. The digest is rebound to the decoded
    /// order, then the rebalancer decides whether the order is a legitimate
    /// rebalance leg right now.
    /// @param digest The order digest the settlement computed.
    /// @param signature The ABI-encoded GPv2Order for that trade.
    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        if (rebalancer == address(0)) revert IndexVault_RebalancerNotSet();

        GPv2Order.Data memory order = abi.decode(signature, (GPv2Order.Data));
        bytes32 expected = order.hash(cowDomainSeparator);
        if (expected != digest) revert IndexVault_OrderDigestMismatch(expected, digest);

        IRebalancer(rebalancer).validateOrder(order);
        return ERC1271_MAGIC;
    }

    // ========================================================================
    // ERC-4626 internals
    // ========================================================================

    /// @dev Shares carry 12 extra decimals over USDC (18 total). The virtual
    /// share offset also blunts first-depositor share-price inflation.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    /// @dev Reentrancy guard on the synchronous lane. Every ERC-4626 sync flow
    /// (deposit, mint, withdraw, redeem) funnels through these two hooks, so
    /// guarding them here covers the whole sync path. The async request, claim,
    /// and settle entry points carry their own guards and bypass these hooks, so
    /// there is no nested-guard reversion. Defense in depth: NAV reads a
    /// constituent's balanceOf, so a callback token could otherwise reenter, and
    /// the curation policy independently excludes callback tokens.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        // Mints fail closed under quarantine: a conservative NAV would over-issue
        // shares to a depositor at the expense of the holders who stay.
        if (isAnyQuarantined()) revert IndexVault_QuarantineBlocksDeposit();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}
