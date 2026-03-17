// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title INativeCurrencyPaymentFallback
 * @notice 接收原生代币（ETH/BNB 等）的接口：当向合约直接转账且无 calldata 时由 receive() 处理。
 * @dev 与 fallback() 区别：receive 仅在 msg.data 为空且存在 value 时被调用；fallback 处理带 data 或无法匹配函数的情况。
 * @author @safe-global/safe-protocol
 */
interface INativeCurrencyPaymentFallback {
    /**
     * @notice 合约收到原生代币时触发。
     * @param sender 发送方地址。
     * @param value 收到的原生代币数量（wei）。
     */
    event SafeReceived(address indexed sender, uint256 value);

    /**
     * @notice 接收原生代币的入口；无 calldata 的转账会调用此函数。
     * @dev 实现中应发出 SafeReceived(sender, value) 以便追踪。
     */
    receive() external payable;
}
