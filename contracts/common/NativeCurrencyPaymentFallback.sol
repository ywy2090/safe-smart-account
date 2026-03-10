// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {INativeCurrencyPaymentFallback} from "./../interfaces/INativeCurrencyPaymentFallback.sol";

/**
 * @title Native Currency Payment Fallback
 * @notice 允许 Safe 直接接收原生币（ETH）：对合约的纯 value 转账会触发 receive 并发出 SafeReceived 事件。
 * @author Richard Meissner - @rmeissner
 */
abstract contract NativeCurrencyPaymentFallback is INativeCurrencyPaymentFallback {
    /** 接收原生币时发出 SafeReceived(sender, value) */
    receive() external payable override {
        emit SafeReceived(msg.sender, msg.value);
    }
}
