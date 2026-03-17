// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ISafe} from "./../interfaces/ISafe.sol";
import {ISignatureValidator} from "./../interfaces/ISignatureValidator.sol";
import {Enum} from "./../interfaces/Enum.sol";
import {TokenCallbackHandler} from "./TokenCallbackHandler.sol";

/**
 * @title Compatibility Fallback Handler
 * @notice Safe 兼容型 fallback 处理器：为 1.3.0 之前与之后的 Safe 生态提供统一接口。
 * @dev 这个合约本身不是“钱包”，也不应被普通外部账户直接当业务合约调用；
 *      它的设计前提是：被某个 Safe 设置为 fallback handler 后，由 Safe 的
 *      `FallbackManager.fallback()` 在“未命中 Safe 自身函数选择器”时转发调用。
 *
 *      因此，阅读本合约时要始终带着一个上下文：
 *      - `msg.sender` 通常不是最终用户，而是调用它的 Safe Proxy
 *      - 本合约很多函数都会把 `msg.sender` 强制解释为 `ISafe`
 *      - 若脱离 Safe 上下文直接调用，行为可能未定义，甚至直接 revert
 *
 *      本合约主要承担三类兼容职责：
 *      1. EIP-1271：把“Safe 是否认可某个消息/签名”暴露为标准接口
 *      2. simulate(...)：为旧版工具保留“在 Safe 上下文里模拟执行”的入口
 *      3. encodeTransactionData(...) / getMessageHash(...)：
 *         为 SDK、前端和旧工具提供可复用的 EIP-712 编码辅助
 * @author Richard Meissner - @rmeissner
 */
contract CompatibilityFallbackHandler is TokenCallbackHandler, ISignatureValidator {
    // EIP-712 中 SafeMessage 结构体的 typehash：
    // keccak256("SafeMessage(bytes message)")
    // 用于把任意 bytes message 包装成 Safe 自己的消息域。
    bytes32 private constant SAFE_MSG_TYPEHASH = 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;

    // EIP-712 中 SafeTx 结构体的 typehash。
    // 注意这里编码的是交易“内容”，最终的待签名哈希还要再拼上 domainSeparator。
    bytes32 private constant SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;

    // ModuleManager 模块链表的哨兵节点。
    // getModules() 通过它作为分页起点读取前 10 个模块。
    address internal constant SENTINEL_MODULES = address(0x1);

    /**
     * @notice 计算“当前调用它的 Safe”对应的消息哈希。
     * @dev 这里默认 `msg.sender` 就是目标 Safe：
     *      - 正常路径：EOA/合约 -> Safe -> fallback handler.getMessageHash(...)
     *      - 因此处理器内部把 `msg.sender` 强制转成 `ISafe`
     *
     *      最终得到的不是原始 message 的 keccak256，而是带有：
     *      - Safe 特定结构体类型 `SafeMessage(bytes message)`
     *      - Safe 的 `domainSeparator()`
     *      的 EIP-712 digest。
     * @param message Raw message bytes.
     * @return Message hash.
     */
    function getMessageHash(bytes memory message) public view returns (bytes32) {
        return getMessageHashForSafe(ISafe(payable(msg.sender)), message);
    }

    /**
     * @notice 为指定 Safe 构造 EIP-712 SafeMessage 的完整 pre-image。
     * @dev 返回 Safe 消息哈希的 pre-image（哈希前原文）：
     *      0x19 0x01 || domainSeparator || safeMessageHash
     *
     *      其中：
     *      - `safeMessageHash = keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(message)))`
     *      - `domainSeparator` 由目标 Safe 决定，因此同一条 message 在不同 Safe 上哈希不同
     *
     *      这个函数通常给 SDK / 前端使用：它们可能想自己检查编码细节，或在链下复现待签名内容。
     * @param safe Safe to which the message is targeted.
     * @param message Message that should be encoded.
     * @return Encoded message.
     */
    function encodeMessageDataForSafe(ISafe safe, bytes memory message) public view returns (bytes memory) {
        bytes32 safeMessageHash = keccak256(abi.encode(SAFE_MSG_TYPEHASH, keccak256(message)));
        return abi.encodePacked(bytes1(0x19), bytes1(0x01), safe.domainSeparator(), safeMessageHash);
    }

    /**
     * @notice 为指定 Safe 计算一条消息的最终待签名哈希。
     * @dev 针对指定 Safe 计算消息哈希。
     *      与 {getMessageHash} 的区别仅在于：这里 Safe 不是隐式取 `msg.sender`，而是显式传入。
     * @param safe Safe to which the message is targeted.
     * @param message Message that should be hashed.
     * @return Message hash.
     */
    function getMessageHashForSafe(ISafe safe, bytes memory message) public view returns (bytes32) {
        return keccak256(encodeMessageDataForSafe(safe, message));
    }

    /**
     * @notice EIP-1271 标准接口实现：判断“当前 Safe 是否认可这份签名/消息”。
     * @dev 核心语义：
     *      - 这里校验的是 `ISafe(msg.sender)` 的签名规则，而不是本处理器自己的签名规则
     *      - `_dataHash` 会先被重新包装为 Safe Message 域下的哈希，再做验证
     *      - 空签名 `_signature.length == 0` 被解释为“检查该消息是否已被链上批准”
     *
     *      两条路径：
     *      1. 空签名：
     *         读取 `safe.signedMessages(messageHash)`，非 0 则表示该 Safe 已在链上认可该消息
     *      2. 非空签名：
     *         复用 Safe 原生的 `checkSignatures(...)` 做完整 owner 签名验证
     *
     *      这里特别把 executor 传成 `address(0)`，目的是禁用“caller approved signature”这类
     *      与 EIP-1271 语义容易混淆的捷径，确保 EIP-1271 行为更可预测。
     * @param _dataHash Hash of the data signed.
     * @param _signature Signature data.
     * @return The EIP-1271 magic value if the signature is valid, reverts otherwise.
     */
    function isValidSignature(bytes32 _dataHash, bytes calldata _signature) public view override returns (bytes4) {
        // Caller should be a Safe.
        ISafe safe = ISafe(payable(msg.sender));
        bytes memory messageData = encodeMessageDataForSafe(safe, abi.encode(_dataHash));
        bytes32 messageHash = keccak256(messageData);
        if (_signature.length == 0) {
            // 链上已批准消息路径：signMessage / SignMessageLib 会把该 messageHash 标记为已签。
            require(safe.signedMessages(messageHash) != 0, "Hash not approved");
        } else {
            // We explicitly do not allow caller approved signatures for EIP-1271 to prevent unexpected behaviour. This
            // is done by setting the executor address to `0` which can never be an owner of the Safe.
            safe.checkSignatures(address(0), messageHash, _signature);
        }
        return EIP1271_MAGIC_VALUE;
    }

    /**
     * @notice 返回当前 Safe 的前 10 个已启用模块。
     * @dev 返回当前 Safe 的前 10 个模块。
     *      这是一个兼容性辅助接口，底层仍然调用 `Safe.getModulesPaginated(...)`。
     *
     *      之所以只取 10 个，是沿用旧接口的简单展示语义，而不是完整模块枚举方案。
     * @return Array of modules.
     */
    function getModules() external view returns (address[] memory) {
        // Caller should be a Safe.
        ISafe safe = ISafe(payable(msg.sender));
        (address[] memory array, ) = safe.getModulesPaginated(SENTINEL_MODULES, 10);
        return array;
    }

    /**
     * @notice 在 Safe 自身上下文里模拟执行一次调用，并把结果作为 bytes 返回。
     * @dev 这个接口看起来像“普通调用 + 返回结果”，但内部实现其实是：
     *      1. 调回 Safe 自己的 `simulateAndRevert(...)`
     *      2. 让 Safe 以 `DELEGATECALL` 方式在自身 storage 上下文里执行目标逻辑
     *      3. 强制 revert，把 success/returndata 编码进 revert data
     *      4. 这里再把那段 revert data 解析出来，重新包装为正常返回值
     *
     *      为什么这么绕？
     *      - 因为我们想“观察执行结果”，但又不想留下任何状态副作用
     *      - `simulateAndRevert` 的策略正好满足：执行真实逻辑，但最后整体回滚
     *
     *      这也是 Safe 生态里很多“预执行 / 模拟 / 前端估算”工具的基础。
     *
     *      Inspired by <https://github.com/gnosis/util-contracts/blob/bb5fe5fb5df6d8400998094fb1b32a178a47c3a1/contracts/StorageAccessible.sol>.
     *      ⚠️⚠️⚠️ This function assumes the caller is a Safe contract and is only intended to be used as a fallback handler for a {Safe}.
     *      Using it in other ways may cause undefined behaviour. ⚠️⚠️⚠️
     * @param targetContract Address of the contract containing the code to execute.
     * @param calldataPayload Calldata that should be sent to the target contract (encoded method name and arguments).
     * @return response ABI 编码的模拟执行返回数据；若模拟本身失败，则本函数直接 revert。
     */
    function simulate(address targetContract, bytes calldata calldataPayload) external returns (bytes memory response) {
        // Suppress compiler warnings about not using parameters, while allowing
        // parameters to keep names for documentation purposes. This does not
        // generate code.
        targetContract;
        calldataPayload;

        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            // 写入 `simulateAndRevert(address,bytes)` 的 selector（0xb4faba09）。
            // 这里用字符串字面量只是为了方便获得右填充的 4 字节常量。
            mstore(ptr, "\xb4\xfa\xba\x09")

            // Abuse the fact that both this and the internal methods have the
            // same signature, and differ only in symbol name (and therefore,
            // selector) and copy calldata directly. This saves us approximately
            // 250 bytes of code and 300 gas at runtime over the
            // `abi.encodeWithSelector` builtin.
            calldatacopy(add(ptr, 0x04), 0x04, sub(calldatasize(), 0x04))

            let success := call(
                gas(),
                // 注意这里不是 call 到 `address(this)`（处理器自己），而是 call 回 `caller()`
                // 也就是当前调用本处理器的 Safe。这样实际命中的是 Safe 上的
                // `simulateAndRevert(address,bytes)`，从而在 Safe 上下文里执行模拟。
                caller(),
                0,
                ptr,
                calldatasize(),
                // The `simulateAndRevert` call should always revert, and
                // instead encodes whether or not it was successful in the
                // return data. The first 32-byte word of the return data
                // contains the `success` value, and the second 32-byte word
                // contains the response bytes length, so write them to memory
                // address 0x00 (Solidity scratch which is OK to use).
                0x00,
                0x40
            )

            // Double check that the call reverted as expected, and that the
            // `returndata` is long enough to hold the encoded success boolean
            // and response bytes length (64 bytes total). This will always be
            // the case if the caller is a Safe, but check anyway to make sure
            // this function does not make unexpected state changes when
            // called by other contracts.
            if or(success, lt(returndatasize(), 0x40)) {
                revert(0, 0)
            }

            // Allocate and copy the response bytes, making sure to increment
            // the free memory pointer accordingly (in case this method is
            // called as an internal function). The remaining `returndata[0x20:]`
            // contains the ABI encoded response bytes, so we can just copy it
            // as is to memory. Note that `returndatacopy` will revert if we
            // try to copy past the `returndatasize` bounds, so we don't need an
            // additional check here. However, do note that this will consume
            // all remaining gas. This is fine (since we don't aim to support
            // other callers that aren't Safes with the compatibility fallback
            // handler).
            let responseEncodedSize := add(mload(0x20), 0x20)
            response := mload(0x40)
            mstore(0x40, add(response, responseEncodedSize))
            returndatacopy(response, 0x20, responseEncodedSize)

            // `mload(0x00)` 读取的是 simulateAndRevert 编码出的 success 标志。
            // 如果模拟执行本身失败，则把 returnData 当作 revert data 再次抛出，
            // 使调用者看到与真实执行更接近的错误语义。
            if iszero(mload(0x00)) {
                revert(add(response, 0x20), responseEncodedSize)
            }
        }
        /* solhint-enable no-inline-assembly */
    }

    /**
     * @notice 返回 Safe 交易哈希的 pre-image（哈希前原文），供链下工具复现/检查。
     * @dev 这不是最终的 `txHash`，而是 `Safe.getTransactionHash(...)` 在做最后一次
     *      `keccak256(...)` 之前的那段 EIP-712 编码结果。
     *
     *      因此恒有：
     *      `keccak256(encodeTransactionData(...)) == Safe.getTransactionHash(...)`
     *
     *      这个接口存在的主要原因是兼容旧版工具链：有些 SDK / 前端并不想只拿最终 hash，
     *      而是希望拿到完整 pre-image 自己检查、存档或参与链下签名流程。
     *
     *      编码结构为：
     *      `0x19 0x01 || domainSeparator || keccak256(abi.encode(SAFE_TX_TYPEHASH, ...))`
     *
     *      For a given Safe, the invariant `getTransactionHash(...) == keccak256(encodeTransactionData(...))` holds true.
     * @param to Destination address of the Safe transaction.
     * @param value Native token value of the Safe transaction.
     * @param data Data payload of the Safe transaction.
     * @param operation Operation type of the Safe transaction: 0 for `CALL` and 1 for `DELEGATECALL`.
     * @param safeTxGas Gas that should be used for the Safe transaction.
     * @param baseGas Base gas costs that are independent of the transaction execution (e.g. base transaction fee, signature check, payment of the refund).
     * @param gasPrice Gas price that should be used for the payment calculation.
     * @param gasToken Token address (or 0 for the native token) that is used for the payment.
     * @param refundReceiver Address of receiver of the gas payment (or 0 for `tx.origin`).
     * @param nonce Transaction nonce.
     * @return Transaction hash pre-image bytes.
     */
    function encodeTransactionData(
        address to,
        uint256 value,
        bytes calldata data,
        Enum.Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) public view returns (bytes memory) {
        // 与 getMessageHash() 一样，这里默认 fallback handler 挂在某个 Safe 上，
        // 因而 `msg.sender` 就是目标 Safe。
        ISafe safe = ISafe(payable(msg.sender));
        bytes32 domainSeparator = safe.domainSeparator();
        bytes32 safeTxHash = keccak256(
            abi.encode(
                SAFE_TX_TYPEHASH,
                to,
                value,
                keccak256(data),
                operation,
                safeTxGas,
                baseGas,
                gasPrice,
                gasToken,
                refundReceiver,
                nonce
            )
        );
        return abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, safeTxHash);
    }
}
