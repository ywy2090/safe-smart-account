// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title Singleton
 * @notice 作为 Safe 实现合约的基类，必须作为继承链中的第一个父合约。
 * @dev 与 SafeProxy 存储布局耦合：Proxy 的 slot0 存 singleton 地址，delegatecall 后实现合约的 storage 写回 proxy，
 *      因此本合约第一个 storage 变量必须为 singleton 且单独占 32 字节，与 Proxy 的 slot0 一致。
 * @author Richard Meissner - @rmeissner
 */
abstract contract Singleton {
    // 与 SafeProxy.singleton 同 slot，实现合约中不读写，仅占位保证布局一致
    address private singleton;
}
