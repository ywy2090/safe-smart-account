// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.4 <0.9.0;

/**
 * @title Safe Storage
 * @notice 声明 Safe 与 Proxy 共享的 storage 布局，供需要读写 Safe 状态的库（如 SignMessageLib）继承。
 * @dev 与 Safe 一起使用的库须将本合约作为第一个基类，保证与 Safe 的 slot 对齐。下为各 slot 含义简述。
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
