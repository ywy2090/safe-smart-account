// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title Safe Math
 * @notice 带溢出/下溢检查的算术库，出错时 revert（用于 Solidity 0.7 兼容，0.8+ 内置检查）。
 */
library SafeMath {
    /**
     * @notice 乘法，溢出时 revert。
     * @param a First number.
     * @param b Second number.
     * @return Product of `a` and `b`.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not to be zero,
        // but the benefit is lost if 'b' is also tested.
        // See: <https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522>
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b);

        return c;
    }

    /** 减法，若 b > a 则 revert。 */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a);
        return a - b;
    }

    /** 加法，溢出时 revert。 */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a);

        return c;
    }

    /** 返回两数较大值。 */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }
}
