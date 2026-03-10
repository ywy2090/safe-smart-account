// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title Enum
 * @notice Safe 智能账户使用的枚举集合。
 * @author @safe-global/safe-protocol
 */
library Enum {
    /**
     * @notice 交易执行方式：Call(0) 使用 CALL 向目标转 value 并执行；DelegateCall(1) 使用 DELEGATECALL 在 Safe 上下文中执行目标代码。
     * @custom:variant Call 使用 CALL 操作码执行。
     * @custom:variant Delegatecall 使用 DELEGATECALL 操作码执行。
     */
    enum Operation {
        Call,
        DelegateCall
    }
}
