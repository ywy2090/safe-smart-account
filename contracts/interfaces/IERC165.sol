// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title IERC165
 * @notice ERC-165 接口检测：查询合约是否实现某接口。
 * @dev interfaceId 通常为接口中函数选择器的 XOR（单函数接口即为该函数 selector）。
 *      详见 EIP-165: https://eips.ethereum.org/EIPS/eip-165
 *      本调用应消耗少于 30_000 gas。
 */
interface IERC165 {
    /**
     * @notice 查询本合约是否实现 interfaceId 所标识的接口。
     * @param interfaceId 接口 ID（一般为函数 selector 或若干 selector 的 XOR）。
     * @return 实现该接口返回 true，否则 false。
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
