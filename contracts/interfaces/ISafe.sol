// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {Enum} from "./../interfaces/Enum.sol";
import {IFallbackManager} from "./IFallbackManager.sol";
import {IGuardManager} from "./IGuardManager.sol";
import {IModuleManager} from "./IModuleManager.sol";
import {INativeCurrencyPaymentFallback} from "./INativeCurrencyPaymentFallback.sol";
import {IOwnerManager} from "./IOwnerManager.sol";
import {IStorageAccessible} from "./IStorageAccessible.sol";

/**
 * @title ISafe
 * @notice Safe 智能账户主接口：多签钱包，支持基于 EIP-712 的签名确认、模块/守卫/fallback、原生币接收与存储可访问等能力。
 * @dev 聚合了 INativeCurrencyPaymentFallback、IModuleManager、IGuardManager、IOwnerManager、IFallbackManager、IStorageAccessible，
 *      定义 setup、execTransaction、签名校验、approveHash、domainSeparator、getTransactionHash、nonce、signedMessages、approvedHashes 等核心 API。
 * @author @safe-global/safe-protocol
 */
interface ISafe is INativeCurrencyPaymentFallback, IModuleManager, IGuardManager, IOwnerManager, IFallbackManager, IStorageAccessible {
    /**
     * @notice Safe 完成初始化时触发（仅会触发一次）。
     * @param initiator 调用 setup 的地址。
     * @param owners 初始 owner 列表。
     * @param threshold 初始签名门槛。
     * @param initializer 可选初始化合约地址（to 参数）；DELEGATECALL 执行 data。
     * @param fallbackHandler 初始配置的 fallback handler 地址。
     */
    event SafeSetup(address indexed initiator, address[] owners, uint256 threshold, address initializer, address fallbackHandler);
    /**
     * @notice 某 owner 对某交易/消息哈希进行了预批准（approveHash）。
     * @param approvedHash 被批准的哈希。
     * @param owner 执行批准的 owner。
     */
    event ApproveHash(bytes32 indexed approvedHash, address indexed owner);
    /**
     * @notice 对 Safe 消息进行签名时触发（用于链下签名场景）。
     * @param msgHash 被签名的消息哈希。
     */
    event SignMsg(bytes32 indexed msgHash);
    /**
     * @notice Safe 交易执行失败时触发（当 execTransaction 配置为不 revert 时）。
     * @dev nonce 仍会递增，gas 补偿仍会支付。
     * @param txHash Safe 交易哈希。
     * @param payment 本次交易支付的补偿金额。
     */
    event ExecutionFailure(bytes32 indexed txHash, uint256 payment);
    /**
     * @notice Safe 交易执行成功时触发。
     * @param txHash Safe 交易哈希。
     * @param payment 本次交易支付的补偿金额。
     */
    event ExecutionSuccess(bytes32 indexed txHash, uint256 payment);

    /**
     * @notice 初始化 Safe 账户存储（仅能调用一次）。
     * @dev
     * - 若代理创建后未调用 setup，任何人可调用并“认领”该代理，部署后务必尽快 setup。
     * - 可将 Safe 自身设为 owner（用于 EIP-7702 委托），若非 EOA 且无法自签名，可能永久锁死（例如 n/n 多签中一 owner 为 Safe 自身且非 7702 委托）。
     * - 事件 SafeSetup 使用传入参数发出，若 to 的 DELEGATECALL 修改了 owners/threshold/fallbackHandler，事件与最终状态可能不一致。
     * @param _owners 初始 owner 列表。
     * @param _threshold 执行 Safe 交易所需的最少确认数。
     * @param to 可选初始化合约；非 0 则对其 DELEGATECALL data；0 表示不执行额外初始化。
     * @param data 传给 to 的 calldata。
     * @param fallbackHandler 本合约的 fallback handler 地址。
     * @param paymentToken 本次支付使用的代币（0 表示原生币）。
     * @param payment 支付金额。
     * @param paymentReceiver 收款地址；0 表示 tx.origin。
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
    ) external;

    /**
     * @notice 执行一笔 Safe 交易：按 operation 向 to 发送 value 与 data，并向 refundReceiver 支付 gas 补偿（gasPrice * (safeTxGas + baseGas)，以 gasToken 计）。
     * @dev 手续费在交易失败时仍会支付；本方法不对 to 是否有代码、gasToken 是否为合约等做校验，由调用方保证。
     * @param to 目标地址。
     * @param value 发送的原生代币数量（wei）。
     * @param data 调用数据。
     * @param operation 0 = Call，1 = DelegateCall。
     * @param safeTxGas 用于 Safe 交易执行的 gas 上限。
     * @param baseGas 与执行无关的固定 gas（如基础费、签名校验、支付补偿）。
     * @param gasPrice 用于计算补偿的 gas 单价。
     * @param gasToken 支付补偿的代币地址，0 表示原生币。
     * @param refundReceiver 接收 gas 补偿的地址，0 表示 tx.origin。
     * @param signatures 打包的签名数据（ECDSA r||s||v、EIP-1271 合约签名或 approved hash）。
     * @return success 交易是否执行成功（未 revert）。
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
    ) external payable returns (bool success);

    /**
     * @notice 校验 signatures 对 (executor, dataHash) 是否满足当前 threshold；不满足则 revert。
     * @dev executor 会参与哈希绑定，传错可能使所需签名数少 1，请确保 executor 为合法执行者。
     * @param executor 执行该交易的地址（用于 EIP-712 绑定）。
     * @param dataHash 数据哈希（消息哈希或交易哈希）。
     * @param signatures 打包签名（ECDSA r||s||v、EIP-1271 或 approved hash）。
     */
    function checkSignatures(address executor, bytes32 dataHash, bytes memory signatures) external view;

    /**
     * @notice 校验是否至少有 requiredSignatures 个有效签名；不满足则 revert。
     * @dev EIP-1271 会做外部调用，需注意重入。
     * @param executor 执行者地址（传错可能减少所需签名数）。
     * @param dataHash 数据哈希。
     * @param signatures 打包签名。
     * @param requiredSignatures 需要的有效签名数量。
     */
    function checkNSignatures(address executor, bytes32 dataHash, bytes memory signatures, uint256 requiredSignatures) external view;

    /**
     * @notice 将 hashToApprove 标记为 msg.sender 已批准（用于“预批准哈希”式签名）。
     * @dev 批准后永久有效，无撤销接口，行为类似 ECDSA 签名不可撤销。
     * @param hashToApprove 待批准的、由本合约参与校验的哈希。
     */
    function approveHash(bytes32 hashToApprove) external;

    /**
     * @notice 返回 EIP-712 的 domain separator。
     * @return 当前合约的 domain separator 哈希。
     */
    function domainSeparator() external view returns (bytes32);

    /**
     * @notice 返回应由 owners 签名的交易哈希（EIP-712 结构哈希）。
     * @param to 目标地址。
     * @param value 原生代币数量。
     * @param data 调用数据。
     * @param operation 0 = Call，1 = DelegateCall。
     * @param safeTxGas Safe 交易 gas 上限。
     * @param baseGas 固定 gas 部分。
     * @param gasPrice 用于补偿计算的 gas 单价。
     * @param gasToken 支付补偿的代币，0 为原生币。
     * @param refundReceiver 补偿接收地址，0 为 tx.origin。
     * @param _nonce Safe 交易 nonce。
     * @return 交易哈希。
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
    ) external view returns (bytes32);

    /**
     * @notice 返回 Safe 合约的版本描述字符串。
     * @return 版本号字符串。
     */
    // solhint-disable-next-line func-name-mixedcase
    function VERSION() external view returns (string memory);

    /**
     * @notice 返回当前 Safe 交易 nonce（每笔 execTransaction 成功执行后递增）。
     * @return 当前 nonce。
     */
    function nonce() external view returns (uint256);

    /**
     * @notice 查询 messageHash 是否已被签名（链下签名后通过签名消息流程记录）。
     * @param messageHash 待检查的消息哈希。
     * @return 非零表示该哈希已被签名。
     */
    function signedMessages(bytes32 messageHash) external view returns (uint256);

    /**
     * @notice 查询 owner 是否已批准某 messageHash（approveHash）。
     * @param owner 可能批准过哈希的 owner。
     * @param messageHash 待检查的哈希。
     * @return 非零表示该 owner 已批准该哈希。
     */
    function approvedHashes(address owner, bytes32 messageHash) external view returns (uint256);
}
