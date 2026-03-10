// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

// ═══════════════════════════════════════════════════════════════════════════════
// 依赖导入 —— Safe 采用"组件化继承"架构，每个父合约负责一个独立关注点
// ═══════════════════════════════════════════════════════════════════════════════

// ──── 基础管理器层 ────
import {FallbackManager} from "./base/FallbackManager.sol";        // 未知调用转发到 fallback handler
import {ITransactionGuard, GuardManager} from "./base/GuardManager.sol"; // 交易前后钩子（Transaction Guard）
import {ModuleManager} from "./base/ModuleManager.sol";            // 模块注册与执行（含 Module Guard）
import {OwnerManager} from "./base/OwnerManager.sol";              // owner 链表 + threshold 管理

// ──── 通用工具层 ────
import {EIP7951} from "./common/EIP7951.sol";                      // P-256 (secp256r1) 预编译验签
import {NativeCurrencyPaymentFallback} from "./common/NativeCurrencyPaymentFallback.sol"; // receive() 接收 ETH
import {SecuredTokenTransfer} from "./common/SecuredTokenTransfer.sol"; // 安全 ERC20 transfer（兼容非标返回值）
import {SignatureDecoder} from "./common/SignatureDecoder.sol";    // 从 packed bytes 解析 v/r/s
import {Singleton} from "./common/Singleton.sol";                  // slot0 占位，确保 proxy 存储布局兼容
import {StorageAccessible} from "./common/StorageAccessible.sol";  // 按 slot 读 storage / simulateAndRevert

// ──── 外部库 & 接口 ────
import {SafeMath} from "./external/SafeMath.sol";                  // 溢出安全算术（Solidity <0.8 需要）
import {ISafe} from "./interfaces/ISafe.sol";                      // Safe 对外 ABI 接口
import {ISignatureValidator, ISignatureValidatorConstants} from "./interfaces/ISignatureValidator.sol"; // EIP-1271 常量
import {Enum} from "./interfaces/Enum.sol";                        // Operation 枚举：Call / DelegateCall

/**
 * @title Safe — 多签智能账户
 * @notice 基于 EIP-712 的多签钱包，支持签名消息确认交易。
 *
 * @dev
 * ╔═══════════════════════════════════════════════════════════════════╗
 * ║                     整体架构与设计理念                            ║
 * ╠═══════════════════════════════════════════════════════════════════╣
 * ║                                                                  ║
 * ║  1. Proxy + Singleton 模式                                       ║
 * ║     - Safe 部署时创建轻量 SafeProxy（仅存 singleton 地址 + slot） ║
 * ║     - 所有调用通过 delegatecall 转发到本合约（singleton）         ║
 * ║     - 状态存储在 Proxy 中，逻辑由 Singleton 提供                  ║
 * ║     - Singleton 的 constructor 设 threshold=1 使其自身不可用       ║
 * ║                                                                  ║
 * ║  2. 组件化继承                                                    ║
 * ║     Singleton → slot0 占位（与 Proxy 布局匹配）                   ║
 * ║     OwnerManager → owner 链表 + threshold                        ║
 * ║     ModuleManager → 可信模块注册与执行                            ║
 * ║     GuardManager → Transaction Guard 前后钩子                     ║
 * ║     FallbackManager → 未知调用转发                                ║
 * ║     SignatureDecoder → 签名解析                                   ║
 * ║     SecuredTokenTransfer → ERC20 安全转账                         ║
 * ║     StorageAccessible → 通用 storage 读取 / 模拟执行              ║
 * ║     EIP7951 → P-256 (secp256r1) 签名验证                         ║
 * ║                                                                  ║
 * ║  3. 交易执行流程 (execTransaction)                                ║
 * ║     onBeforeExecTransaction (hook)                                ║
 * ║     → 计算 EIP-712 txHash + nonce++                               ║
 * ║     → checkSignatures (≥ threshold 个有效 owner 签名)             ║
 * ║     → Guard.checkTransaction (前置策略检查)                       ║
 * ║     → execute (CALL/DELEGATECALL)                                 ║
 * ║     → handlePayment (gas 退款给 relayer)                          ║
 * ║     → emit ExecutionSuccess / ExecutionFailure                    ║
 * ║     → Guard.checkAfterExecution (后置一致性检查)                   ║
 * ║                                                                  ║
 * ║  4. 签名方案（5 种，按 v 值区分）                                  ║
 * ║     v=0  : 合约签名 (EIP-1271)                                    ║
 * ║     v=1  : 预批准哈希 (approveHash)                               ║
 * ║     v=2  : secp256r1 / P-256 签名 (EIP-7951/RIP-7212)            ║
 * ║     v=27/28 : 标准 ECDSA (secp256k1, EIP-712 typed data)         ║
 * ║     v>30 : eth_sign 风格 (对 hash 做 EIP-191 前缀后 ecrecover)    ║
 * ║                                                                  ║
 * ║  5. Gas 退款机制                                                  ║
 * ║     允许 relayer 代付 gas 并从 Safe 获得退款（ETH 或 ERC20）      ║
 * ║     gasPrice>0 时启用，退款额 = (gasUsed + baseGas) × gasPrice    ║
 * ║     gasPrice=0 时不退款，用于 owner 自行提交或 gas 估算           ║
 * ║                                                                  ║
 * ╚═══════════════════════════════════════════════════════════════════╝
 *
 * 核心概念：
 *   - Threshold：执行 Safe 交易所需的最少确认数。
 *   - Owners：控制 Safe 的地址列表，仅其可增删 owner、改 threshold、审批交易；由 OwnerManager 管理。
 *   - Transaction Hash：按 EIP-712 类型化结构数据计算得到的交易哈希。
 *   - Nonce：每笔交易使用不同 nonce，防止重放。
 *   - Signature：owner 对交易哈希的有效签名（支持 EOA、EIP-1271 合约、预批准哈希、P-256 等）。
 *   - Guards：在交易前后执行检查的合约。分两种：
 *       1. Transaction Guard（GuardManager）：针对 execTransaction 执行的交易。
 *       2. Module Guard（ModuleManager）：针对 execTransactionFromModule 执行的模块交易。
 *   - Modules：可扩展 Safe 写能力的合约，由 ModuleManager 管理；仅信任且审计过的模块应被启用。
 *   - Fallback：Fallback 处理器由 FallbackManager 管理，用于扩展对未知调用的处理；安全风险见 IFallbackManager。
 *   本实现为节省 gas 不发出交易级别事件，需依赖链上追踪节点做索引；需要事件时请使用 SafeL2.sol。
 *
 * @author Stefan George - @Georgi87
 * @author Richard Meissner - @rmeissner
 */
contract Safe is
    Singleton,                      // slot0: singleton 地址（与 SafeProxy 布局匹配，必须第一个继承）
    NativeCurrencyPaymentFallback,  // receive() — 允许 Safe 接收 ETH
    ModuleManager,                  // 模块链表 + execTransactionFromModule + Module Guard
    GuardManager,                   // Transaction Guard 的 set/get
    OwnerManager,                   // owner 链表 + threshold + addOwner/removeOwner/swapOwner
    SignatureDecoder,               // signatureSplit：从 packed bytes 解析 v/r/s
    SecuredTokenTransfer,           // transferToken：安全 ERC20 transfer（兼容不规范代币）
    ISignatureValidatorConstants,   // EIP-1271 magic value: 0x1626ba7e
    FallbackManager,                // fallback() — 未匹配调用转发到 handler
    StorageAccessible,              // getStorageAt / simulateAndRevert — 通用 storage 读取与模拟
    EIP7951,                        // p256Verify — secp256r1 预编译验签
    ISafe                           // 对外 ABI 接口
{
    using SafeMath for uint256;

    // ═══════════════════════════════════════════════════════════════════════
    //                        常量 & 状态变量
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc ISafe
     * @dev 语义化版本号，用于前端 SDK 和链下工具判断 Safe 实现版本。
     */
    string public constant override VERSION = "1.5.0";

    /**
     * @dev EIP-712 Domain Separator 的类型哈希（编译时预计算，节省运行时 gas）。
     *      = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)")
     *
     *      只绑定了 chainId 和 verifyingContract（即 Safe 地址），没有 name/version，
     *      这是 Safe 的特有选择：保证跨版本 domainSeparator 一致，同时绑定链和地址防跨链/跨合约重放。
     */
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH = 0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;

    /**
     * @dev SafeTx 结构体的 EIP-712 类型哈希（编译时预计算）。
     *      = keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,
     *                          uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,
     *                          address gasToken,address refundReceiver,uint256 nonce)")
     *
     *      这 10 个字段完整描述了一笔 Safe 交易的全部参数，owner 签名的就是这个结构。
     */
    bytes32 private constant SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;

    /**
     * @inheritdoc ISafe
     * @dev 交易序号，每次 execTransaction 时先取当前值参与哈希计算，再自增。
     *      防止同一笔交易被重放。nonce 只增不减，永不重置。
     *
     *      Storage Layout（继承顺序决定 slot 分配）:
     *        slot 0: singleton (Singleton)
     *        slot 1: modules[SENTINEL] (ModuleManager)
     *        slot 2: owners[SENTINEL] (OwnerManager)
     *        slot 3: ownerCount (OwnerManager)
     *        slot 4: threshold (OwnerManager)
     *        slot 5: nonce ← 这里
     *        slot 6: _deprecatedDomainSeparator
     *        slot 7: signedMessages (mapping)
     *        slot 8: approvedHashes (mapping)
     *      Guard/FallbackHandler/ModuleGuard 使用固定 slot（keccak256 派生），不占连续位置。
     */
    uint256 public override nonce;

    /**
     * @dev 旧版本预计算的 domainSeparator 缓存。v1.3+ 改为动态计算（支持链分叉时 chainId 变化），
     *      但保留此变量以维持与旧版本的存储布局兼容，不可移除。
     */
    bytes32 private _deprecatedDomainSeparator;

    /**
     * @inheritdoc ISafe
     * @dev signedMessages[hash] = 1 表示该 hash 已被足够数量的 owner 签署（由 SignMessageLib 设置）。
     *      用于 EIP-1271 isValidSignature 场景：外部合约可查询 Safe 是否"签署"了某消息。
     */
    mapping(bytes32 => uint256) public override signedMessages;

    /**
     * @inheritdoc ISafe
     * @dev approvedHashes[owner][hash] = 1 表示该 owner 已预批准此 hash。
     *      用于 v=1 签名类型：owner 先调用 approveHash(hash) 上链，execTransaction 时无需提供 ECDSA 签名。
     *      适用场景：硬件钱包/合约钱包无法直接签 EIP-712 数据时的替代方案。
     *      注意：一旦批准无法撤销，行为类似 ECDSA 签名。
     */
    mapping(address => mapping(bytes32 => uint256)) public override approvedHashes;

    // ═══════════════════════════════════════════════════════════════════════
    //                           构造函数
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Singleton 合约的构造函数 — 使 singleton 自身不可作为钱包使用。
     * @dev 设 threshold=1 后，setupOwners 会因 "threshold > 0" 而 revert（错误码 GS200），
     *      从而阻止任何人对 singleton 本身调用 setup()。
     *      这是 Proxy 模式的标准保护措施：singleton 只提供逻辑，不持有资产。
     *      真正的 Safe 实例是 SafeProxy，由 SafeProxyFactory 部署，
     *      部署后通过 proxy.setup() 完成初始化。
     */
    constructor() {
        threshold = 1;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       初始化（仅调用一次）
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc ISafe
     * @dev Safe 的一次性初始化入口，由 SafeProxyFactory 在部署 proxy 后立即调用。
     *
     *      初始化顺序（顺序有讲究）：
     *        1. emit SafeSetup — 先发事件，确保后续 delegatecall 中的事件顺序正确
     *        2. setupOwners — 初始化 owner 链表与 threshold（内含 threshold>0 防重入检查）
     *        3. internalSetFallbackHandler — 设置 fallback 处理器
     *        4. setupModules — 初始化模块链表，可选 delegatecall(to, data) 做进一步配置
     *        5. handlePayment — 可选地支付部署费用给 deployer/relayer
     *
     *      ⚠️ 安全注意事项：
     *      - 如果 proxy 创建时未调用 setup，任何人都可以抢先调用 setup 接管 proxy
     *      - SafeProxyFactory.createProxyWithCallback 会在同一笔 tx 中创建 + 初始化，避免此风险
     *      - `to` 参数允许 delegatecall 任意合约，常用于一次性批量 enableModule / setGuard
     */
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external override {
        // 乐观地先发事件：后续 setupModules 中的 delegatecall 可能触发 addOwner/changeThreshold 等事件，
        // 先发 SafeSetup 可确保链下索引器按正确顺序重建 Safe 配置。
        emit SafeSetup(msg.sender, _owners, _threshold, to, fallbackHandler);

        // setupOwners 内部检查 threshold>0 防止重复调用（singleton 的 constructor 已设 threshold=1）
        setupOwners(_owners, _threshold);
        if (fallbackHandler != address(0)) internalSetFallbackHandler(fallbackHandler);
        // setupOwners 保证了仅能初始化一次，因此 setupModules 无需额外的初始化检查
        setupModules(to, data);

        if (payment > 0) {
            // 复用 handlePayment 实现部署费支付。
            // 技巧：令 baseGas=0, gasPrice=1, gasUsed=payment → amount = (payment + 0) × 1 = payment
            // 避免为 setup 单独写支付逻辑，减少字节码大小（EIP-170 24KB 限制）。
            handlePayment(payment, 0, 1, paymentToken, paymentReceiver);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                   核心：多签交易执行入口
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc ISafe
     * @dev 这是 Safe 最核心的函数——所有多签交易的入口。完整执行流程：
     *
     *      ┌─────────────────────────────────────────────────────────────┐
     *      │ 1. onBeforeExecTransaction (virtual hook)                   │
     *      │    - Safe 基类为空实现                                       │
     *      │    - SafeL2 在此发出 SafeMultiSigTransaction 事件            │
     *      ├─────────────────────────────────────────────────────────────┤
     *      │ 2. 计算 EIP-712 txHash + nonce 自增                         │
     *      │    - nonce++ 保证每笔 tx 哈希唯一，防重放                    │
     *      ├─────────────────────────────────────────────────────────────┤
     *      │ 3. checkSignatures                                          │
     *      │    - 验证 ≥ threshold 个有效 owner 签名                      │
     *      │    - 签名按 owner 地址升序排列，防重复                       │
     *      ├─────────────────────────────────────────────────────────────┤
     *      │ 4. Guard.checkTransaction (前置策略检查)                     │
     *      │    - 可选：限制 to/value/operation 等                        │
     *      ├─────────────────────────────────────────────────────────────┤
     *      │ 5. Gas 校验 (EIP-150 63/64 规则)                            │
     *      ├─────────────────────────────────────────────────────────────┤
     *      │ 6. execute(to, value, data, operation, gas)                 │
     *      │    - CALL 或 DELEGATECALL                                    │
     *      ├─────────────────────────────────────────────────────────────┤
     *      │ 7. handlePayment (gas 退款)                                 │
     *      │    - gasPrice > 0 时向 relayer 支付 ETH 或 ERC20             │
     *      ├─────────────────────────────────────────────────────────────┤
     *      │ 8. emit ExecutionSuccess / ExecutionFailure                 │
     *      ├─────────────────────────────────────────────────────────────┤
     *      │ 9. Guard.checkAfterExecution (后置一致性检查)                │
     *      └─────────────────────────────────────────────────────────────┘
     *
     *      设计要点：
     *      - 即使内部调用失败（success=false），nonce 仍递增、gas 费仍支付。
     *        这避免了 relayer 因目标调用失败而无法获得补偿的问题。
     *      - gasPrice=0 + safeTxGas=0 是特殊的 "estimateGas 模式"：
     *        内部调用失败时直接 bubble up revert，便于二分搜索最小 gas。
     *      - signatures 参数为 memory 而非 calldata，因为 EIP-1271 校验需要传递给外部合约。
     */
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable override returns (bool success) {
        // ── Step 1: 子类钩子（SafeL2 在此发出完整交易事件，便于 L2 链下索引） ──
        onBeforeExecTransaction(to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, signatures);

        bytes32 txHash;
        // 使用 {} 作用域限制局部变量生命周期，避免 Solidity "stack too deep" 错误
        {
            // ── Step 2: 计算 EIP-712 交易哈希 ──
            // nonce++ 是后自增：先用当前 nonce 参与哈希计算，再 +1
            // 这保证了每笔交易的哈希唯一性，且 nonce 严格递增
            txHash = getTransactionHash(
                to,
                value,
                data,
                operation,
                safeTxGas,
                baseGas,
                gasPrice,
                gasToken,
                refundReceiver,
                nonce++
            );
            // ── Step 3: 验证签名 ──
            // 内部会检查 threshold > 0、签名数 ≥ threshold、每个签名来自不同且有效的 owner、
            // owner 地址严格升序（防重复与重排攻击）
            checkSignatures(msg.sender, txHash, signatures);
        }

        // ── Step 4: Transaction Guard 前置检查 ──
        address guard = getGuard();
        {
            if (guard != address(0)) {
                // Guard 可以根据 to/value/data/operation 等参数决定是否允许执行
                // 典型用例：禁止 delegatecall、限制转账额度、白名单目标地址等
                ITransactionGuard(guard).checkTransaction(
                    to,
                    value,
                    data,
                    operation,
                    safeTxGas,
                    baseGas,
                    gasPrice,
                    gasToken,
                    refundReceiver,
                    signatures,
                    msg.sender
                );
            }
        }

        // ── Step 5: Gas 充足性校验 ──
        // EIP-150 规定：CALL/DELEGATECALL 最多传递当前 gas 的 63/64，保留 1/64 给调用方。
        // 因此要确保 gasleft() 足够：
        //   (safeTxGas << 6) / 63  ≈  safeTxGas × 64/63  →  需要的总 gas（含 1/64 保留）
        //   safeTxGas + 2500       →  执行 gas + 事件发射 gas 的下界
        //   取两者较大值，再加 500 gas（到达 execute 调用点的开销）
        if (gasleft() < ((safeTxGas << 6) / 63).max(safeTxGas + 2500) + 500) revertWithError("GS010");
        {
            // ── Step 6: 执行目标调用 ──
            uint256 gasUsed = gasleft();
            // gasPrice == 0 → 不需要精确计量 gas → 把几乎所有剩余 gas 传给 execute
            // 留 2500 给后续的事件发射和变量赋值
            success = execute(to, value, data, operation, gasPrice == 0 ? (gasleft() - 2500) : safeTxGas);
            gasUsed = gasUsed.sub(gasleft());

            // Gas 估算模式：safeTxGas=0 且 gasPrice=0 时，失败的调用直接 bubble up revert 数据
            // 这让 eth_estimateGas 可以通过二分法找到刚好不 revert 的最小 gas
            if (!success && safeTxGas == 0 && gasPrice == 0) {
                /* solhint-disable no-inline-assembly */
                /// @solidity memory-safe-assembly
                assembly {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
                /* solhint-enable no-inline-assembly */
            }

            // ── Step 7: Gas 退款 ──
            uint256 payment = 0;
            if (gasPrice > 0) {
                // 仅在 gasPrice > 0 时支付退款（gasPrice=0 表示 owner 自行提交，不需要退款）
                payment = handlePayment(gasUsed, baseGas, gasPrice, gasToken, refundReceiver);
            }

            // ── Step 8: 发出执行结果事件 ──
            if (success) emit ExecutionSuccess(txHash, payment);
            else emit ExecutionFailure(txHash, payment);
        }
        {
            // ── Step 9: Transaction Guard 后置检查 ──
            // Guard 可以验证执行后状态是否符合预期（如 owner 列表未被篡改、资产余额正常等）
            if (guard != address(0)) {
                ITransactionGuard(guard).checkAfterExecution(txHash, success);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      Gas 退款机制
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice 处理 Safe 交易的 gas 费支付——Safe 的"元交易/Relayer"机制核心。
     *
     * @dev 设计意图：
     *      Safe 的 owner 可能无 ETH 支付 gas，但 Safe 中持有资产。
     *      通过此机制，relayer 代为提交交易，Safe 用 ETH 或 ERC20 补偿 relayer。
     *      owner 签名中已包含 gasPrice/gasToken/refundReceiver，relayer 无法篡改退款参数。
     *
     *      退款公式：payment = (gasUsed + baseGas) × effectiveGasPrice
     *        - gasUsed = 执行 execute() 实际消耗的 gas
     *        - baseGas = 签名校验、Guard 检查等执行外开销，由 owner 签名时预估
     *        - ETH 模式：effectiveGasPrice = min(gasPrice, tx.gasprice)，防止 relayer 设超高 gas price
     *        - ERC20 模式：effectiveGasPrice = gasPrice（链上无法获取 ERC20 的市场汇率）
     *
     * @param gasUsed 本次 Safe 交易消耗的 gas。
     * @param baseGas 与执行无关的固定 gas（如基础交易费、签名校验、本次支付的 gas 等）。
     * @param gasPrice 用于计算支付金额的 gas 单价。
     * @param gasToken 支付用的代币地址，address(0) 表示用原生 ETH。
     * @param refundReceiver 接收 gas 费退款地址，address(0) 表示使用 tx.origin。
     * @return payment 实际支付的代币/原生币数量。
     */
    function handlePayment(
        uint256 gasUsed,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver
    ) private returns (uint256 payment) {
        // 未指定退款地址时向 tx.origin 退款 —— tx.origin 通常是最初发起交易的 EOA (relayer)
        // 使用 tx.origin 而非 msg.sender：如果中间有合约转发，仍能退到最终的 relayer
        // solhint-disable-next-line avoid-tx-origin
        address payable receiver = refundReceiver == address(0) ? payable(tx.origin) : refundReceiver;
        if (gasToken == address(0)) {
            // 原生币退款：取 min(gasPrice, tx.gasprice) 防止 relayer 故意抬高 gas price 多取退款
            payment = gasUsed.add(baseGas).mul(gasPrice < tx.gasprice ? gasPrice : tx.gasprice);
            (bool refundSuccess, ) = receiver.call{value: payment}("");
            if (!refundSuccess) revertWithError("GS011");
        } else {
            // ERC20 退款：无法在链上比较 ERC20 价格与 gas 成本，直接按 gasPrice 计算
            // owner 签名时应谨慎设置 gasPrice，避免被 relayer 利用
            payment = gasUsed.add(baseGas).mul(gasPrice);
            if (!transferToken(gasToken, receiver, payment)) revertWithError("GS012");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        签名验证系统
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice 验证合约签名（EIP-1271）是否有效，无效则 revert。
     * @dev 当 v=0 时进入此分支。签名数据编码方式：
     *
     *      signatures 的整体布局（以 3 个签名为例，其中第 2 个是合约签名）：
     *      ┌──────────────────────────────────────────────────────────┐
     *      │ 静态部分 (每条 65 字节)                                    │
     *      │  [0..64]   签名 #0: r(32) || s(32) || v(1)              │
     *      │  [65..129] 签名 #1: r=owner地址(32) || s=offset(32) || v=0(1) │
     *      │  [130..194] 签名 #2: r(32) || s(32) || v(1)             │
     *      ├──────────────────────────────────────────────────────────┤
     *      │ 动态部分 (合约签名数据，offset 指向此处)                   │
     *      │  [offset..offset+31]       contractSignatureLen (32 bytes)│
     *      │  [offset+32..offset+32+len-1] 实际合约签名数据            │
     *      └──────────────────────────────────────────────────────────┘
     *
     *      独立为函数是为了兼容 Certora 形式化验证工具
     *      （内联 assembly 会导致 Certora 指针分析失败，切换到 failsafe 模式）。
     *
     * @param owner 签名的合约 owner 地址（编码在 r 中）。
     * @param dataHash 待验证的哈希。
     * @param signatures 完整的 packed 签名数据。
     * @param offset 合约签名数据在 signatures 中的偏移（即 s 的值）。
     */
    function checkContractSignature(address owner, bytes32 dataHash, bytes memory signatures, uint256 offset) internal view {
        // 边界检查 1：offset 处至少能读出 32 字节的 length
        if (offset.add(32) > signatures.length) revertWithError("GS022");

        // 读取合约签名的长度
        uint256 contractSignatureLen;
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            contractSignatureLen := mload(add(add(signatures, offset), 0x20))
        }
        /* solhint-enable no-inline-assembly */
        // 边界检查 2：length + data 不能超出 signatures 总长
        if (offset.add(32).add(contractSignatureLen) > signatures.length) revertWithError("GS023");

        // 构建指向合约签名数据的 bytes 指针（跳过前 32 字节 length 字段）
        bytes memory contractSignature;
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            contractSignature := add(add(signatures, offset), 0x20)
        }
        /* solhint-enable no-inline-assembly */

        // 调用 owner 合约的 EIP-1271 isValidSignature，期望返回 magic value 0x1626ba7e
        if (ISignatureValidator(owner).isValidSignature(dataHash, contractSignature) != EIP1271_MAGIC_VALUE) revertWithError("GS024");
    }

    /**
     * @inheritdoc ISafe
     * @dev 便捷包装：自动使用当前 threshold 作为所需签名数。
     *      先缓存 threshold 到栈变量以避免多次 SLOAD（节省 ~2100 gas / 额外读取）。
     */
    function checkSignatures(address executor, bytes32 dataHash, bytes memory signatures) public view override {
        uint256 _threshold = threshold;
        if (_threshold == 0) revertWithError("GS001"); // Safe 未初始化
        checkNSignatures(executor, dataHash, signatures, _threshold);
    }

    /**
     * @inheritdoc ISafe
     * @dev 签名验证的核心实现 —— Safe 安全模型的基石。
     *
     *      Safe 支持 5 种签名方案，通过 v 值区分：
     *
     *      ┌────────┬──────────────────────────────────────────────────────────────┐
     *      │  v 值   │ 含义与验证方式                                              │
     *      ├────────┼──────────────────────────────────────────────────────────────┤
     *      │  0     │ 合约签名 (EIP-1271)                                          │
     *      │        │ r = owner 合约地址                                           │
     *      │        │ s = 动态签名数据在 signatures 中的偏移                         │
     *      │        │ 验证: owner.isValidSignature(dataHash, sig) == 0x1626ba7e    │
     *      ├────────┼──────────────────────────────────────────────────────────────┤
     *      │  1     │ 预批准哈希                                                    │
     *      │        │ r = owner 地址                                               │
     *      │        │ 验证: executor == owner || approvedHashes[owner][hash] == 1  │
     *      │        │ 用途: 硬件钱包/合约钱包无法签 EIP-712 时的替代方案              │
     *      ├────────┼──────────────────────────────────────────────────────────────┤
     *      │  2     │ secp256r1 / P-256 (EIP-7951/RIP-7212)                       │
     *      │        │ r = owner 地址 (= keccak256(qx, qy) 的后 20 字节)            │
     *      │        │ s = 动态数据偏移 → 128 字节: sig_r(32) + sig_s(32) + qx(32) + qy(32) │
     *      │        │ 用途: Passkey/WebAuthn 等使用 P-256 曲线的认证方式            │
     *      ├────────┼──────────────────────────────────────────────────────────────┤
     *      │ 27/28  │ 标准 ECDSA (secp256k1)                                      │
     *      │        │ 直接 ecrecover(dataHash, v, r, s) 得到 owner 地址             │
     *      │        │ 这是最常见的 EOA 签名方式                                     │
     *      ├────────┼──────────────────────────────────────────────────────────────┤
     *      │ >30    │ eth_sign 风格                                                │
     *      │        │ 先对 dataHash 加 EIP-191 前缀: "\x19Ethereum Signed Message:\n32" + dataHash │
     *      │        │ 再 ecrecover，v 需减 4 还原为 27/28                           │
     *      │        │ 用途: 某些钱包不支持 EIP-712，只支持 personal_sign            │
     *      └────────┴──────────────────────────────────────────────────────────────┘
     *
     *      防重复与排序机制：
     *      - 要求 currentOwner > lastOwner（严格升序），保证同一 owner 不能签两次
     *      - lastOwner 初始为 address(0)，所以第一个 owner 地址必须 > 0
     *      - 这也意味着签名提交前需要按 owner 地址升序排列
     *
     *      ECDSA 可展性 (malleability)：
     *      - 本实现不强制 s 在椭圆曲线下半部分
     *      - 因为 Safe 有 nonce + owner 升序排列 两重机制防重放/防重复，无需额外限制
     *
     * @param executor 交易提交者地址。v=1 时，executor 等同于自动批准的 owner（⚠️ 安全敏感）。
     * @param dataHash 待验证的哈希（交易哈希或消息哈希）。
     * @param signatures 紧凑编码的签名序列。
     * @param requiredSignatures 所需的有效签名数量。
     */
    function checkNSignatures(
        address executor,
        bytes32 dataHash,
        bytes memory signatures,
        uint256 requiredSignatures
    ) public view override {
        // 最低长度检查：静态部分至少需要 requiredSignatures × 65 字节
        if (signatures.length < requiredSignatures.mul(65)) revertWithError("GS020");

        address lastOwner = address(0);   // 上一个已验证的 owner，用于强制升序
        address currentOwner;
        uint256 v;
        bytes32 r;
        bytes32 s;
        uint256 i;

        for (i = 0; i < requiredSignatures; ++i) {
            // 从 packed signatures 中解析第 i 条签名的 v, r, s
            (v, r, s) = signatureSplit(signatures, i);

            if (v == 0) {
                // ──── v=0: 合约签名 (EIP-1271) ────
                // r 中编码的是合约 owner 的地址
                currentOwner = address(uint160(uint256(r)));

                // s 指向动态签名数据的偏移，必须位于静态部分之后（否则会覆盖其他签名的数据）
                if (uint256(s) < requiredSignatures.mul(65)) revertWithError("GS021");

                // 调用 owner 合约的 isValidSignature(dataHash, contractSignature)
                checkContractSignature(currentOwner, dataHash, signatures, uint256(s));

            } else if (v == 1) {
                // ──── v=1: 预批准哈希 ────
                // owner 地址编码在 r 中
                currentOwner = address(uint160(uint256(r)));
                // 两种方式视为"已批准"：
                //   1. executor == currentOwner → 提交者自身即为 owner，隐式批准
                //   2. approvedHashes[owner][hash] == 1 → owner 之前调用过 approveHash()
                // ⚠️ 如果 executor 是 owner，threshold 实质上减少了 1
                if (executor != currentOwner && approvedHashes[currentOwner][dataHash] == 0) revertWithError("GS025");

            } else if (v == 2) {
                // ──── v=2: secp256r1 / P-256 签名 (Passkey/WebAuthn) ────
                // 与 v=0 类似：r = owner 地址，s = 偏移指向 128 字节动态数据
                // 动态数据布局: sig_r(32) || sig_s(32) || qx(32) || qy(32)
                // owner 地址 = keccak256(qx || qy) 的后 20 字节（与 secp256k1 地址派生方式一致）
                currentOwner = address(uint160(uint256(r)));

                // 偏移不能指向静态部分
                if (uint256(s) < requiredSignatures.mul(65)) revertWithError("GS021");
                // 动态部分固定 128 字节，检查不越界
                if (uint256(s).add(128) > signatures.length) revertWithError("GS027");

                uint256 qx;
                uint256 qy;
                address signerAddress;
                /* solhint-disable no-inline-assembly */
                /// @solidity memory-safe-assembly
                assembly {
                    // signatures 在内存中: [length(32)] [data...]
                    // sig 指向动态部分的起始位置
                    let sig := add(signatures, add(s, 0x20))

                    // 读取 P-256 签名的 r, s 分量（覆盖栈上的 r, s 变量）
                    r := mload(sig)
                    s := mload(add(sig, 0x20))
                    // 读取公钥坐标
                    qx := mload(add(sig, 0x40))
                    qy := mload(add(sig, 0x60))

                    // 从公钥坐标派生地址：address = keccak256(qx || qy) 的后 20 字节
                    signerAddress := keccak256(add(sig, 0x40), 0x40)
                }
                /* solhint-enable no-inline-assembly */
                // 验证：r 中声明的 owner 地址必须与公钥派生地址一致，且 P-256 签名有效
                if (currentOwner != signerAddress || !p256Verify(dataHash, r, s, qx, qy)) revertWithError("GS028");

            } else if (v > 30) {
                // ──── v>30: eth_sign 风格 ────
                // 某些钱包（如早期 MetaMask）不支持 EIP-712 signTypedData，
                // 只能用 personal_sign 对原始哈希签名。
                // personal_sign 会在签名前自动加 "\x19Ethereum Signed Message:\n32" 前缀，
                // 所以验证时需要对 dataHash 加相同前缀再 ecrecover。
                // v 值被加了 4（31=27, 32=28），需要减 4 还原。
                currentOwner = ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash)), uint8(v - 4), r, s);

            } else {
                // ──── v=27 或 28: 标准 ECDSA (EIP-712 signTypedData) ────
                // 最常见的签名方式：owner 直接对 EIP-712 结构化数据签名
                currentOwner = ecrecover(dataHash, uint8(v), r, s);
            }

            // ──── 签名有效性与排序检查 ────
            // 1. currentOwner > lastOwner → 严格升序，防止同一 owner 签两次
            // 2. owners[currentOwner] != 0 → 在 owner 链表中（链表中的 owner 指向下一个，不为 0）
            // 3. currentOwner != SENTINEL_OWNERS → 排除哨兵地址 address(0x1)
            if (currentOwner <= lastOwner || owners[currentOwner] == address(0) || currentOwner == SENTINEL_OWNERS)
                revertWithError("GS026");
            lastOwner = currentOwner;
        }
    }

    // ──── 向后兼容的签名验证接口（v1.3 遗留） ────

    /**
     * @notice 旧版签名验证接口，`data` 参数被完全忽略。
     * @dev 仅为向后兼容而保留。新代码应使用 `checkSignatures(address,bytes32,bytes)`。
     *      ⚠️ 安全警告：此函数使用 msg.sender 作为 executor。
     *      如果调用者是 Safe 的 owner，它可以用 v=1 预批准签名方式无需实际签名即可通过验证，
     *      等效于将 threshold 减少 1。确保调用者不是恶意的 owner。
     */
    function checkSignatures(bytes32 dataHash, bytes calldata data, bytes memory signatures) external view {
        data; // 显式引用以消除 unused parameter 编译器警告
        checkSignatures(msg.sender, dataHash, signatures);
    }

    /**
     * @notice 旧版签名验证接口，`data` 参数被完全忽略。
     * @dev 仅为向后兼容而保留。新代码应使用 `checkNSignatures(address,bytes32,bytes,uint256)`。
     *      同样存在 executor == msg.sender 的安全注意事项（见上方说明）。
     */
    function checkNSignatures(bytes32 dataHash, bytes calldata data, bytes memory signatures, uint256 requiredSignatures) external view {
        data;
        checkNSignatures(msg.sender, dataHash, signatures, requiredSignatures);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        哈希预批准
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc ISafe
     * @dev 允许 owner 预先批准一个交易/消息哈希，之后在 checkNSignatures 中以 v=1 方式验证。
     *
     *      使用场景：
     *      1. 硬件钱包无法签 EIP-712 数据 → owner 用硬件钱包发送 approveHash 交易
     *      2. 合约钱包 owner → 通过合约调用 approveHash
     *      3. 多步收集签名 → 部分 owner 先 approveHash，最后由某人收集签名并执行
     *
     *      ⚠️ 批准后无法撤销（与 ECDSA 签名行为一致：一旦签名泄露无法回收）。
     *      Owner 被移除后，其已批准的哈希仍存在于 mapping 中，但 checkNSignatures 会在
     *      owners[currentOwner] == address(0) 时拒绝（移除 owner 后其链表指针被置 0）。
     */
    function approveHash(bytes32 hashToApprove) external override {
        // 仅允许当前 owner 调用（owners[addr] != 0 表示在链表中）
        if (owners[msg.sender] == address(0)) revertWithError("GS030");
        approvedHashes[msg.sender][hashToApprove] = 1;
        emit ApproveHash(hashToApprove, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                   EIP-712 哈希计算
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc ISafe
     * @dev 动态计算 EIP-712 Domain Separator（每次调用时根据当前 chainId 计算）。
     *
     *      v1.3 之前使用缓存的 _deprecatedDomainSeparator，但在链分叉（如 ETH/ETC 分叉）时
     *      chainId 会改变，缓存值不再正确。v1.3+ 改为每次动态计算，虽多消耗约 ~200 gas，
     *      但确保了分叉安全性。
     *
     *      Domain Separator = keccak256(DOMAIN_SEPARATOR_TYPEHASH || chainId || address(this))
     *      - chainId: 防止跨链重放
     *      - address(this): 防止同链不同 Safe 之间的签名重用
     *
     *      使用 assembly 是因为 Solidity 0.7.6 的内存分配效率较低，
     *      assembly 中直接使用 free memory pointer 处的空间计算哈希，无需正式分配内存。
     */
    function domainSeparator() public view override returns (bytes32 domainHash) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)

            // 内存布局 (96 bytes): [DOMAIN_SEPARATOR_TYPEHASH(32) | chainId(32) | address(this)(32)]
            mstore(ptr, DOMAIN_SEPARATOR_TYPEHASH)
            mstore(add(ptr, 32), chainid())
            mstore(add(ptr, 64), address())

            domainHash := keccak256(ptr, 96)
        }
        /* solhint-enable no-inline-assembly */
    }

    /**
     * @inheritdoc ISafe
     * @dev 计算 Safe 交易的 EIP-712 哈希 —— 这是 owner 签名时签署的目标。
     *
     *      EIP-712 签名哈希的三层结构：
     *      ┌─────────────────────────────────────────────────────────────┐
     *      │ txHash = keccak256(                                        │
     *      │   0x19 0x01                    ← EIP-712 标记前缀          │
     *      │   || domainSeparator           ← 绑定 chainId + Safe 地址  │
     *      │   || keccak256(                ← structHash               │
     *      │       SAFE_TX_TYPEHASH         ← SafeTx 类型标识           │
     *      │       || to                                                │
     *      │       || value                                             │
     *      │       || keccak256(data)        ← bytes 类型用哈希代替      │
     *      │       || operation                                         │
     *      │       || safeTxGas                                         │
     *      │       || baseGas                                           │
     *      │       || gasPrice                                          │
     *      │       || gasToken                                          │
     *      │       || refundReceiver                                    │
     *      │       || nonce                                             │
     *      │     )                                                      │
     *      │ )                                                          │
     *      └─────────────────────────────────────────────────────────────┘
     *
     *      ⚠️ 关于 dirty bits：
     *      address 和 Enum.Operation 等小于 256 bit 的类型在 assembly 中可能有脏高位。
     *      但此处大部分数据从 calldata 读取（每个参数占满 32 字节 slot），
     *      唯一从 storage 读取的 nonce 是 uint256，因此不受 dirty bits 影响。
     */
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) public view override returns (bytes32 txHash) {
        bytes32 domainHash = domainSeparator();

        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)

            // ── Step 1: 对 data (bytes) 做 keccak256 ──
            // EIP-712 规定动态类型(bytes/string)用其 keccak256 哈希替代
            calldatacopy(ptr, data.offset, data.length)
            let calldataHash := keccak256(ptr, data.length)

            // ── Step 2: 组装 SafeTx 结构体 (11 × 32 = 352 bytes) ──
            //
            // 内存布局:
            //   ptr +   0: SAFE_TX_TYPEHASH   ← 结构体类型标识
            //   ptr +  32: to                  ← 目标地址
            //   ptr +  64: value               ← ETH 数量
            //   ptr +  96: keccak256(data)     ← calldata 哈希
            //   ptr + 128: operation           ← 0=CALL, 1=DELEGATECALL
            //   ptr + 160: safeTxGas           ← 分配给目标调用的 gas
            //   ptr + 192: baseGas             ← 执行外的基础 gas 成本
            //   ptr + 224: gasPrice            ← 退款计算用的 gas 单价
            //   ptr + 256: gasToken            ← 退款代币地址 (0=ETH)
            //   ptr + 288: refundReceiver      ← 退款接收地址 (0=tx.origin)
            //   ptr + 320: nonce               ← 交易序号
            mstore(ptr, SAFE_TX_TYPEHASH)
            mstore(add(ptr, 32), to)
            mstore(add(ptr, 64), value)
            mstore(add(ptr, 96), calldataHash)
            mstore(add(ptr, 128), operation)
            mstore(add(ptr, 160), safeTxGas)
            mstore(add(ptr, 192), baseGas)
            mstore(add(ptr, 224), gasPrice)
            mstore(add(ptr, 256), gasToken)
            mstore(add(ptr, 288), refundReceiver)
            mstore(add(ptr, 320), _nonce)

            // ── Step 3: 计算 EIP-712 最终哈希 ──
            // 3a. structHash = keccak256(SafeTx 结构体, 352 bytes)
            //     将结果写入 ptr+64，后续复用 ptr 空间
            mstore(add(ptr, 64), keccak256(ptr, 352))

            // 3b. 组装 EIP-712 前缀: 0x1901 || domainSeparator || structHash
            //     0x1901 以 bytes32 左对齐写入 ptr → 实际 0x19 在 ptr+30, 0x01 在 ptr+31
            //     domainSeparator 写入 ptr+32 (覆盖了上面的部分数据，但 0x1901 已定位)
            //     structHash 已在 ptr+64
            mstore(ptr, 0x1901)
            mstore(add(ptr, 32), domainHash)

            // 3c. 从 ptr+30 开始，取 66 字节 (2+32+32) 做 keccak256 = 最终 txHash
            txHash := keccak256(add(ptr, 30), 66)
        }
        /* solhint-enable no-inline-assembly */
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        内部钩子
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice execTransaction 执行前的虚拟钩子 —— 子合约可 override 以注入自定义逻辑。
     *
     * @dev 设计模式：Template Method Pattern
     *      - Safe (基类): 空实现，不消耗额外 gas
     *      - SafeL2 (子类): override 此函数发出 SafeMultiSigTransaction 事件
     *        （包含完整交易参数 + nonce + msg.sender + threshold），
     *        使得在无 trace 支持的 L2 网络上也能通过事件索引 Safe 交易
     *
     *      在 L1 上使用 Safe 时不需要事件（可通过 trace 获取），
     *      因此基类留空以节省约 ~5000+ gas 的事件写入成本。
     */
    function onBeforeExecTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) internal virtual {}
}
