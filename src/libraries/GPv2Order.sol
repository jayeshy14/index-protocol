// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title GPv2Order
 * @notice Minimal port of CoW Protocol's order struct and EIP-712 digest, used
 * so the vault can present and validate orders that hash identically to what
 * the real GPv2Settlement computes. The struct field order, TYPE_HASH, and
 * KIND / balance constants are copied verbatim from cowprotocol/contracts; the
 * digest uses abi.encode, which is byte-for-byte equivalent to their assembly
 * struct hashing (12 fields plus the type hash, each padded to 32 bytes).
 */
library GPv2Order {
    /// @dev The order struct, field order significant for the EIP-712 hash.
    struct Data {
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind;
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
    }

    /// @dev keccak256 of the EIP-712 Order type string (from CoW).
    bytes32 internal constant TYPE_HASH = hex"d5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489";

    /// @dev Sell order kind.
    bytes32 internal constant KIND_SELL = hex"f3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775";

    /// @dev Buy order kind.
    bytes32 internal constant KIND_BUY = hex"6ed88e868af0a1983e3886d5f3e95a2fafbd6c3450bc229e27342283dc429ccc";

    /// @dev ERC-20 balance source/target (as opposed to Balancer internal balances).
    bytes32 internal constant BALANCE_ERC20 = hex"5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9";

    /// @notice EIP-712 digest of `order` under `domainSeparator`, matching the
    /// value GPv2Settlement derives when verifying a signature.
    function hash(Data memory order, bytes32 domainSeparator) internal pure returns (bytes32 orderDigest) {
        bytes32 structHash = keccak256(
            abi.encode(
                TYPE_HASH,
                order.sellToken,
                order.buyToken,
                order.receiver,
                order.sellAmount,
                order.buyAmount,
                order.validTo,
                order.appData,
                order.feeAmount,
                order.kind,
                order.partiallyFillable,
                order.sellTokenBalance,
                order.buyTokenBalance
            )
        );
        orderDigest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }
}
