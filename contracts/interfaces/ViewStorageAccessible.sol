// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.5.0 <0.9.0;

/**
 * @title ViewStorageAccessible
 * @notice 在 IStorageAccessible 基础上的“视图版”模拟接口：允许在 view 函数中调用 simulate，从只读上下文模拟对目标合约的调用。
 * @dev 实现需保证模拟过程不修改状态，否则应 revert；适用于在 view 中预估调用结果（如 Safe 的 execTransaction 结果）。
 *      源自 Gnosis util-contracts 的 StorageAccessible 视图扩展。
 */
interface ViewStorageAccessible {
    /**
     * @notice 在 view 上下文中模拟对 targetContract 的调用，返回目标调用的返回数据。
     * @dev 若被模拟的调用尝试修改状态，应 revert；这样可从外部 view 中安全地做“只读模拟”。
     * @param targetContract 被模拟调用的目标合约地址。
     * @param calldataPayload 发给目标合约的 calldata。
     * @return 目标调用的 return data。
     */
    function simulate(address targetContract, bytes calldata calldataPayload) external view returns (bytes memory);
}
