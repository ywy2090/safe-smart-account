// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title Signature Decoder
 * @notice 从 packed 签名字节数组中按位置解析出单条签名的 v、r、s。
 * @dev 每条签名 65 字节：r(32) || s(32) || v(1)。v 在 Safe 中还可表示类型：0=合约签名，1=预批准哈希，2=P-256 等。
 * @author Richard Meissner - @rmeissner
 */
abstract contract SignatureDecoder {
    /**
     * @notice 从 signatures 中第 pos 条签名起解析出 v, r, s（调用方需保证 pos*65+65 <= signatures.length）。
     * @param pos 第几条签名（从 0 开始）。
     * @param signatures 紧凑编码的签名序列。
     * @return v 恢复 id 或 Safe 扩展类型（0/1/2/27/28/>30）。
     * @return r 签名 r 分量。
     * @return s 签名 s 分量（合约签名时 s 存数据偏移）。
     */
    function signatureSplit(bytes memory signatures, uint256 pos) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            let signaturePos := mul(0x41, pos)
            r := mload(add(signatures, add(signaturePos, 0x20)))
            s := mload(add(signatures, add(signaturePos, 0x40)))
            v := byte(0, mload(add(signatures, add(signaturePos, 0x60))))
        }
        /* solhint-enable no-inline-assembly */
    }
}
