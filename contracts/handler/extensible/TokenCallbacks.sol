// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ERC1155TokenReceiver} from "../../interfaces/ERC1155TokenReceiver.sol";
import {ERC721TokenReceiver} from "../../interfaces/ERC721TokenReceiver.sol";

import {ExtensibleBase} from "./ExtensibleBase.sol";

/**
 * @title TokenCallbacks
 * @notice 为 Safe 提供 ERC-721 / ERC-1155 的接收回调实现，使 Safe 能正确接收 safeTransferFrom / safeBatchTransferFrom 转来的 NFT。
 * @dev
 * - 当第三方调用 NFT 合约的 safeTransferFrom(sender, safe, tokenId) 时，NFT 合约会回调「接收方」的 onERC721Received / onERC1155Received。
 *   若接收方为 Safe，则调用会进入 Safe 的 fallback，并路由到本 Handler；本合约实现上述回调并返回标准魔术值，NFT 合约才认为转账成功。
 * - onlyFallback 确保仅当调用来自 Safe 的 fallback（即 Safe 的 fallback handler 指向本合约）时才响应，避免被误挂到其他合约时接受任意调用。
 * - 魔术值来自 EIP-165 的 selector：onERC721Received → 0x150b7a02，onERC1155Received → 0xf23a6e61，onERC1155BatchReceived → 0xbc197c81。
 * - 本模块不处理 ERC-777 tokensReceived（ExtensibleFallbackHandler 未声明该接口）；若需 ERC-777 可另行扩展。
 * @author mfw78 <mfw78@rndlabs.xyz>
 * @notice 逻辑源自 https://github.com/safe-global/safe-contracts 的 TokenCallbackHandler，在此拆分为可组合的 mixin。
 */
abstract contract TokenCallbacks is ExtensibleBase, ERC1155TokenReceiver, ERC721TokenReceiver {
    /**
     * @notice ERC-1155 单笔转账接收回调：返回标准魔术值以通过 NFT 合约的检查。
     * @dev 仅允许经 Safe fallback 进入（onlyFallback）；参数由 ERC-1155 标准定义，本实现不解析。
     * @return 固定 0xf23a6e61（onERC1155Received 的 selector）。
     */
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view override onlyFallback returns (bytes4) {
        return 0xf23a6e61;
    }

    /**
     * @notice ERC-1155 批量转账接收回调：返回标准魔术值。
     * @dev 仅允许经 Safe fallback 进入；参数由 ERC-1155 标准定义。
     * @return 固定 0xbc197c81（onERC1155BatchReceived 的 selector）。
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external view override onlyFallback returns (bytes4) {
        return 0xbc197c81;
    }

    /**
     * @notice ERC-721 接收回调：返回标准魔术值以使 safeTransferFrom 成功。
     * @dev 仅允许经 Safe fallback 进入。
     * @return 固定 0x150b7a02（onERC721Received 的 selector）。
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view override onlyFallback returns (bytes4) {
        return 0x150b7a02;
    }
}
