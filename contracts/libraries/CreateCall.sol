// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity >=0.7.0 <0.9.0;

/**
 * @title CreateCall
 * @notice 供 Safe 通过 DELEGATECALL 使用的合约创建封装：支持 CREATE 与 CREATE2，新合约的部署者为 Safe。
 * @dev
 * - 必须由 Safe 对本合约做 DELEGATECALL 调用。执行时 msg.sender/address(this) 为 Safe，
 *   因此 create/create2 的“部署者”是 Safe，新合约 constructor 中 msg.sender 为 Safe。
 * - 若 Safe 用 CALL 调工厂合约部署，部署者会是工厂；通过本库 DELEGATECALL 则部署者为 Safe，
 *   便于新合约直接把 Safe 设为 owner 或做权限绑定。
 * - CREATE：地址由部署者 + nonce 决定，不可预测。CREATE2：地址由 salt + creationCode 哈希决定，可预测、可跨链同地址。
 * @author Richard Meissner - @rmeissner
 */
contract CreateCall {
    /**
     * @notice 每次成功部署出新合约时发出。
     * @param newContract 新部署的合约地址。
     */
    event ContractCreation(address indexed newContract);

    /**
     * @notice 使用 CREATE2 部署合约；地址由 salt 与 creationCode 唯一确定，可预测。
     * @dev 通常由 Safe 通过 execTransaction(..., to=CreateCall, data=performCreate2(...), operation=DelegateCall) 调用。
     *      deploymentData 在 memory 中：前 32 字节为 length，随后为字节码；assembly 中 add(deploymentData, 0x20) 为数据起始，mload(deploymentData) 为长度。
     * @param value 部署时转给新合约的 wei（可为 0）。
     * @param deploymentData 创建用字节码（creation code + 编码后的 constructor 参数）。
     * @param salt CREATE2 盐值，参与地址计算；同一 salt + 同一 deploymentData 在同一链上得到同一地址。
     * @return newContract 新合约地址；失败时为 address(0)，下方 require 会 revert。
     */
    function performCreate2(uint256 value, bytes memory deploymentData, bytes32 salt) public returns (address newContract) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            // bytes memory 布局：offset 0 为 length，offset 0x20 起为 data
            newContract := create2(value, add(deploymentData, 0x20), mload(deploymentData), salt)
        }
        /* solhint-enable no-inline-assembly */
        require(newContract != address(0), "Could not deploy contract");
        emit ContractCreation(newContract);
    }

    /**
     * @notice 使用 CREATE 部署合约；地址由部署者（Safe）的 nonce 决定，不可预测。
     * @dev 通常由 Safe 通过 DELEGATECALL 调用。deploymentData 为完整 creation code（含 constructor 参数）。
     * @param value 部署时转给新合约的 wei（可为 0）。
     * @param deploymentData 创建用字节码。
     * @return newContract 新合约地址；失败时为 address(0)，下方 require 会 revert。
     */
    function performCreate(uint256 value, bytes memory deploymentData) public returns (address newContract) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            newContract := create(value, add(deploymentData, 0x20), mload(deploymentData))
        }
        /* solhint-enable no-inline-assembly */
        require(newContract != address(0), "Could not deploy contract");
        emit ContractCreation(newContract);
    }
}
