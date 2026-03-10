// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {SelfAuthorized} from "../common/SelfAuthorized.sol";
import {IFallbackManager} from "../interfaces/IFallbackManager.sol";
// solhint-disable-next-line no-unused-import
import {FALLBACK_HANDLER_STORAGE_SLOT} from "../libraries/SafeStorage.sol";

/**
 * @title Fallback Manager
 * @notice 管理对 Safe 的未知调用（fallback）：将调用转发到已设置的 handler，并在 calldata 末尾附加 msg.sender（20 字节）。
 * @dev handler 存于固定 storage slot，避免与 Safe 自身存储布局冲突。不能将 handler 设为 address(this)，否则可能被短 calldata 伪造函数签名攻击。
 * @author Richard Meissner - @rmeissner
 */
abstract contract FallbackManager is SelfAuthorized, IFallbackManager {
    /**
     * @notice 内部设置 fallback 处理器（setup 或 setFallbackHandler 调用）。
     * @param handler 处理 fallback 的合约地址；不能为 address(this)。
     */
    function internalSetFallbackHandler(address handler) internal {
        // 若 handler == this，攻击者可构造 3 字节 calldata + 攻击者地址 1 字节，拼成 4 字节函数选择器，误调 Safe 内部方法
        // Imagine we have a function like this:
        //
        //         function withdraw() internal authorized {
        //             withdrawalAddress.call.value(address(this).balance)("");
        //         }
        //
        // If the fallback method is triggered, the fallback handler appends the `msg.sender` address to the calldata and calls the fallback handler.
        // A potential attacker could call a Safe with the 3 bytes signature of a `withdraw` function. Since 3 bytes do not create a valid signature,
        // the call would end in a fallback handler. Since it appends the `msg.sender` address to the calldata, the attacker could craft an address
        // where the first 3 bytes of the previous calldata followed by the first byte of the attacker's address make up a valid function signature.
        // The subsequent call would result in unsanctioned access to Safe's internal protected methods. This happens as Solidity matches the first
        // 4 bytes of the calldata to a function signature, regardless if more data follows these 4 bytes.
        if (handler == address(this)) revertWithError("GS400");

        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            sstore(FALLBACK_HANDLER_STORAGE_SLOT, handler)
        }
        /* solhint-enable no-inline-assembly */
    }

    /**
     * @inheritdoc IFallbackManager
     */
    function setFallbackHandler(address handler) public override authorized {
        internalSetFallbackHandler(handler);
        emit ChangedFallbackHandler(handler);
    }

    /**
     * @inheritdoc IFallbackManager
     */
    // solhint-disable-next-line payable-fallback,no-complex-fallback
    fallback() external override {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            let handler := sload(FALLBACK_HANDLER_STORAGE_SLOT)
            if iszero(handler) {
                return(0, 0)
            }
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            // 在 calldata 副本末尾追加 caller() 的 20 字节（左移 96 位去零填充），供 handler 识别原始调用方
            mstore(add(ptr, calldatasize()), shl(96, caller()))
            // 有效 payload 长度 = 原 calldata 长度 + 20
            let success := call(gas(), handler, 0, ptr, add(calldatasize(), 20), 0, 0)

            returndatacopy(ptr, 0, returndatasize())
            if iszero(success) {
                revert(ptr, returndatasize())
            }
            return(ptr, returndatasize())
        }
        /* solhint-enable no-inline-assembly */
    }
}
