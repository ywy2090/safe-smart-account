// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title ERC721TokenReceiver
 * @notice ERC-721 安全转账的接收者回调接口：实现此接口的合约可安全接收 NFT（safeTransferFrom 会调用 onERC721Received）。
 * @dev ERC-165 接口 ID: 0x150b7a02。必须返回魔数 0x150b7a02 表示接受转账，否则转账会被 revert。
 */
interface ERC721TokenReceiver {
    /**
     * @notice 当 NFT 通过 safeTransferFrom 转入本合约时，由 ERC721 合约调用。
     * @dev 接受转账时必须返回 bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")) = 0x150b7a02；返回其他值或 revert 将导致转账回滚。调用方（msg.sender）为 NFT 合约地址。
     * @param _operator 执行 safeTransferFrom 的地址（operator）。
     * @param _from 转出方地址。
     * @param _tokenId 被转移的 NFT 的 tokenId。
     * @param _data 附加数据（由调用方传入，无固定格式）。
     * @return 接受时返回 0x150b7a02，否则 revert 或返回其他值以使转账失败。
     */
    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes calldata _data) external returns (bytes4);
}
