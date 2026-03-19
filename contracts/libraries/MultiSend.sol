// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title Multi Send
 * @notice 将多笔交易打包为一次调用；通常由 Safe 通过 DELEGATECALL 调用，在 Safe 上下文中顺序执行每笔子交易。
 * @dev
 * ═══════════════════════════════════════════════════════════════════════════════
 * transactions 编码方式：紧密打包（packed），非 ABI 编码
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * 使用 packed 编码（等同 abi.encodePacked / solidityPacked），不是 abi.encode。
 * - ABI 编码：每个参数按 32 字节对齐、有 padding（如 address 占 32 字节）。
 * - 此处：operation 1 字节、to 20 字节 无 padding，仅 value/dataLength 为 32 字节。
 *
 * 为何不用 ABI 编码：
 *   1. 更省 calldata：单笔至少省 (32-1)+(32-20)=43 字节，多笔累加后 calldata 更小，gas 更低。
 *   2. 批量场景下差异明显：多笔子交易时，每笔少几十字节会显著降低链上数据与费用（尤其 L2/calldata 计价）。
 *
 * 多笔子交易直接拼接：  encoded_tx_1 || encoded_tx_2 || ...
 *
 * 单笔子交易布局（每段连续，无分隔符）：
 *
 *   offset    length    type      说明
 *   ─────────────────────────────────────────────────────────────────────────
 *   0         1        uint8     operation：0 = CALL，1 = DELEGATECALL
 *   1         20       address   to：目标地址；全 0 时本合约内视为 address(this)
 *   21        32       uint256   value：仅 CALL 有效（wei），DELEGATECALL 忽略
 *   53        32       uint256   dataLength：后续 data 的字节数
 *   85        dataLen  bytes     data：本次调用的 calldata（selector + 参数等）
 *
 * 单笔总长 = 85 + dataLength；下一笔从 85 + dataLength 处开始。
 *
 * 编码示例（与 src/utils/multisend.ts 一致，必须用 packed 而非 abi.encode）：
 *   ethers.solidityPacked(["uint8","address","uint256","uint256","bytes"],
 *                         [operation, to, value, data.length, data])
 * 多笔：将每笔上述 packed 编码的十六进制拼接后作为 bytes 传入。
 *
 * 任一子交易失败则整体 revert，并携带该笔调用的 returndata。
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 * @author Nick Dodson, Gonçalo Sá, Stefan George, Richard Meissner
 */
contract MultiSend {
    // 单例地址，用于校验必须通过 DELEGATECALL 调用（address(this) != MULTISEND_SINGLETON 时说明在 proxy 中）
    address private immutable MULTISEND_SINGLETON;

    constructor() {
        MULTISEND_SINGLETON = address(this);
    }

    /**
     * @notice 顺序执行多笔交易，任一笔失败则 revert。
     * @param transactions 多笔子交易紧密拼接的 bytes。单笔布局（与 assembly 中偏移一致）：
     *                     [i+0x00] operation  1 字节  (0=CALL, 1=DELEGATECALL)
     *                     [i+0x01] to        20 字节 (0 表示 address(this))
     *                     [i+0x15] value     32 字节
     *                     [i+0x35] dataLength 32 字节
     *                     [i+0x55] data      dataLength 字节
     *                     下一笔起始下标 i' = i + 0x55 + dataLength。
     */
    function multiSend(bytes memory transactions) public payable {
        require(address(this) != MULTISEND_SINGLETON, "MultiSend should only be called via delegatecall");
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            let length := mload(transactions)
            let i := 0x20
            for {
                // Pre block is not used in "while mode"
            } lt(i, length) {
                // Post block is not used in "while mode"
            } {
                // First byte of the data is the operation.
                // We shift by 248 bits (256 - 8 [operation byte]) right, since mload will always load 32 bytes (a word).
                // This will also zero out unused data.
                let operation := shr(0xf8, mload(add(transactions, i)))
                // We offset the load address by 1 byte (operation byte)
                // We shift it right by 96 bits (256 - 160 [20 address bytes]) to right-align the data and zero out unused data.
                let to := shr(0x60, mload(add(transactions, add(i, 0x01))))
                // Defaults `to` to `address(this)` if `address(0)` is provided.
                to := or(to, mul(iszero(to), address()))
                // We offset the load address by 21 byte (operation byte + 20 address bytes)
                let value := mload(add(transactions, add(i, 0x15)))
                // We offset the load address by 53 byte (operation byte + 20 address bytes + 32 value bytes)
                let dataLength := mload(add(transactions, add(i, 0x35)))
                // We offset the load address by 85 byte (operation byte + 20 address bytes + 32 value bytes + 32 data length bytes)
                let data := add(transactions, add(i, 0x55))
                let success := 0
                switch operation
                case 0 {
                    success := call(gas(), to, value, data, dataLength, 0, 0)
                }
                case 1 {
                    success := delegatecall(gas(), to, data, dataLength, 0, 0)
                }
                if iszero(success) {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
                // Next entry starts at 85 byte + data length
                i := add(i, add(0x55, dataLength))
            }
        }
        /* solhint-enable no-inline-assembly */
    }
}
