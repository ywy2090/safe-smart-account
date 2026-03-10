// SPDX-License-Identifier: LGPL-3.0-only

pragma solidity >=0.7.0 <0.9.0;

/**
 * @title Create Call
 * @notice 供 Safe 通过 DELEGATECALL 使用的合约创建封装：支持 CREATE 与 CREATE2，部署的合约由 Safe 作为部署者。
 * @author Richard Meissner - @rmeissner
 */
contract CreateCall {
    /** 每次成功创建合约时发出 */
    event ContractCreation(address indexed newContract);

    /**
     * @notice 使用 CREATE2 部署合约；地址由 salt + creationCode 确定，可预测。
     * @param value 随创建发送的 wei。
     * @param deploymentData 创建字节码（含 constructor 参数）。
     * @param salt CREATE2 盐值。
     * @return newContract 新合约地址。
     */
    function performCreate2(uint256 value, bytes memory deploymentData, bytes32 salt) public returns (address newContract) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            newContract := create2(value, add(deploymentData, 0x20), mload(deploymentData), salt)
        }
        /* solhint-enable no-inline-assembly */
        require(newContract != address(0), "Could not deploy contract");
        emit ContractCreation(newContract);
    }

    /**
     * @notice 使用 CREATE 部署合约；地址由 sender + nonce 决定。
     * @param value 随创建发送的 wei。
     * @param deploymentData 创建字节码。
     * @return newContract 新合约地址。
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
