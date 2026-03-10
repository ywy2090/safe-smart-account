// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title Secured Token Transfer
 * @notice 安全执行 ERC20 transfer：兼容无返回值或 bool 返回值的代币，失败时返回 false 而不 revert。
 * @author Richard Meissner - @rmeissner
 */
abstract contract SecuredTokenTransfer {
    /**
     * @notice 向 receiver 转 amount 数量的 token；成功返回 true，失败返回 false。
     * @dev 不校验 token 是否为合约。对 return data 长度做判断：0 字节视为 success 即成功，32 字节且为 true 即成功，否则失败。
     * @param token ERC20 代币地址。
     * @param receiver 接收地址。
     * @param amount 数量。
     * @return transferred 是否转账成功。
     */
    function transferToken(address token, address receiver, uint256 amount) internal returns (bool transferred) {
        // transfer(address,uint256) 的 selector
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, receiver, amount);
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            // We write the return value to scratch space.
            // See <https://docs.soliditylang.org/en/v0.7.6/internals/layout_in_memory.html#layout-in-memory>
            let success := call(sub(gas(), 10000), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            switch returndatasize()
            case 0 {
                transferred := success
            }
            case 0x20 {
                transferred := iszero(or(iszero(success), iszero(mload(0))))
            }
            default {
                transferred := 0
            }
        }
        /* solhint-enable no-inline-assembly */
    }
}
