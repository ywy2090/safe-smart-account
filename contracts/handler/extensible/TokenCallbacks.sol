// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ERC1155TokenReceiver} from "../../interfaces/ERC1155TokenReceiver.sol";
import {ERC721TokenReceiver} from "../../interfaces/ERC721TokenReceiver.sol";

import {ExtensibleBase} from "./ExtensibleBase.sol";

/**
 * @title TokenCallbacks - ERC-1155 and ERC-721 token callbacks for Safes
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @notice Refactored from https://github.com/safe-global/safe-contracts/blob/3c3fc80f7f9aef1d39aaae2b53db5f4490051b0d/contracts/handler/TokenCallbackHandler.sol
 */
abstract contract TokenCallbacks is ExtensibleBase, ERC1155TokenReceiver, ERC721TokenReceiver {
    /**
     * @notice Handles ERC-1155 Token callback.
     * return Standardized onERC1155Received return value.
     */
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view override onlyFallback returns (bytes4) {
        // 只允许经 Safe fallback 上下文调用，返回 ERC-1155 单笔接收魔术值。
        return 0xf23a6e61;
    }

    /**
     * @notice Handles ERC-1155 Token batch callback.
     * return Standardized onERC1155BatchReceived return value.
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external view override onlyFallback returns (bytes4) {
        // 返回 ERC-1155 批量接收魔术值。
        return 0xbc197c81;
    }

    /**
     * @notice Handles ERC-721 Token callback.
     *  return Standardized onERC721Received return value.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view override onlyFallback returns (bytes4) {
        // 返回 ERC-721 接收魔术值。
        return 0x150b7a02;
    }
}
