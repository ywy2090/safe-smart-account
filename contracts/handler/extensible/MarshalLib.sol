// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title MarshalLib
 * @notice 将 Extensible Fallback Handler 的「方法路由」编码为单个 bytes32，便于在 mapping 中存储与解码。
 * @dev
 * ═══════════════════════════════════════════════════════════════════════════════
 * 打包格式（bytes32，从高到低）
 * ═══════════════════════════════════════════════════════════════════════════════
 * - 字节 31（最高）：flags。0x00 = static(view)，0x01 = non-static。
 * - 字节 28–27（仅 encodeWithSelector/decodeWithSelector）：4 字节 selector，用于批量注册时校验 interfaceId。
 * - 字节 19–0（低 20 字节）：handler 合约地址（20 字节）。
 * 未存储 selector 的 encode/decode 仅用 1 字节 + 20 字节，中间为 0；decodeWithSelector 从固定偏移读取 4 字节。
 * ═══════════════════════════════════════════════════════════════════════════════
 */
library MarshalLib {
    /**
     * @notice 将 isStatic 与 handler 地址编码为一个 bytes32。
     * @dev 用于 ExtensibleBase.safeMethods 的写入与 ERC165Handler 在批量注册后写入的条目（仅需 isStatic + handler）。
     * @param isStatic true 表示 view 处理器（IStaticFallbackMethod），false 表示可写处理器（IFallbackMethod）。
     * @param handler 实现 IFallbackMethod 或 IStaticFallbackMethod 的合约地址。
     * @return data 编码后的 bytes32，可直接存入 safeMethods[safe][selector]。
     */
    function encode(bool isStatic, address handler) internal pure returns (bytes32 data) {
        data = bytes32(uint256(uint160(handler)) | (isStatic ? 0 : (1 << 248)));
    }

    /**
     * @notice 将 isStatic、selector、handler 编码为一个 bytes32（用于批量注册时带 selector 的条目）。
     * @dev ERC165Handler.addSupportedInterfaceBatch 传入的 handlerWithSelectors 中每一项可由此编码，
     *      解码时用 decodeWithSelector 取出 selector 并校验 XOR(selectors) == interfaceId。
     * @param isStatic 是否为 view 处理器。
     * @param selector 4 字节函数选择器，编码在字节 28–27（左移 216 位）。
     * @param handler 处理器合约地址。
     * @return data 编码后的 bytes32。
     */
    function encodeWithSelector(bool isStatic, bytes4 selector, address handler) internal pure returns (bytes32 data) {
        data = bytes32(uint256(uint160(handler)) | (isStatic ? 0 : (1 << 248)) | (uint256(uint32(selector)) << 216));
    }

    /**
     * @notice 从 bytes32 解码出 isStatic 与 handler，不包含 selector。
     * @dev 用于 fallback 路由时根据 safeMethods[safe][msg.sig] 取得处理器类型与地址。
     * @param data 由 encode 或 encodeWithSelector 产生的 packed 数据。
     * @return isStatic 最高字节非 0 则为 false（non-static），否则为 true（static）。
     * @return handler 低 20 字节表示的地址。
     */
    function decode(bytes32 data) internal pure returns (bool isStatic, address handler) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            isStatic := iszero(shr(248, data))
            handler := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
        /* solhint-enable no-inline-assembly */
    }

    /**
     * @notice 从 bytes32 解码出 isStatic、selector、handler（用于批量接口注册时的校验与路由写入）。
     * @dev selector 从字节 27–24 取出（shr 160 得高 12 字节，再 shl 168 使 4 字节对齐到右侧）。
     * @param data 由 encodeWithSelector 产生的 packed 数据。
     * @return isStatic 是否为 view 处理器。
     * @return selector 4 字节方法选择器。
     * @return handler 处理器合约地址。
     */
    function decodeWithSelector(bytes32 data) internal pure returns (bool isStatic, bytes4 selector, address handler) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            isStatic := iszero(shr(248, data))
            handler := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            selector := shl(168, shr(160, data))
        }
        /* solhint-enable no-inline-assembly */
    }
}
