// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title ERC1155TokenReceiver
 * @notice ERC-1155 安全转账的接收者回调接口：实现后可在 safeTransferFrom / safeBatchTransferFrom 时被 NFT 合约调用以接受或拒绝转账。
 * @dev ERC-165 接口 ID: 0x4e2312e0。单笔接收需返回 0xf23a6e61，批量接收需返回 0xbc197c81，否则调用方会 revert。
 */
interface ERC1155TokenReceiver {
    /**
     * @notice 单笔 ERC-1155 安全转账完成后，由代币合约在接收方合约上调用。
     * @dev 接受时必须返回 bytes4(keccak256("onERC1155Received(...)")) = 0xf23a6e61；拒绝可 revert；返回其他值会导致调用方 revert。
     * @param _operator 发起转账的地址（msg.sender 为代币合约）。
     * @param _from 转出方。
     * @param _id 代币 ID。
     * @param _value 转账数量。
     * @param _data 附加数据。
     * @return 接受时返回 0xf23a6e61。
     */
    function onERC1155Received(
        address _operator,
        address _from,
        uint256 _id,
        uint256 _value,
        bytes calldata _data
    ) external returns (bytes4);

    /**
     * @notice 批量 ERC-1155 安全转账完成后，由代币合约在接收方合约上调用。
     * @dev 接受时必须返回 bytes4(keccak256("onERC1155BatchReceived(...)")) = 0xbc197c81；拒绝可 revert；返回其他值会导致调用方 revert。_ids 与 _values 长度与顺序需一致。
     * @param _operator 发起批量转账的地址。
     * @param _from 转出方。
     * @param _ids 各代币 ID 数组。
     * @param _values 各代币数量数组（与 _ids 一一对应）。
     * @param _data 附加数据。
     * @return 接受时返回 0xbc197c81。
     */
    function onERC1155BatchReceived(
        address _operator,
        address _from,
        uint256[] calldata _ids,
        uint256[] calldata _values,
        bytes calldata _data
    ) external returns (bytes4);
}
