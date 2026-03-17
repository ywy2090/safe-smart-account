// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;
import {Enum} from "../interfaces/Enum.sol";

/**
 * @title IModuleManager
 * @notice Safe 模块管理接口：负责模块的启用/禁用、以模块身份执行交易及分页查询模块列表。
 * @dev
 * - 模块是由 owner 通过 Safe 交易添加的扩展，拥有通过 Safe 执行任意交易的能力（CALL/DELEGATECALL）。
 * - ⚠️ 仅应添加可信且经过审计的模块；恶意模块可完全控制 Safe。
 * - 实现中模块列表以链表存储，start 为 `0x1` 表示从链表头开始分页。
 * @author @safe-global/safe-protocol
 */
interface IModuleManager {
    /**
     * @notice 模块被启用时触发。
     * @param module 被启用的模块地址。
     */
    event EnabledModule(address indexed module);

    /**
     * @notice 模块被禁用时触发。
     * @param module 被禁用的模块地址。
     */
    event DisabledModule(address indexed module);

    /**
     * @notice 由模块发起的交易执行成功时触发。
     * @param module 执行该交易的模块地址。
     */
    event ExecutionFromModuleSuccess(address indexed module);

    /**
     * @notice 由模块发起的交易执行失败（revert）时触发。
     * @param module 执行该交易的模块地址。
     */
    event ExecutionFromModuleFailure(address indexed module);

    /**
     * @notice 模块交易守卫（Module Guard）更换时触发。
     * @param moduleGuard 新的模块交易守卫地址。
     */
    event ChangedModuleGuard(address indexed moduleGuard);

    /**
     * @notice 为 Safe 启用模块 `module`。
     * @dev 仅能通过 Safe 交易调用（多签）。
     * @param module 待加入白名单的模块地址。
     */
    function enableModule(address module) external;

    /**
     * @notice 禁用 Safe 的模块 `module`。
     * @dev 仅能通过 Safe 交易调用。需传入链表中 `module` 的前驱；若 `module` 为链表首元，则 prevModule 为 `0x1`（SENTINEL_MODULES）。
     * @param prevModule 链表中紧挨在 `module` 之前的节点；首元时传 `0x1`。
     * @param module 待移除的模块地址。
     */
    function disableModule(address prevModule, address module) external;

    /**
     * @notice 以当前 Safe 身份执行一笔交易（仅可由已启用模块调用）。
     * @dev 仅当 msg.sender 为已启用模块时执行；使用 Safe 的余额与存储上下文（DELEGATECALL 时）。
     * @param to 目标地址。
     * @param value 发送的原生代币数量（wei）。
     * @param data 调用数据。
     * @param operation 0 = Call，1 = DelegateCall。
     * @return success 是否执行成功（未 revert）。
     */
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) external returns (bool success);

    /**
     * @notice 与 execTransactionFromModule 相同，但返回目标调用的返回数据。
     * @dev 仅可由已启用模块调用；便于模块根据返回数据做后续逻辑。
     * @param to 目标地址。
     * @param value 发送的原生代币数量（wei）。
     * @param data 调用数据。
     * @param operation 0 = Call，1 = DelegateCall。
     * @return success 是否执行成功。
     * @return returnData 目标调用的返回数据。
     */
    function execTransactionFromModuleReturnData(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) external returns (bool success, bytes memory returnData);

    /**
     * @notice 查询某地址是否为已启用的模块。
     * @param module 待查询地址。
     * @return 若为已启用模块返回 true，否则 false。
     */
    function isModuleEnabled(address module) external view returns (bool);

    /**
     * @notice 分页返回模块列表。
     * @dev 链表存储；单页可容纳全部时 next 为 `address(0x1)`，否则 next 为当前页最后一个元素，用于下次请求的 start。
     * @param start 本页起始节点，须为模块地址或 `0x1`（表示链表头）。
     * @param pageSize 本页最多返回的模块数量，必须大于 0。
     * @return array 本页模块地址数组。
     * @return next 下一页起始节点（或 `0x1` 表示无下一页）。
     */
    function getModulesPaginated(address start, uint256 pageSize) external view returns (address[] memory array, address next);

    /**
     * @notice 设置或更换模块交易守卫；设为 0 表示禁用。请仅设置可信的 moduleGuard。
     * @dev 该守卫在由模块发起的交易执行前后被调用，可阻断执行。仅能通过 Safe 交易设置。
     *      ⚠️ 守卫故障会导致模块无法执行交易（DoS），需审计并设计恢复机制。
     * @param moduleGuard 模块守卫合约地址，或 0 表示禁用。
     */
    function setModuleGuard(address moduleGuard) external;
}
