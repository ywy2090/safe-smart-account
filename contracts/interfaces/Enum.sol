// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title Enum
 * @notice Safe 智能账户使用的枚举类型定义（如交易执行方式）。
 * @author @safe-global/safe-protocol
 */
library Enum {
    /**
     * @notice 交易执行方式：用于 execTransaction / execTransactionFromModule 等。
     * @dev Call(0)：CALL，从 Safe 向 to 转 value 并执行 to 的代码，状态变更发生在 to；DelegateCall(1)：DELEGATECALL，在 Safe 的存储与余额上下文中执行 to 的代码，无 value 转移，状态写入 Safe。
     */
    enum Operation {
        Call,        // 0: 使用 CALL
        DelegateCall // 1: 使用 DELEGATECALL
    }
}
