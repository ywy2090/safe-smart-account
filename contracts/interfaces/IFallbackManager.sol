// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title IFallbackManager
 * @notice Safe 的 Fallback 管理器接口：将无匹配函数且带 data 的调用转发到已设置的 handler，并在 calldata 末尾附加原始调用者地址。
 * @dev
 * - 仅当调用「无 value 且带 data」时才会进入 fallback 并转发；纯转账（仅有 value）由 receive 处理。
 * - Handler 通过 {HandlerContext} 可获取原始 caller，因下一调用帧中 msg.sender 为 FallbackManager 地址。
 * @author @safe-global/safe-protocol
 */
interface IFallbackManager {
    /**
     * @notice Fallback handler 已更换时触发。
     * @param handler 新的 fallback handler 地址。
     */
    event ChangedFallbackHandler(address indexed handler);

    /**
     * @notice 为 Safe 设置 Fallback Handler。
     * @dev
     * 1. 仅无 value 且带 data 的 fallback 调用会被转发。
     * 2. 更换 handler 只能通过 Safe 交易执行（需多签）。
     * 3. 不能将 Safe 自身设为 handler。
     * 4. ⚠️ 安全风险：handler 可设为任意地址，转发会绕过 Safe 的访问控制，请仅设置可信合约并确认其有必要的校验。
     * @param handler 处理 fallback 调用的合约地址。
     */
    function setFallbackHandler(address handler) external;

    /**
     * @notice 若已设置 handler，则将当前调用转发给 handler；未设置则返回空数据。
     * @dev 会在 calldata 末尾追加「未 padding 的调用者地址」，handler 可通过 {HandlerContext} 解析；
     *      这样在下一调用帧中虽 msg.sender 为 FallbackManager，仍可获知原始 caller，便于做额外校验。
     */
    fallback() external;
}
