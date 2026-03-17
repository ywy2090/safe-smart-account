// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {EIP7702} from "../common/EIP7702.sol";          // 检测 EIP-7702 委托执行上下文
import {SelfAuthorized} from "../common/SelfAuthorized.sol"; // authorized 修饰符：msg.sender == address(this)
import {IOwnerManager} from "../interfaces/IOwnerManager.sol";

/**
 * @title Owner Manager — Safe 的 owner 与 threshold 管理实现
 * @notice 管理 Safe 的 owner 列表与签名门槛（threshold），仅 SelfAuthorized 调用可修改。
 *
 * @dev
 * ╔═══════════════════════════════════════════════════════════════════════════╗
 * ║                      链表数据结构详解                                     ║
 * ╠═══════════════════════════════════════════════════════════════════════════╣
 * ║                                                                          ║
 * ║  Owner 列表使用 mapping(address => address) 实现单向链表：                  ║
 * ║                                                                          ║
 * ║    SENTINEL(0x1) → Owner_A → Owner_B → Owner_C → SENTINEL(0x1)          ║
 * ║                                                                          ║
 * ║  存储结构（owners[key] = "key 的后继节点"）:                               ║
 * ║    owners[SENTINEL] = Owner_A   (头指针：哨兵的下一个 = 第一个 owner)     ║
 * ║    owners[Owner_A]  = Owner_B   (A 的 next)                               ║
 * ║    owners[Owner_B]  = Owner_C   (B 的 next)                              ║
 * ║    owners[Owner_C]  = SENTINEL  (尾节点 next 指回哨兵，形成闭环)         ║
 * ║                                                                          ║
 * ║  为什么选择链表而非动态数组：                                              ║
 * ║    ✓ O(1) 添加 — 头插法，不需要移动元素                                   ║
 * ║    ✓ O(1) 删除 — 修改前驱指针即可（调用者需提供 prevOwner）               ║
 * ║    ✓ O(1) 存在判断 — owners[addr] != 0 即在链表中                         ║
 * ║    ✓ gas 效率 — 添加/删除只写 2-3 个 storage slot                         ║
 * ║    ✗ 遍历需 O(n) — 但只在 getOwners() 等 view 函数中使用                 ║
 * ║                                                                          ║
 * ║  哨兵节点 (SENTINEL = address(0x1))：                                     ║
 * ║    - 用作链表的头尾标记，本身不是有效 owner                                ║
 * ║    - 简化边界处理：无需区分空链表、单元素、头部插入等情况                   ║
 * ║    - address(0) 被保留为"不在链表中"的标记                                ║
 * ║                                                                          ║
 * ║  无效地址：                                                               ║
 * ║    - address(0): 用作"不在链表中"的标记，不可作为 owner                   ║
 * ║    - address(0x1): 哨兵地址，不可作为 owner                               ║
 * ║    - address(this): 除非处于 EIP-7702 委托上下文，否则不可作为 owner       ║
 * ║                                                                          ║
 * ╠═══════════════════════════════════════════════════════════════════════════╣
 * ║                      链表算法步骤说明                                     ║
 * ╠═══════════════════════════════════════════════════════════════════════════╣
 * ║                                                                          ║
 * ║  【初始化 setupOwners】                                                   ║
 * ║    从 SENTINEL 开始，按 _owners[0..n-1] 顺序建链，最后让末节点指向       ║
 * ║    SENTINEL。等价于：先建 SENTINEL→A，再 A→B，再 B→C，最后 C→SENTINEL。  ║
 * ║                                                                          ║
 * ║  【头插 addOwnerWithThreshold】                                           ║
 * ║    1. 新节点 next := 当前头节点（owners[SENTINEL]）                        ║
 * ║    2. 头指针改为新节点：owners[SENTINEL] := 新节点                        ║
 * ║    两步顺序不可颠倒，否则会丢失原头节点引用。                              ║
 * ║                                                                          ║
 * ║  【删除 removeOwner(prevOwner, owner)】                                   ║
 * ║    1. prevOwner 的 next 改为 owner 的 next：owners[prevOwner] := owners[owner] ║
 * ║    2. 将 owner 清出链表：owners[owner] := 0                                ║
 * ║    这样 prevOwner 直接跳过 owner 指向其后继，owner 不再在链中。            ║
 * ║                                                                          ║
 * ║  【替换 swapOwner(prevOwner, oldOwner, newOwner)】                        ║
 * ║    1. newOwner 的 next := oldOwner 的 next（占住同一逻辑位置）             ║
 * ║    2. prevOwner 的 next := newOwner                                        ║
 * ║    3. owners[oldOwner] := 0（标记已移除）                                 ║
 * ║                                                                          ║
 * ║  【遍历 getOwners】                                                       ║
 * ║    current := owners[SENTINEL]，若 current != SENTINEL 则压入数组，      ║
 * ║    然后 current := owners[current]，直到回到 SENTINEL。                   ║
 * ║                                                                          ║
 * ╚═══════════════════════════════════════════════════════════════════════════╝
 *
 * @author Stefan George - @Georgi87
 * @author Richard Meissner - @rmeissner
 */
abstract contract OwnerManager is EIP7702, SelfAuthorized, IOwnerManager {

    // ═══════════════════════════════════════════════════════════════════════
    //                        常量 & 状态变量
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @dev 链表哨兵地址 — 固定为 address(0x1)。
     *      链表结构: SENTINEL → [owner1] → [owner2] → ... → [ownerN] → SENTINEL
     *      - owners[SENTINEL] 始终指向第一个 owner（头指针）
     *      - 最后一个 owner 的 next 指向 SENTINEL（闭环标记）
     *      - 空链表: owners[SENTINEL] == SENTINEL
     */
    address internal constant SENTINEL_OWNERS = address(0x1);

    /**
     * @dev Owner 链表的核心存储。
     *      owners[addr] 的含义：
     *        - address(0): addr 不在链表中（未添加或已移除）
     *        - 其他非零值: addr 在链表中，值为 addr 的下一个 owner 地址
     *
     *      这个 mapping 同时充当两个角色：
     *        1. 链表的 next 指针：owners[A] = B 表示 A 的下一个是 B
     *        2. 成员判断：owners[A] != address(0) 即表示 A 是 owner（O(1) 查询）
     */
    mapping(address => address) internal owners;

    /**
     * @dev 当前 owner 总数。冗余存储，避免每次遍历链表计算长度。
     *      约束: ownerCount ≥ threshold ≥ 1
     */
    uint256 internal ownerCount;

    /**
     * @dev 执行 Safe 交易所需的最少签名数。
     *      约束: 1 ≤ threshold ≤ ownerCount
     *      在 Safe.constructor() 中被设为 1 使 singleton 不可用。
     *      在 Safe.setup() → setupOwners() 中被设为用户指定的值。
     */
    uint256 internal threshold;

    // ═══════════════════════════════════════════════════════════════════════
    //                      初始化（仅调用一次）
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice 初始化 owner 链表与 threshold —— 由 Safe.setup() 调用，仅可执行一次。
     * @dev 初始化后链表结构:
     *      SENTINEL → _owners[0] → _owners[1] → ... → _owners[n-1] → SENTINEL
     *
     *      防重入/重初始化机制：检查 threshold > 0。
     *      - Safe singleton: constructor 设了 threshold=1 → setupOwners 会 revert (GS200)
     *      - Safe proxy: 首次 setup() 时 threshold=0 → 允许初始化
     *      - 二次 setup() 时 threshold>0 → revert (GS200)
     *
     *      owner 有效性校验:
     *      - 每个 owner 经过 requireCanAddOwner() 校验（非 0、非 SENTINEL、未重复、非 self-unless-7702）
     *      - owner == currentOwner 检查可捕获 _owners 数组中连续相同地址的情况
     *        （requireCanAddOwner 也会检测重复，但此处提前 revert 更省 gas）
     *
     * @param _owners 初始 owner 地址列表（不可重复、不可包含 0/SENTINEL/非7702的self）。
     * @param _threshold 所需签名数，须满足 1 ≤ _threshold ≤ _owners.length。
     */
    function setupOwners(address[] memory _owners, uint256 _threshold) internal {
        // 已初始化检查：threshold > 0 说明已经 setup 过
        if (threshold > 0) revertWithError("GS200");
        // threshold 不能超过 owner 数量
        if (_threshold > _owners.length) revertWithError("GS201");
        // threshold 至少为 1（Safe 至少需要一个签名）
        if (_threshold == 0) revertWithError("GS202");

        // ─── 链表构建算法：顺序建链，SENTINEL → _owners[0] → _owners[1] → ... → SENTINEL ───
        // currentOwner 始终是「当前链尾」：下一轮要把新节点挂到它后面
        address currentOwner = SENTINEL_OWNERS;
        uint256 ownersLength = _owners.length;
        for (uint256 i = 0; i < ownersLength; ++i) {
            address owner = _owners[i];
            // 快速检查：连续重复地址（比如 [A, A, B]）
            if (owner == currentOwner) revertWithError("GS204");
            // 完整校验：地址有效性 + 链表中不存在
            requireCanAddOwner(owner);
            // 链表操作：currentOwner 的 next 指向新节点（即 currentOwner → owner）
            owners[currentOwner] = owner;
            // 移动链尾指针到新节点，下一轮会在 owner 后面继续挂
            currentOwner = owner;
        }
        // 闭环：最后一个 owner 的 next 指回 SENTINEL，遍历时以「回到 SENTINEL」为结束条件
        owners[currentOwner] = SENTINEL_OWNERS;
        ownerCount = ownersLength;
        threshold = _threshold;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      写操作（需 authorized）
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IOwnerManager
     * @dev 头插法：新 owner 插入到 SENTINEL 之后（链表头部）。
     *
     *      链表变化示例（添加 Owner_D）:
     *        Before: SENTINEL → A → B → C → SENTINEL
     *        After:  SENTINEL → D → A → B → C → SENTINEL
     *
     *      操作步骤:
     *        1. owners[D] = owners[SENTINEL]  // D.next = A（原来的第一个）
     *        2. owners[SENTINEL] = D          // 头指针指向 D
     *        3. ownerCount++
     *
     *      如果 _threshold 与当前值不同，会在添加后调用 changeThreshold 更新。
     *      这允许在一次交易中完成"添加 owner + 提高 threshold"的原子操作。
     */
    function addOwnerWithThreshold(address owner, uint256 _threshold) public override authorized {
        requireCanAddOwner(owner);
        // ─── 头插法：新节点插在 SENTINEL 之后，成为新的第一个 owner ───
        // 1. 新节点的 next = 当前头节点（原第一个 owner），保证不丢链
        owners[owner] = owners[SENTINEL_OWNERS];
        // 2. 头指针改为新节点（SENTINEL 的 next = 新节点）
        owners[SENTINEL_OWNERS] = owner;
        ++ownerCount;
        emit AddedOwner(owner);
        // 仅在 threshold 需要变化时调用（节省 gas）
        if (threshold != _threshold) changeThreshold(_threshold);
    }

    /**
     * @inheritdoc IOwnerManager
     * @dev 链表删除：修改前驱的 next 指针绕过被删节点。
     *
     *      删除 Owner_B 示例（prevOwner = A）:
     *        Before: SENTINEL → A → B → C → SENTINEL
     *        After:  SENTINEL → A → C → SENTINEL     (B 被断开)
     *
     *      操作步骤:
     *        1. --ownerCount（先减，以便后续 threshold 校验使用减后的值）
     *        2. 校验 ownerCount >= _threshold（否则移除后无法达到门槛）
     *        3. owners[prevOwner] = owners[owner]  // 前驱直接指向后继
     *        4. owners[owner] = address(0)         // 标记为已移除
     *
     *      ⚠️ ownerCount 先减再校验，这是一个 checks-effects-interactions 的优化。
     *      即使 changeThreshold 触发额外逻辑，ownerCount 已正确反映最终状态。
     */
    function removeOwner(address prevOwner, address owner, uint256 _threshold) public override authorized {
        // 先减 ownerCount 再校验：确保移除后仍能满足新 threshold
        if (--ownerCount < _threshold) revertWithError("GS201");
        requireCanRemoveOwner(prevOwner, owner);
        // ─── 链表删除：让 prevOwner 的 next 跳过 owner，直接指向 owner 的后继 ───
        // prevOwner → owner → next  变为   prevOwner → next
        owners[prevOwner] = owners[owner];
        // 将 owner 从链表中抹掉：owners[owner]=0 同时表示「不在链中」且 isOwner(owner)=false
        owners[owner] = address(0);
        emit RemovedOwner(owner);
        if (threshold != _threshold) changeThreshold(_threshold);
    }

    /**
     * @inheritdoc IOwnerManager
     * @dev 原子替换：在链表同一位置将 oldOwner 替换为 newOwner。
     *
     *      替换 Owner_B 为 Owner_D 示例（prevOwner = A）:
     *        Before: SENTINEL → A → B → C → SENTINEL
     *        After:  SENTINEL → A → D → C → SENTINEL
     *
     *      操作步骤:
     *        1. owners[newOwner] = owners[oldOwner]  // D.next = C
     *        2. owners[prevOwner] = newOwner          // A.next = D
     *        3. owners[oldOwner] = address(0)         // B 标记为已移除
     *
     *      ownerCount 不变，threshold 也不需要调整。
     *      先发 RemovedOwner 再发 AddedOwner 事件，保持与 removeOwner+addOwner 一致的事件序列。
     */
    function swapOwner(address prevOwner, address oldOwner, address newOwner) public override authorized {
        // 校验 newOwner 可添加（合法 + 不在链表中）
        requireCanAddOwner(newOwner);
        // 校验 oldOwner 可移除（合法 + prevOwner 确实指向它）
        requireCanRemoveOwner(prevOwner, oldOwner);
        // ─── 原子替换：在 oldOwner 的位置插入 newOwner，链结构不变 ───
        // prevOwner → oldOwner → next  变为   prevOwner → newOwner → next
        // 1. newOwner 的 next = oldOwner 的 next（占住同一逻辑位置）
        owners[newOwner] = owners[oldOwner];
        // 2. prevOwner 的 next = newOwner
        owners[prevOwner] = newOwner;
        // 3. oldOwner 清出链表（与 removeOwner 一致，便于 isOwner(oldOwner)==false）
        owners[oldOwner] = address(0);
        emit RemovedOwner(oldOwner);
        emit AddedOwner(newOwner);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      内部校验函数
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice 校验一个地址是否为合法的 owner 地址（不校验是否已在链表中）。
     * @dev 非法地址将 revert GS203:
     *      - address(0): 零地址不可签名
     *      - SENTINEL_OWNERS (0x1): 哨兵地址是内部保留的链表标记
     *      - address(this) 且非 EIP-7702: Safe 自身作为 owner 只在 7702 委托场景下有意义。
     *        7702 允许 EOA 将代码委托给合约，此时 EOA 地址 == address(this)，且 EOA 可以签名。
     * @param owner 待校验的地址。
     */
    function requireIsValidOwner(address owner) internal view {
        if (owner == address(0) || owner == SENTINEL_OWNERS || (owner == address(this) && !isThisDelegatedAccount()))
            revertWithError("GS203");
    }

    /**
     * @notice 校验一个 owner 可以被添加：地址合法 + 不在链表中。
     * @dev owners[owner] != address(0) 表示已在链表中（因为链表中的 owner 必定指向某个非零地址）。
     *      重复添加会 revert GS204。
     * @param owner 待添加的 owner 地址。
     */
    function requireCanAddOwner(address owner) internal view {
        requireIsValidOwner(owner);
        if (owners[owner] != address(0)) revertWithError("GS204");
    }

    /**
     * @notice 校验一个 owner 可以被移除：地址合法 + prevOwner 确实指向 owner。
     * @dev 调用者必须提供正确的 prevOwner，否则 revert GS205。
     *      这是链表删除的必要条件：需要修改前驱的 next 指针。
     *
     *      前端确定 prevOwner 的方法:
     *        1. 调用 getOwners() 获取 [owner1, owner2, ..., ownerN]
     *        2. 找到待删 owner 的索引 i
     *        3. i==0 时 prevOwner = SENTINEL(0x1)，否则 prevOwner = owners[i-1]
     *
     * @param prevOwner 链表中待移除 owner 的前驱地址。
     * @param owner 待移除的 owner 地址。
     */
    function requireCanRemoveOwner(address prevOwner, address owner) internal view {
        requireIsValidOwner(owner);
        if (owners[prevOwner] != owner) revertWithError("GS205");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      Threshold 管理
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IOwnerManager
     * @dev threshold 约束:
     *      - _threshold ≤ ownerCount (GS201): 不能要求比现有 owner 更多的签名
     *      - _threshold ≥ 1 (GS202): 至少需要一个签名（0 会导致任何人都能执行交易）
     *
     *      此函数被 addOwnerWithThreshold / removeOwner 内部调用以原子更新 threshold。
     *      也可单独调用（通过 Safe 交易）仅修改 threshold 而不改变 owner 列表。
     */
    function changeThreshold(uint256 _threshold) public override authorized {
        if (_threshold > ownerCount) revertWithError("GS201");
        if (_threshold == 0) revertWithError("GS202");
        threshold = _threshold;
        emit ChangedThreshold(_threshold);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          只读查询
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc IOwnerManager
     */
    function getThreshold() public view override returns (uint256) {
        return threshold;
    }

    /**
     * @inheritdoc IOwnerManager
     * @dev 判断逻辑：
     *      - SENTINEL_OWNERS 不是有效 owner（它是链表标记）
     *      - owners[owner] == address(0) 表示不在链表中
     *      - 两个条件都不满足 → 是有效 owner
     *      时间复杂度: O(1)，单次 SLOAD
     */
    function isOwner(address owner) public view override returns (bool) {
        return !(owner == SENTINEL_OWNERS || owners[owner] == address(0));
    }

    /**
     * @inheritdoc IOwnerManager
     * @dev 从 SENTINEL_OWNERS 开始遍历链表，收集所有 owner 到数组中。
     *      遍历终止条件: currentOwner == SENTINEL_OWNERS（回到哨兵，链表结束）。
     *      返回顺序: 链表顺序（最近添加的 owner 在数组前面，因为头插法）。
     *      时间复杂度: O(n)，n 次 SLOAD。
     *      注意: 这是 view 函数，仅用于链下查询，不消耗 gas（除非被合约内部调用）。
     */
    function getOwners() public view override returns (address[] memory) {
        address[] memory array = new address[](ownerCount);

        // ─── 遍历链表：从头节点出发，沿 next 走到回到 SENTINEL 为止 ───
        uint256 index = 0;
        address currentOwner = owners[SENTINEL_OWNERS]; // 第一个 owner（头节点）
        while (currentOwner != SENTINEL_OWNERS) {
            array[index] = currentOwner;
            currentOwner = owners[currentOwner]; // 移动到下一个节点
            ++index;
        }
        return array;
    }
}
