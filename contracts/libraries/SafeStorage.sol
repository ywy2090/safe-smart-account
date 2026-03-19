// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.4 <0.9.0;

/**
 * @title SafeStorage
 * @notice 声明与 Safe 一致的 storage 布局，供通过 DELEGATECALL 使用 Safe 状态的库（如 SignMessageLib、SafeToL2Setup、SafeMigration）继承。
 * @dev
 * ─── 如何保证与 Safe 布局一致 ───
 * Safe 自身不继承本合约；其布局由继承链顺序决定：
 *   Singleton (slot 0) → ModuleManager (slot 1) → OwnerManager (slot 2,3,4) → Safe 自身 (slot 5...)
 * 本合约将上述同一批变量按同一顺序声明，形成“镜像布局”。一致性靠约定与代码评审保证：
 *   1. 修改 Safe 继承顺序或新增/调整状态变量时，须同步更新本合约中的变量列表与顺序。
 *   2. 通过 DELEGATECALL 读写 Safe 状态的库必须将 SafeStorage 作为第一个基类继承，
 *      这样编译器分配的 slot 与本合约一致，进而与 Safe 一致。
 * 下方常量（FALLBACK_HANDLER_STORAGE_SLOT 等）为命名 slot，与顺序布局无关，由各 Manager 按名使用。
 * @author Richard Meissner - @rmeissner
 */
abstract contract SafeStorage {
    // slot 0：与 Proxy.singleton 对齐，实现合约中由 Singleton 占用
    address internal singleton;
    // 模块链表：modules[sentinel]=首模块，modules[module]=下一模块
    mapping(address => address) internal modules;
    // owner 链表：owners[sentinel]=首 owner，owners[owner]=下一 owner
    mapping(address => address) internal owners;
    // owner 数量
    uint256 internal ownerCount;
    // 所需签名数
    uint256 internal threshold;
    // 交易 nonce，每笔 execTransaction 自增
    uint256 internal nonce;
    // 已废弃的 domain separator 槽位，保留布局兼容
    bytes32 internal _deprecatedDomainSeparator;
    // 已链上签名的消息哈希：signedMessages[hash]!=0 表示已签
    mapping(bytes32 => uint256) internal signedMessages;
    // owner 预批准的哈希：approvedHashes[owner][hash]!=0 表示该 owner 已批准
    mapping(address => mapping(bytes32 => uint256)) internal approvedHashes;
}

// Fallback 处理器地址所在 storage slot：keccak256("fallback_manager.handler.address")
bytes32 constant FALLBACK_HANDLER_STORAGE_SLOT = 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

// Transaction Guard 地址所在 storage slot：keccak256("guard_manager.guard.address")
bytes32 constant GUARD_STORAGE_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;

// Module Guard 地址所在 storage slot：keccak256("module_manager.module_guard.address")
bytes32 constant MODULE_GUARD_STORAGE_SLOT = 0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947;
