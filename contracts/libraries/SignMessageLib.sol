// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ISafe} from "./../interfaces/ISafe.sol";
import {SafeStorage} from "./SafeStorage.sol";

/**
 * @title Sign Message Library
 * @notice 供 Safe 通过 DELEGATECALL 使用的链上签名库：将任意消息哈希标记为“已由该 Safe 签名”，可用于 EIP-1271 验证。
 * @dev 继承 SafeStorage 以与 Safe 共享 storage，写入 signedMessages[msgHash]=1。验证时可用 getMessageHash(message) 得到 hash，再检查 signedMessages[hash]!=0 或 EIP-1271 isValidSignature(hash, "")。
 * @author Richard Meissner - @rmeissner
 */
contract SignMessageLib is SafeStorage {
    // EIP-712 类型哈希：keccak256("SafeMessage(bytes message)")
    bytes32 private constant SAFE_MSG_TYPEHASH = 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;

    event SignMsg(bytes32 indexed msgHash);

    /**
     * @notice 将 _data 对应的 EIP-712 SafeMessage 哈希标记为已签名（signedMessages[hash]=1）。
     * @param _data 待签名的消息，任意字节（无规定编码格式）。库内会先算 getMessageHash(_data)，再写入 signedMessages。
     *
     *      编码方式与哈希计算：
     *      - _data 不做格式约定：可为任意 bytes（如 UTF-8 文本、十六进制、ABI 编码结果、或已哈希的 32 字节等）。
     *      - 实际写入的为 EIP-712 哈希：getMessageHash(_data) = keccak256(0x19 0x01 || domainSeparator || structHash)，
     *        其中 structHash = keccak256(SAFE_MSG_TYPEHASH || keccak256(_data))，类型为 SafeMessage(bytes message)。
     *      - 验证时（含 EIP-1271）必须用与签名时相同的 _data 调用 getMessageHash(_data)，得到同一 hash 后查 signedMessages[hash] 或 isValidSignature(hash, "")。
     *
     *      调用方须为 Safe 自身（通过 Safe 的 execTransaction 对本库做 DELEGATECALL）。
     */
    function signMessage(bytes calldata _data) external {
        bytes32 msgHash = getMessageHash(_data);
        signedMessages[msgHash] = 1;
        emit SignMsg(msgHash);
    }

    /**
     * @notice 计算与 Safe 的 domainSeparator 一致的 SafeMessage 哈希，供签名或验证使用。
     * @param message 原始消息字节。
     * @return 符合 EIP-712 的 message hash（含 0x19 0x01 domainSeparator typeHash messageHash）。
     */
    function getMessageHash(bytes memory message) public view returns (bytes32) {
        bytes32 safeMessageHash = keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(message)));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), ISafe(payable(address(this))).domainSeparator(), safeMessageHash));
    }
}
