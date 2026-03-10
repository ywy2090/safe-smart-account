// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {IStorageAccessible} from "../interfaces/IStorageAccessible.sol";

/**
 * @title Storage Accessible
 * @notice 允许按 slot 偏移读取合约 storage，并支持 simulateAndRevert 模拟调用并携带结果 revert。
 * @dev 用于读取 Guard 等存储或安全地试执行；见 Gnosis util-contracts StorageAccessible。
 * @author Gnosis Developers
 */
abstract contract StorageAccessible is IStorageAccessible {
    /** 读取从 offset 起的 length 个 storage 槽，每槽 32 字节 */
    function getStorageAt(uint256 offset, uint256 length) public view override returns (bytes memory) {
        bytes memory result = new bytes(length << 5);
        for (uint256 index = 0; index < length; ++index) {
            /* solhint-disable no-inline-assembly */
            /// @solidity memory-safe-assembly
            assembly {
                let word := sload(add(offset, index))
                mstore(add(add(result, 0x20), mul(index, 0x20)), word)
            }
            /* solhint-enable no-inline-assembly */
        }
        return result;
    }

    /**
     * @inheritdoc IStorageAccessible
     * @dev 使用当前合约上下文 delegatecall targetContract(calldataPayload)，然后将 success、returndatasize、returnData 编码进 revert 数据并 revert，便于调用方 try/catch 解析结果。
     */
    function simulateAndRevert(address targetContract, bytes memory calldataPayload) external override {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            let success := delegatecall(gas(), targetContract, add(calldataPayload, 0x20), mload(calldataPayload), 0, 0)
            let ptr := mload(0x40)
            mstore(ptr, success)
            mstore(add(ptr, 0x20), returndatasize())
            returndatacopy(add(ptr, 0x40), 0, returndatasize())
            revert(ptr, add(returndatasize(), 0x40))
        }
        /* solhint-enable no-inline-assembly */
    }
}
