// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ErrorMessage} from "../common/ErrorMessage.sol";

/**
 * @title Self Authorized
 * @notice 仅允许合约“自己调用自己”：即通过 proxy 调用时，msg.sender 必须为 address(this)（即 proxy 地址），从而仅 Safe 自身可执行修改配置的逻辑。
 * @author Richard Meissner - @rmeissner
 */
abstract contract SelfAuthorized is ErrorMessage {
    /** 校验调用方为当前合约（在 proxy 场景下即 proxy 自身），否则 GS031 */
    function requireSelfCall() private view {
        if (msg.sender != address(this)) revertWithError("GS031");
    }

    /** 修饰符：仅当 msg.sender == address(this) 时通过，用于 owner/module/guard/fallback 等管理函数 */
    modifier authorized() {
        requireSelfCall();
        _;
    }
}
