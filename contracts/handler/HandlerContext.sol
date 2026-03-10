// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ISafe} from "../interfaces/ISafe.sol";
import {FALLBACK_HANDLER_STORAGE_SLOT} from "../libraries/SafeStorage.sol";

/**
 * @title Handler Context
 * @notice 为 Fallback Handler 提供“原始调用方”等上下文：FallbackManager 会在转发给 handler 的 calldata 末尾追加 20 字节的 caller()，本合约提供 _msgSender() 读取。
 * @dev _requireFallback() 通过读取 msg.sender（即 Safe）的 FALLBACK_HANDLER_STORAGE_SLOT 是否为本合约来尽力判断是否由 Safe 以 fallback 方式调用，仅为尽力而为，不可依赖为唯一安全边界。
 * @author Richard Meissner - @rmeissner
 */
abstract contract HandlerContext {
    /** 修饰符：要求当前调用来自 Safe 的 fallback（即 Safe 的 fallback handler 为本合约）。 */
    modifier onlyFallback() {
        _requireFallback();
        _;
    }

    /** 校验：msg.sender（Safe）的 fallback handler 配置为 address(this)。 */
    function _requireFallback() internal view {
        bytes memory storageData = ISafe(payable(msg.sender)).getStorageAt(uint256(FALLBACK_HANDLER_STORAGE_SLOT), 1);
        address fallbackHandler = abi.decode(storageData, (address));
        require(fallbackHandler == address(this), "not a fallback call");
    }

    /**
     * @notice 从 calldata 末尾 20 字节读取原始调用方（FallbackManager 追加的 caller()）。
     * @return sender 发起对 Safe 调用的地址。
     */
    function _msgSender() internal pure returns (address sender) {
        require(msg.data.length >= 20, "Invalid calldata length");
        // The assembly code is more direct than the Solidity version using `abi.decode`.
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            sender := shr(96, calldataload(sub(calldatasize(), 20)))
        }
        /* solhint-enable no-inline-assembly */
    }

    /** 返回“管理者”地址：在 fallback 调用中即为 Safe（msg.sender）。 */
    function _manager() internal view returns (address) {
        return msg.sender;
    }
}
