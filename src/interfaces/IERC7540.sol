// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IERC7540
 * @notice Minimal ERC-7540 asynchronous tokenized vault interface, covering the
 * request/claim lifecycle and the operator model. The vault is an ERC-4626
 * superset: small flows settle synchronously through the standard 4626 entry
 * points, large flows route through these asynchronous requests.
 */
interface IERC7540 {
    /// @notice Emitted when `owner` locks `assets` into a deposit request controlled by `controller`.
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );

    /// @notice Emitted when `owner` escrows `shares` into a redeem request controlled by `controller`.
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /// @notice Emitted when `controller` grants or revokes `operator` rights over its requests.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /// @notice Transfers `assets` of the underlying from `owner` into the pending deposit queue.
    /// @return requestId The settlement epoch the request was filed under.
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    /// @notice Escrows `shares` from `owner` into the pending redeem queue.
    /// @return requestId The settlement epoch the request was filed under.
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);

    /// @notice Assets in a deposit request that has not yet been settled.
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);

    /// @notice Assets in a deposit request that has been settled and can be claimed as shares.
    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);

    /// @notice Shares in a redeem request that has not yet been settled.
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);

    /// @notice Shares in a redeem request that has been settled and can be claimed as assets.
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);

    /// @notice Claims shares from a settled deposit request (ERC-7540 claim overload of deposit).
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    /// @notice Claims shares from a settled deposit request, specified in shares.
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /// @notice Grants or revokes `operator` rights to manage the caller's requests.
    function setOperator(address operator, bool approved) external returns (bool);

    /// @notice Returns whether `operator` may manage requests on behalf of `controller`.
    function isOperator(address controller, address operator) external view returns (bool);
}
