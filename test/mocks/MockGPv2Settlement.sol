// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { GPv2Order } from "src/libraries/GPv2Order.sol";

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/**
 * @notice Faithful mock of the slice of GPv2Settlement a contract trader
 * touches: the EIP-712 domain separator built exactly as CoW builds it, the
 * relayer (itself, for the mock), and a settle path that replicates the real
 * EIP-1271 verification (compute the order digest, call the owner's
 * isValidSignature, require the magic value) before moving tokens. This lets
 * the handler's full mechanics be tested deterministically without a fork.
 */
contract MockGPv2Settlement {
    bytes32 public immutable domainSeparator;

    constructor() {
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gnosis Protocol"),
                keccak256("v2"),
                block.chainid,
                address(this)
            )
        );
    }

    function vaultRelayer() external view returns (address) {
        return address(this);
    }

    /// @notice Settles a single order against an EIP-1271 contract owner,
    /// filling `executedSell` of the sell token at the order's clearing ratio.
    function settle(GPv2Order.Data calldata order, address owner, uint256 executedSell) external {
        bytes32 digest = GPv2Order.hash(order, domainSeparator);
        require(IERC1271(owner).isValidSignature(digest, abi.encode(order)) == 0x1626ba7e, "GPv2: invalid eip1271");

        // Clearing ratio from the order: buy is proportional to the sell filled.
        uint256 executedBuy = order.buyAmount * executedSell / order.sellAmount;

        // Relayer pulls the sell token from the owner, settlement pays the buy.
        IERC20(order.sellToken).transferFrom(owner, address(this), executedSell);
        IERC20(order.buyToken).transfer(order.receiver, executedBuy);
    }
}
