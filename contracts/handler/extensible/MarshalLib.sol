// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

library MarshalLib {
    // 打包格式（bytes32）：
    // [1 byte flags][4 bytes selector(可选)][7 bytes reserved][20 bytes handler address]
    // 其中 flags 的最低语义是：0x00=static(view), 0x01=non-static。
    /**
     * Encode a method handler into a `bytes32` value
     * @dev The first byte of the `bytes32` value is set to 0x01 if the method is not static (`view`)
     * @dev The last 20 bytes of the `bytes32` value are set to the address of the handler contract
     * @param isStatic Whether the method is static (`view`) or not
     * @param handler The address of the handler contract implementing the `IFallbackMethod` or `IStaticFallbackMethod` interface
     */
    function encode(bool isStatic, address handler) internal pure returns (bytes32 data) {
        // 仅编码 flags + handler 地址。
        data = bytes32(uint256(uint160(handler)) | (isStatic ? 0 : (1 << 248)));
    }

    /**
     * Encode a method handler into a `bytes32` value with a selector
     * @dev The first byte of the `bytes32` value is set to 0x01 if the method is not static (`view`)
     * @dev The next 4 bytes of the `bytes32` value are set to the selector of the method
     * @dev The last 20 bytes of the `bytes32` value are set to the address of the handler contract
     * @param isStatic Whether the method is static (`view`) or not
     * @param selector The selector of the method
     * @param handler The address of the handler contract implementing the `IFallbackMethod` or `IStaticFallbackMethod` interface
     */
    function encodeWithSelector(bool isStatic, bytes4 selector, address handler) internal pure returns (bytes32 data) {
        // 在 encode 基础上额外把 selector 放到高位区间，便于批量导入接口映射。
        data = bytes32(uint256(uint160(handler)) | (isStatic ? 0 : (1 << 248)) | (uint256(uint32(selector)) << 216));
    }

    /**
     * Given a `bytes32` value, decode it into a method handler and return it
     * @param data The packed data to decode
     * @return isStatic Whether the method is static (`view`) or not
     * @return handler The address of the handler contract implementing the `IFallbackMethod` or `IStaticFallbackMethod` interface
     */
    function decode(bytes32 data) internal pure returns (bool isStatic, address handler) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            // 左侧最高字节为 0 表示 static；非 0 表示 non-static。
            isStatic := iszero(shr(248, data))
            // 低 20 字节为处理器地址。
            handler := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
        /* solhint-enable no-inline-assembly */
    }

    /**
     * Given a `bytes32` value, decode it into a method handler and return it
     * @param data The packed data to decode
     * @return isStatic Whether the method is static (`view`) or not
     * @return selector The selector of the method
     * @return handler The address of the handler contract implementing the `IFallbackMethod` or `IStaticFallbackMethod` interface
     */
    function decodeWithSelector(bytes32 data) internal pure returns (bool isStatic, bytes4 selector, address handler) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            // 左侧最高字节为 0 表示 static；非 0 表示 non-static。
            isStatic := iszero(shr(248, data))
            // 低 20 字节为处理器地址。
            handler := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            // 取中间 4 字节 selector。
            selector := shl(168, shr(160, data))
        }
        /* solhint-enable no-inline-assembly */
    }
}
