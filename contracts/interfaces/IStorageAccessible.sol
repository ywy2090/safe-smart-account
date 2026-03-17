// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title IStorageAccessible
 * @notice 存储可访问接口：允许只读访问合约存储，以及在本合约上下文中“模拟执行”目标合约调用（通过 revert 携带结果，不产生实际状态变更）。
 * @dev 用于调试、链下工具或其他合约在只读上下文中模拟对 Safe 的调用；simulateAndRevert 的返回数据格式为 success:uint256 || response.length:uint256 || response:bytes。
 * @author @safe-global/safe-protocol
 */
interface IStorageAccessible {
    /**
     * @notice 从当前合约存储中读取一段数据（按“字”为单位，每字 32 字节）。
     * @param offset 起始字偏移（从 0 开始）。
     * @param length 要读取的字数。
     * @return 读取到的字节（length * 32 字节）。
     */
    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory);

    /**
     * @notice 在“本合约”的上下文中对 targetContract 执行 DELEGATECALL，然后 revert 并将执行结果编码到 revert data 中，不保留任何状态变更。
     * @dev 调用方需 catch revert 并解析 data：abi.encodePacked(success:uint256, response.length:uint256, response:bytes)。
     * @param targetContract 要执行的目标合约地址。
     * @param calldataPayload 发给目标合约的 calldata（函数选择器 + 参数）。
     */
    function simulateAndRevert(address targetContract, bytes memory calldataPayload) external;
}
