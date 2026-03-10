// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title IProxy
 * @notice 用于链上获取 Proxy 当前使用的实现合约地址。
 * @dev 命名为 masterCopy 是历史惯例（Gnosis Safe v1.0 时期的叫法），
 *      等价于 EIP-1967 中的 implementation 概念。
 */
interface IProxy {
    function masterCopy() external view returns (address);
}

/**
 * @title SafeProxy
 * @notice Safe 的最小代理合约 —— 整个 Safe 协议中实际部署量最大的合约。
 *
 * @dev 核心设计：
 *
 *      ┌─────────────────────────────────────────────────────────────┐
 *      │  SafeProxy 的职责极其单一：                                  │
 *      │    1. 存储 singleton 地址（slot 0）                          │
 *      │    2. 拦截 masterCopy() 调用 → 直接返回 singleton 地址       │
 *      │    3. 其余所有调用 → delegatecall 到 singleton               │
 *      │                                                             │
 *      │  不持有任何业务逻辑，但持有全部状态（storage / balance）。    │
 *      └─────────────────────────────────────────────────────────────┘
 *
 *      Storage Layout 约束：
 *        - `singleton` 必须位于 slot 0，与 Safe 实现合约的 Singleton 基类布局严格对齐。
 *        - delegatecall 下 Safe 实现合约操作的是 proxy 的 storage，因此两者的 slot 0
 *          含义必须相同（都是"实现合约地址"），否则会导致 storage 错位。
 *
 *      为什么没有 receive()：
 *        - SafeProxy 只有 fallback() payable，没有独立的 receive()。
 *        - 纯 ETH 转账（无 calldata）会进入 fallback，被 delegatecall 到 singleton。
 *        - Safe 实现合约继承了 NativeCurrencyPaymentFallback，其 receive() 会处理并
 *          emit SafeReceived 事件。由于 delegatecall 的语义，该事件从 proxy 地址发出。
 *
 *      Gas 优化：
 *        - assembly 块故意不标记 memory-safe，因为它始终以 return/revert 终止，
 *          不会把控制权交还 Solidity，所以违反内存安全假设不会产生副作用。
 *        - delegatecall 路径不清理 singleton 地址的高 96 位，因为 EVM 的 DELEGATECALL
 *          会自动忽略地址参数的高 12 字节，省去一次 AND 操作。
 *
 * @author Stefan George - @Georgi87
 * @author Richard Meissner - @rmeissner
 */
contract SafeProxy {
    /**
     * @dev 实现合约地址，占据 slot 0。
     *
     *      这是 SafeProxy 中唯一的状态变量。与 Safe 实现合约中 Singleton 基类的
     *      `singleton` 变量对齐，保证 delegatecall 场景下 storage 布局一致。
     *
     *      可通过 masterCopy() 在链上查询，也可通过 eth_getStorageAt(proxy, 0) 读取。
     *      迁移版本时，迁移合约（如 SafeMigration）会修改此值指向新的实现。
     */
    address internal singleton;

    /**
     * @notice 部署一个新的 SafeProxy，指向指定的 singleton 实现合约。
     * @dev 构造函数只做两件事：校验地址非零 + 存储 singleton。
     *      部署后通常由 SafeProxyFactory 立即调用 setup() 完成初始化。
     *      若未立即初始化，任何人都可抢先调用 setup() 接管该 proxy。
     * @param _singleton Safe 或 SafeL2 实现合约的地址，必须已部署。
     */
    constructor(address _singleton) {
        require(_singleton != address(0), "Invalid singleton address provided");
        singleton = _singleton;
    }

    /**
     * @notice SafeProxy 的核心：所有外部调用的统一入口。
     * @dev 内部逻辑分两条路径：
     *
     *      路径 1 — masterCopy() 查询（selector 0xa619486e）：
     *        直接从 slot 0 读取 singleton 地址并 ABI 编码返回，不做 delegatecall。
     *        这使得链上合约和工具可以查询 proxy 当前指向的实现。
     *
     *      路径 2 — 其他所有调用：
     *        将完整 calldata 通过 delegatecall 转发到 singleton。
     *        delegatecall 意味着：
     *          - 使用 proxy 的 storage（状态保存在 proxy 中）
     *          - msg.sender 和 msg.value 保持不变（调用者视角透明）
     *          - 执行结果（returndata）原样返回给调用者
     *          - 如果 singleton 调用 revert，proxy 也 revert 并携带完整 revert data
     *
     *      关于 masterCopy() 返回值的内存布局技巧：
     *        写入位置是 0x6c（= 0x60 + 12），而 return 从 0x60 开始读 32 字节。
     *        shl(96, _singleton) 把 20 字节地址左对齐，存入 0x6c 后，
     *        0x60~0x6b 的 12 字节来自"零内存区"（Solidity 保证 0x60 处初始为 0），
     *        从而构成一个合法的 ABI 编码 address（左 padding 12 个 0 字节）。
     *        选择零内存区而非 scratch space（0x00~0x3f）是因为 scratch space
     *        不保证为零，可能导致返回值高位脏数据。
     */
    fallback() external payable {
        // 此 assembly 块故意不标记 memory-safe：它不遵守 Solidity 内存分配规则，
        // 但因始终以 return/revert 终止、不回到 Solidity 代码，所以不会产生问题。
        // 该合约独立编译，不影响其他合约的优化器行为。
        /* solhint-disable no-inline-assembly */
        assembly {
            // 从 slot 0 读取实现合约地址
            let _singleton := sload(0)

            // 检查 calldata 前 4 字节是否为 masterCopy() 的 selector (0xa619486e)
            // shr(224, calldataload(0))：加载 calldata 前 32 字节，右移 224 位只保留前 4 字节
            if eq(shr(224, calldataload(0)), 0xa619486e) {
                // masterCopy() 路径：直接返回 singleton 地址，不 delegatecall
                // shl(96, _singleton)：左移 96 位把 20 字节地址对齐到高位
                // mstore(0x6c, ...)：写入零内存区偏移 12 处，使 0x60~0x7f 构成合法 ABI 编码
                mstore(0x6c, shl(96, _singleton))
                return(0x60, 0x20)
            }

            // 通用 delegatecall 路径：转发全部 calldata 到 singleton
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), _singleton, 0, calldatasize(), 0, 0)

            // 将 returndata 拷贝到内存起始位置
            returndatacopy(0, 0, returndatasize())

            // singleton 调用失败则 revert，携带完整 revert data（错误消息 / panic 码等）
            if iszero(success) {
                revert(0, returndatasize())
            }
            // 成功则返回完整 returndata
            return(0, returndatasize())
        }
        /* solhint-enable no-inline-assembly */
    }
}
