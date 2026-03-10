// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity >=0.7.0 <0.9.0;

/**
 * @title Error Message
 * @notice 使用固定的 5 字节错误码（如 GS001）进行 revert，便于前端与索引解析。
 * @dev 仅支持恰好 5 字节的错误串；用 assembly 构造 Error(string) 的 revert 数据，比直接 revert(string) 更省 gas 与字节码。
 * @author Shebin John - @remedcu
 */
abstract contract ErrorMessage {
    /**
     * @notice 以 Safe 5 字节错误码 revert（如 "GS001"）。
     * @param error 5 字节错误标识，通常为 "GS" + 三位数字。
     */
    function revertWithError(bytes5 error) internal pure {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x08c379a000000000000000000000000000000000000000000000000000000000) // Selector for method "Error(string)".
            mstore(add(ptr, 0x04), 0x20) // String offset.
            mstore(add(ptr, 0x24), 0x05) // Revert reason length (5 bytes for bytes5).
            mstore(add(ptr, 0x44), error) // Revert reason.
            revert(ptr, 0x64) // Revert data length is 4 bytes for selector + offset + error length + error.
        }
        /* solhint-enable no-inline-assembly */
    }
}
