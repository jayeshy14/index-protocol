// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { AssetRegistry } from "src/AssetRegistry.sol";
import { PendingSilo } from "src/PendingSilo.sol";
import { IERC7540 } from "src/interfaces/IERC7540.sol";

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

/// @notice Thrown when curating a constituent not registered in the AssetRegistry.
error IndexVault_AssetNotRegistered(address token);

/// @notice Thrown when the same token appears twice in a constituent set.
error IndexVault_DuplicateConstituent(address token);

/// @notice Thrown when a constituent set exceeds the per-index cap.
error IndexVault_TooManyConstituents(uint256 count, uint256 cap);

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
contract IndexVault is ERC4626, Ownable2Step, IERC7540 {
    using SafeERC20 for IERC20;
    using Math for uint256;

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
        uint256 usdcPrice = REGISTRY.getUsdcPriceUsd();

        address[] memory cons = _constituents;
        uint256 basketUsd = 0;
        for (uint256 i = 0; i < cons.length; i++) {
            address token = cons[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) continue;
            uint256 price = REGISTRY.getPriceUsd(token);
            basketUsd += balance.mulDiv(price, 10 ** _constituentDecimals[token], Math.Rounding.Floor);
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

    // ========================================================================
    // Constituents (curated membership)
    // ========================================================================

    /// @notice Replaces this index's constituent set. Curated by the admin or
    /// multisig, because category membership is a definitional choice, not a
    /// rank. Every token must be registered in the shared AssetRegistry.
    /// @dev Stage 1 wholesale setter under simple owner gating. The timelock,
    /// forced-versus-discretionary removal, rate-limit, and minimum-count
    /// guardrails are layered on later; weighting over this set stays autonomous.
    function setConstituents(address[] calldata tokens) external onlyOwner {
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
            uint256 valueUsd = balance == 0
                ? 0
                : balance.mulDiv(REGISTRY.getPriceUsd(token), 10 ** _constituentDecimals[token], Math.Rounding.Floor);
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
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId) {
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
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
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
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares) {
        _requireAuthorized(controller);
        shares = _claimDeposit(controller, receiver, assets);
    }

    /// @inheritdoc IERC7540
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets) {
        _requireAuthorized(controller);
        DepositRequestState storage request = _depositRequests[controller];
        EpochData storage epoch = _epochs[request.epochId];
        if (!epoch.settled) revert IndexVault_RequestNotSettled();
        assets = shares.mulDiv(epoch.pendingDepositAssets, epoch.depositSharesMinted, Math.Rounding.Ceil);
        _claimDeposit(controller, receiver, assets);
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
    function settle() external {
        if (msg.sender != keeper) {
            if (block.timestamp < lastSettleTimestamp + maxSettleDelay) revert IndexVault_NotKeeper(msg.sender);
        }
        if (block.timestamp < lastSettleTimestamp + minSettleInterval) revert IndexVault_SettleIntervalNotPassed();
        if (block.number <= _lastRequestBlock) revert IndexVault_RequestBlockDelayNotPassed();

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
        if (assetsToPay > idle) revert IndexVault_InsufficientSettlementLiquidity(assetsToPay, idle);

        epoch.settled = true;
        epoch.depositSharesMinted = sharesToMint;
        epoch.redeemAssetsPaid = assetsToPay;
        currentEpoch = epochId + 1;
        lastSettleTimestamp = block.timestamp;

        if (redeemShares > 0) {
            _burn(address(SILO), redeemShares);
            IERC20(asset()).safeTransfer(address(SILO), assetsToPay);
        }
        if (depositAssets > 0) {
            IERC20(asset()).safeTransferFrom(address(SILO), address(this), depositAssets);
            _mint(address(SILO), sharesToMint);
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
    // ERC-4626 internals
    // ========================================================================

    /// @dev Shares carry 12 extra decimals over USDC (18 total). The virtual
    /// share offset also blunts first-depositor share-price inflation.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }
}
