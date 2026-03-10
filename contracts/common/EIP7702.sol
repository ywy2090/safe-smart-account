// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title EIP-7702
 * @notice 检测当前执行是否处于 EIP-7702 委托上下文中（EOA 将代码委托给某合约后，以 EOA 身份执行该合约代码）。
 * @dev 用于 OwnerManager：允许将 Safe 自身设为 owner（当 Safe 是 7702 委托账户时）。返回 true 仅表示当前在某种委托执行中，不保证委托目标就是本合约。
 * @author Nicholas Rodrigues Lordello - @nlordell
 */
abstract contract EIP7702 {
    /**
     * @dev 通过 EXTCODECOPY 读取 address() 处代码前 3 字节，判断是否为 0xef0100（EIP-7702 委托前缀）。CODECOPY 在委托执行时读到的是执行中的代码而非委托槽，故用 EXTCODECOPY。
     */
    function isThisDelegatedAccount() internal view returns (bool result) {

        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            extcodecopy(address(), 0, 0, 3)
            result := eq(shr(232, mload(0)), 0xef0100)
        }
        /* solhint-enable no-inline-assembly */
    }
}
