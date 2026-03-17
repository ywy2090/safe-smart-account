// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title ISignatureValidatorConstants
 * @notice EIP-1271 签名校验所需的魔数常量。
 * @dev 合约若实现 EIP-1271，isValidSignature 在签名有效时必须返回此魔数。
 */
abstract contract ISignatureValidatorConstants {
    /**
     * @notice EIP-1271 规定的“签名有效”返回值。
     * @dev 即 bytes4(keccak256("isValidSignature(bytes32,bytes)")) = 0x1626ba7e。
     */
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;
}

/**
 * @title ISignatureValidator
 * @notice EIP-1271 合约签名校验接口：允许合约以“智能合约钱包”身份对给定哈希和签名进行校验。
 * @dev Safe 在验证多签时，若 owner 为合约，会调用其 isValidSignature；返回 EIP1271_MAGIC_VALUE 视为该 owner 已签名。
 *      实现不得修改状态，可允许外部只读调用。
 */
abstract contract ISignatureValidator is ISignatureValidatorConstants {
    /**
     * @notice 校验 _signature 是否为 address(this) 对 _hash 的有效签名。
     * @dev 通过时必须返回 EIP1271_MAGIC_VALUE (0x1626ba7e)；revert 或返回其他值均视为无效。
     * @param _hash 被签名的数据哈希（如 Safe 交易哈希或消息哈希）。
     * @param _signature 签名字节（格式由实现定义，如 ECDSA 或多重签名的打包格式）。
     * @return 签名有效时返回 EIP1271_MAGIC_VALUE，否则 revert 或返回其他值。
     */
    function isValidSignature(bytes32 _hash, bytes memory _signature) external view virtual returns (bytes4);
}
