// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ERC1155TokenReceiver} from "../interfaces/ERC1155TokenReceiver.sol";
import {ERC721TokenReceiver} from "../interfaces/ERC721TokenReceiver.sol";
import {ERC777TokensRecipient} from "../interfaces/ERC777TokensRecipient.sol";
import {IERC165} from "../interfaces/IERC165.sol";
import {HandlerContext} from "./HandlerContext.sol";

/**
 * @title TokenCallbackHandler
 * @notice 代币回调处理器：当 Safe 被设为 Fallback Handler 时，使 Safe 能正确接收 ERC-721 / ERC-1155 / ERC-777 的 safeTransfer 或 send。
 * @dev
 * 调用路径（以 ERC-721 safeTransferFrom 为例）：
 *   1. 用户对 ERC721 调用 safeTransferFrom(..., safeAddress)，接收方为 Safe。
 *   2. ERC721 合约在转账后对“接收方”调用 onERC721Received(operator, from, tokenId, data)，此时接收方是 Safe 地址。
 *   3. Safe 没有实现 onERC721Received，调用落入 fallback；FallbackManager 将 calldata 转发给已配置的 handler（本合约）。
 *   4. 本合约 onERC721Received 被调用，msg.sender 为 Safe；仅当 Safe 的 fallback handler 确为本合约时（onlyFallback）才返回魔数 0x150b7a02。
 *   5. ERC721 收到魔数后视作接收成功，NFT 余额记在 Safe 上。
 *
 * 因此本合约不持有代币，代币始终在“调用本合约的 Safe”上；本合约仅实现回调接口并返回接受魔数。
 *
 * ⚠️ 警告：本合约自身也实现了这些回调。若有人将代币直接转到本合约地址（而非 Safe），代币会锁死在本合约内，无法转出。勿向本合约地址转代币。
 * @author Richard Meissner - @rmeissner
 */
contract TokenCallbackHandler is HandlerContext, ERC1155TokenReceiver, ERC777TokensRecipient, ERC721TokenReceiver, IERC165 {
    /**
     * @notice ERC-1155 单笔 safeTransferFrom 的接收回调；返回魔数表示接受。
     * @dev 仅当通过 Safe 的 fallback 调用时（onlyFallback）才返回 0xf23a6e61，否则 revert，避免被非 Safe 直接调用滥用。
     *      参数未使用，接口要求保留签名。
     * @return 0xf23a6e61 = selector(onERC1155Received(address,address,uint256,uint256,bytes))
     */
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view override onlyFallback returns (bytes4) {
        return 0xf23a6e61;
    }

    /**
     * @notice ERC-1155 批量 safeBatchTransferFrom 的接收回调；返回魔数表示接受。
     * @dev 仅当通过 Safe 的 fallback 调用时（onlyFallback）才返回 0xbc197c81。
     * @return 0xbc197c81 = selector(onERC1155BatchReceived(address,address,uint256[],uint256[],bytes))
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
     * @notice ERC-721 safeTransferFrom 的接收回调；返回魔数表示接受。
     * @dev 仅当通过 Safe 的 fallback 调用时（onlyFallback）才返回 0x150b7a02，使 NFT 记入 Safe 而非本合约。
     * @return 0x150b7a02 = selector(onERC721Received(address,address,uint256,bytes))
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view override onlyFallback returns (bytes4) {
        return 0x150b7a02;
    }

    /**
     * @notice ERC-777 tokensReceived 钩子；空实现即可满足接口，使 Safe 可接收 ERC-777。
     * @dev 仅为接口完整实现，无额外逻辑。若使用 ERC-777，接收方（Safe）可能还需在 ERC-1820 注册表中
     *      注册本合约为 implementer（依具体代币与标准要求）。
     */
    function tokensReceived(address, address, address, uint256, bytes calldata, bytes calldata) external pure override {
        // 接口要求存在，无额外逻辑
    }

    /**
     * @notice 声明本合约实现的接口，供 ERC-165 查询（如代币合约在转账前检查接收方是否支持回调）。
     * @dev 返回 ERC1155TokenReceiver、ERC721TokenReceiver、IERC165 的 interfaceId；未包含 ERC777TokensRecipient，
     *      因 ERC-777 常用 ERC-1820 注册表而非 ERC-165 查询。
     * @param interfaceId 接口 ID（4 字节 selector 或 XOR 组合）。
     * @return 若支持该接口返回 true。
     */
    function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
        return
            interfaceId == type(ERC1155TokenReceiver).interfaceId ||
            interfaceId == type(ERC721TokenReceiver).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}
