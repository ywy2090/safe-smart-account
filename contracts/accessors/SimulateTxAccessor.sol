// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {Executor, Enum} from "../base/Executor.sol";

/**
 * @title Simulate Transaction Accessor
 * @notice 供 Safe 通过 StorageAccessible.simulateAndRevert 使用的模拟执行器：对 (to, value, data, operation) 执行一次调用并返回 gas 消耗、成功与否及 returnData。
 * @dev 必须通过 DELEGATECALL 调用（即 Safe 的 storage 与上下文），否则 onlyDelegateCall 会 revert。返回值格式等价于 abi.encode(estimate, success, returnData)。
 * @author Richard Meissner - @rmeissner
 */
contract SimulateTxAccessor is Executor {
    // 单例地址，用于校验调用方式：address(this) != ACCESSOR_SINGLETON 表示在 Safe 上下文中
    address private immutable ACCESSOR_SINGLETON;

    constructor() {
        ACCESSOR_SINGLETON = address(this);
    }

    /** 仅允许通过 DELEGATECALL 调用（由 Safe 调用）。 */
    modifier onlyDelegateCall() {
        require(address(this) != ACCESSOR_SINGLETON, "SimulateTxAccessor should only be called via delegatecall");
        _;
    }

    /**
     * @notice 模拟执行一笔调用，返回消耗的 gas、是否成功及返回数据。
     * @param to 目标地址。
     * @param value 发送的 wei。
     * @param data 调用数据。
     * @param operation Call 或 DelegateCall。
     * @return estimate 本次调用消耗的 gas。
     * @return success 调用是否成功。
     * @return returnData 调用返回的字节数据。
     */
    function simulate(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation
    ) external onlyDelegateCall returns (uint256 estimate, bool success, bytes memory returnData) {
        uint256 startGas = gasleft();
        success = execute(to, value, data, operation, gasleft());
        estimate = startGas - gasleft();
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            // Load free memory location.
            let ptr := mload(0x40)
            // We allocate memory for the return data by setting the free memory location to
            // current free memory location `ptr`, plus the size of the return data and an
            // additional 32 bytes for the return data length.
            mstore(0x40, add(ptr, add(returndatasize(), 0x20)))
            // Store the size.
            mstore(ptr, returndatasize())
            // Store the data.
            returndatacopy(add(ptr, 0x20), 0, returndatasize())
            // Point the return data to the correct memory location.
            returnData := ptr
        }
        /* solhint-enable no-inline-assembly */
    }
}
