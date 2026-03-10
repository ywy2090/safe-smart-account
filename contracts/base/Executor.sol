// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;
import {Enum} from "../interfaces/Enum.sol";

/**
 * @title Executor
 * @notice 执行单笔调用的抽象基类：支持 CALL 与 DELEGATECALL。
 * @dev 不校验 to 是否有代码、data 是否合法，由调用方保证。CALL 时 value 会转给 to；DELEGATECALL 时 value 被忽略，在当前合约上下文中执行 to 的代码。
 * @author Richard Meissner - @rmeissner
 */
abstract contract Executor {
    /**
     * @notice 使用指定 gas 执行 CALL 或 DELEGATECALL。
     * @param to 目标地址（CALL 时接收 value，DELEGATECALL 时仅提供代码）。
     * @param value 仅 CALL 有效，发送给 to 的 wei 数；DELEGATECALL 时忽略。
     * @param data 调用数据，内存布局：前 32 字节为 length，随后为 payload。
     * @param operation Call(0) 或 DelegateCall(1)。
     * @param txGas 传递给 call/delegatecall 的 gas。
     * @return success 调用是否成功（不 revert 即 true，不解析 return data）。
     */
    function execute(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        uint256 txGas
    ) internal returns (bool success) {
        if (operation == Enum.Operation.DelegateCall) {
            // DELEGATECALL：在当前合约上下文中执行 to 的代码，storage/msg.sender 不变，不转 value
            /* solhint-disable no-inline-assembly */
            /// @solidity memory-safe-assembly
            assembly {
                success := delegatecall(txGas, to, add(data, 0x20), mload(data), 0, 0)
            }
            /* solhint-enable no-inline-assembly */
        } else {
            // CALL：向 to 发送 value wei 并执行 data，返回值不写入 memory
            /* solhint-disable no-inline-assembly */
            /// @solidity memory-safe-assembly
            assembly {
                success := call(txGas, to, value, add(data, 0x20), mload(data), 0, 0)
            }
            /* solhint-enable no-inline-assembly */
        }
    }
}
