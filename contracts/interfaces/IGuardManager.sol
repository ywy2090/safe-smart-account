// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title IGuardManager
 * @notice Safe 交易守卫管理接口：为通过多签执行的 Safe 交易设置「执行前/执行后」检查逻辑。
 * @dev
 * - 守卫在 execTransaction 执行目标调用前、后各被调用一次，可做策略校验（如白名单、额度、重入检查等）。
 * - 仅能通过 Safe 交易设置或更换守卫；传入 0 表示禁用守卫。
 * - ⚠️ 守卫可完全阻止交易执行，若实现有误会导致 Safe 无法执行交易（DoS），需审计并预留恢复方式。
 * @author @safe-global/safe-protocol
 */
interface IGuardManager {
    /**
     * @notice 交易守卫更换时触发。
     * @param guard 新的交易守卫合约地址。
     */
    event ChangedGuard(address indexed guard);

    /**
     * @notice 为 Safe 设置交易守卫，或传入 0 禁用守卫。请仅设置可信的 guard。
     * @dev 守卫会对多签通过的 Safe 交易在执行前后进行检查；设置/更换只能通过 Safe 交易完成。
     * @param guard 守卫合约地址，或 0 表示禁用。
     */
    function setGuard(address guard) external;
}
