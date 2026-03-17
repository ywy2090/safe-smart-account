// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title ERC777TokensRecipient
 * @notice ERC-777 代币的接收者钩子接口：当 ERC-777 代币转入本合约时，代币合约会调用 tokensReceived，以便接收方执行逻辑（如记账、拒绝等）。
 * @dev 实现此接口的合约方可被 ERC-777 在 transfer/send/mint 等操作后回调；未实现则可能无法正确接收或会 revert（视具体代币实现而定）。
 */
interface ERC777TokensRecipient {
    /**
     * @notice 在 ERC-777 代币完成一次转账或铸币后，由代币合约在接收方（to）上调用。
     * @param operator 执行本次转账或铸币的 operator 地址。
     * @param from 发送方地址（铸币时为 0）。
     * @param to 接收方地址（通常为 address(this)）。
     * @param amount 转账或铸币的数量。
     * @param data 发送方在 transfer 时传入的 data。
     * @param operatorData operator 传入的附加数据。
     */
    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata data,
        bytes calldata operatorData
    ) external;
}
