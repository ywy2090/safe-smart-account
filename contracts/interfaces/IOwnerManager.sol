// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title Owner Manager Interface — Safe 的 owner 管理接口
 * @notice 定义 Safe 多签钱包中 owner 列表与签名门槛（threshold）的管理操作。
 *
 * @dev
 * ╔═══════════════════════════════════════════════════════════════════════╗
 * ║                    Owner 管理核心概念                                 ║
 * ╠═══════════════════════════════════════════════════════════════════════╣
 * ║                                                                      ║
 * ║  Owner（所有者）：                                                    ║
 * ║    - 有权签署 Safe 交易的地址                                         ║
 * ║    - 可以是 EOA、合约钱包 (EIP-1271)、P-256 密钥对、EIP-7702 委托账户 ║
 * ║    - 实现中使用链表 (linked list) 存储，非动态数组                     ║
 * ║                                                                      ║
 * ║  Threshold（签名门槛）：                                              ║
 * ║    - 执行 Safe 交易所需的最少 owner 确认数                             ║
 * ║    - 约束: 1 ≤ threshold ≤ ownerCount                                ║
 * ║    - 典型配置: 2-of-3, 3-of-5, n-of-n 等                             ║
 * ║                                                                      ║
 * ║  权限控制：                                                           ║
 * ║    - 所有写操作（add/remove/swap/changeThreshold）均为 authorized      ║
 * ║    - authorized 要求 msg.sender == address(this)                      ║
 * ║    - 即只能通过 Safe 交易（execTransaction）自身调用来修改 owner 配置   ║
 * ║    - 这意味着修改 owner 本身也需要达到 threshold 个签名               ║
 * ║                                                                      ║
 * ╚═══════════════════════════════════════════════════════════════════════╝
 *
 * @author @safe-global/safe-protocol
 */
interface IOwnerManager {
    // ═══════════════════════════════════════════════════════════════════════
    //                            事件
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice 一个新 owner 被添加到 Safe 中。
     * @param owner 新增的 owner 地址。
     */
    event AddedOwner(address indexed owner);

    /**
     * @notice 一个 owner 从 Safe 中被移除。
     * @param owner 被移除的 owner 地址。
     */
    event RemovedOwner(address indexed owner);

    /**
     * @notice 签名门槛已更改。
     * @param threshold 新的签名门槛值。
     */
    event ChangedThreshold(uint256 threshold);

    // ═══════════════════════════════════════════════════════════════════════
    //                          写操作
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice 添加 owner 并更新签名门槛。
     * @dev 仅可通过 Safe 交易调用（authorized 修饰符）。
     *      新 owner 被插入链表头部（SENTINEL_OWNERS 之后），时间复杂度 O(1)。
     *
     *      ⚠️ EIP-7702 注意事项：
     *      Safe 可以将自身地址设为 owner（用于 EIP-7702 委托场景）。
     *      但如果 Safe 地址不是 EOA 且无法自签名，可能导致钱包无法使用。
     *      例如：n/n 多签中一个 owner 是 Safe 自身且非 7702 委托账户，
     *      则无法凑齐 n 个有效签名。
     *
     * @param owner 新 owner 地址。
     * @param _threshold 新的签名门槛。
     */
    function addOwnerWithThreshold(address owner, uint256 _threshold) external;

    /**
     * @notice 移除 owner 并更新签名门槛。
     * @dev 仅可通过 Safe 交易调用。
     *      调用者需提供被移除 owner 在链表中的前驱节点（prevOwner），
     *      因为链表删除需要修改前驱的 next 指针。
     *
     *      前端/SDK 可通过 getOwners() 获取完整列表来确定 prevOwner。
     *
     * @param prevOwner 链表中指向 `owner` 的前驱节点地址。
     *        如果 `owner` 是链表的第一个（或唯一一个）元素，
     *        则 `prevOwner` 必须设为哨兵地址 `0x1`（实现中的 `SENTINEL_OWNERS`）。
     * @param owner 待移除的 owner 地址。
     * @param _threshold 新的签名门槛（必须 ≤ 移除后的 ownerCount）。
     */
    function removeOwner(address prevOwner, address owner, uint256 _threshold) external;

    /**
     * @notice 将 oldOwner 替换为 newOwner，owner 总数不变。
     * @dev 仅可通过 Safe 交易调用。
     *      等效于"在 oldOwner 的位置插入 newOwner"——原子操作，
     *      不会出现 ownerCount 先减后增的中间状态。
     *
     *      ⚠️ 同样存在 EIP-7702 self-owner 风险（见 addOwnerWithThreshold 说明）。
     *
     * @param prevOwner 链表中指向 `oldOwner` 的前驱节点地址。
     *        如果 `oldOwner` 是链表第一个元素，则设为哨兵地址 `0x1`。
     * @param oldOwner 待替换的旧 owner 地址。
     * @param newOwner 替换后的新 owner 地址。
     */
    function swapOwner(address prevOwner, address oldOwner, address newOwner) external;

    /**
     * @notice 仅修改签名门槛，不增删 owner。
     * @dev 仅可通过 Safe 交易调用。
     *      约束: 1 ≤ _threshold ≤ ownerCount。
     * @param _threshold 新的签名门槛。
     */
    function changeThreshold(uint256 _threshold) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                          只读查询
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice 返回当前签名门槛（执行 Safe 交易所需的最少确认数）。
     * @return 当前 threshold 值。
     */
    function getThreshold() external view returns (uint256);

    /**
     * @notice 查询某地址是否为 Safe 的 owner。
     * @dev 内部通过链表映射判断：owners[owner] != address(0) 且 owner != SENTINEL。
     *      时间复杂度 O(1)。
     * @param owner 待查询的地址。
     * @return 如果是 owner 返回 true。
     */
    function isOwner(address owner) external view returns (bool);

    /**
     * @notice 返回所有 owner 的列表。
     * @dev 遍历链表从 SENTINEL_OWNERS 开始直到回到 SENTINEL_OWNERS。
     *      返回数组大小 = ownerCount，顺序为链表顺序（最近添加的在前）。
     *      时间复杂度 O(n)，n 为 owner 数量。
     * @return 按链表顺序排列的 owner 地址数组。
     */
    function getOwners() external view returns (address[] memory);
}
