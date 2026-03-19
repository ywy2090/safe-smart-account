// SPDX-License-Identifier: LGPL-3.0-only
// solhint-disable one-contract-per-file
pragma solidity >=0.7.0 <0.9.0;

import {ISafe, ExtensibleBase} from "./ExtensibleBase.sol";

/**
 * @title ERC1271
 * @notice ERC-1271 标准接口：合约通过 isValidSignature 声明其对给定 hash 的签名是否有效，供外部（如协议、前端）校验「合约账户」的签名。
 * @dev hash 通常为 EIP-712 digest 或任意 32 字节；signature 可为空（仅查 approved hash）、阈值签名字节、或本 Muxer 的扩展格式。返回 0x1626ba7e 表示有效。
 */
interface ERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue);
}

/**
 * @title ISafeSignatureVerifier
 * @notice 由 Muxer 按 domainSeparator 委托的签名校验器：在给定 EIP-712 域与编码数据下，判定 Safe 是否应返回 ERC-1271 魔术值。
 * @dev
 * 调用前 Muxer 已校验 _hash == EIP712Digest(domainSeparator, typeHash, encodeData)。verifier 仅需根据 safe/sender/typeHash/encodeData/payload
 * 及自身存储（如会话密钥、门限规则）判断是否通过；有效时返回 0x1626ba7e。safe 为委托方 Safe，sender 为调用 isValidSignature 的原始地址。
 */
interface ISafeSignatureVerifier {
    function isValidSafeSignature(
        ISafe safe,
        address sender,
        bytes32 _hash,
        bytes32 domainSeparator,
        bytes32 typeHash,
        bytes calldata encodeData,
        bytes calldata payload
    ) external view returns (bytes4 magic);
}

/**
 * @title ISignatureVerifierMuxer
 * @notice 按 Safe + domainSeparator 配置外部签名校验器，供 ERC-1271 按域路由。domainVerifiers 查询某 Safe 在某域下绑定的 verifier；setDomainVerifier 由 Safe 经 fallback 调用以绑定/解绑。
 */
interface ISignatureVerifierMuxer {
    function domainVerifiers(ISafe safe, bytes32 domainSeparator) external view returns (ISafeSignatureVerifier);

    function setDomainVerifier(bytes32 domainSeparator, ISafeSignatureVerifier verifier) external;
}

/**
 * @title SignatureVerifierMuxer
 * @notice 实现 ERC-1271，并按 EIP-712 domainSeparator 将校验委托给可配置的 ISafeSignatureVerifier；未配置或签名格式不匹配时回退到 Safe 默认逻辑（approved hash + 阈值签名）。
 * @dev
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 * 一、工作原理概览
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * 外部调用 Safe.isValidSignature(hash, signature) 时，Safe 无此函数 → fallback → 本 Handler。
 * 本合约根据 signature 的形态分两条路径：
 *
 *  【路径 A】扩展签名格式 + 已配置该域的 verifier
 *    - signature 前 4 字节为 0x5fd7e97d，且长度 ≥ 68，且 domainVerifiers[safe][domainSeparator] 已设置。
 *    - 先校验 _hash 与签名内 (domainSeparator, typeHash, encodeData) 构造的 EIP-712 digest 一致，再委托给
 *      verifier.isValidSafeSignature(safe, sender, _hash, domainSeparator, typeHash, encodeData, payload)。
 *    - 适用于 dApp 自有 EIP-712 域（如登录、授权），由外部合约按域实现自定义验签（会话密钥、门限等）。
 *
 *  【路径 B】默认路径（defaultIsValidSignature）
 *    - 不满足路径 A 时（空签名、普通多签、或未配置 verifier）：将 _hash 包装成 Safe 的 SafeMessage(bytes message)
 *      得到 messageHash，空签名则要求 safe.signedMessages(messageHash) 已置位，非空则交 safe.checkSignatures 做阈值多签校验。
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 * 二、扩展签名格式（路径 A 的 signature 布局）
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 *
 *  layout（ABI 编码）：
 *  ┌─────────────┬──────────────────┬──────────────────┬─────────────────┬─────────────────┐
 *  │ 4 bytes     │ 32 bytes         │ 32 bytes         │ bytes (动态)    │ bytes (动态)    │
 *  │ selector    │ domainSeparator  │ typeHash         │ encodeData      │ payload         │
 *  │ 0x5fd7e97d  │                  │                  │                 │                 │
 *  └─────────────┴──────────────────┴──────────────────┴─────────────────┴─────────────────┘
 *
 *  - domainSeparator / typeHash / encodeData 用于在 Muxer 内复算 EIP-712 digest，必须与传入的 _hash 一致，防止签名数据被篡改或错配。
 *  - payload 为任意字节，原样传给 verifier，可由 verifier 自行解析（如额外参数、nonce 等）。
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 * 三、按域授权（安全设计）
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * 每个 domainSeparator 必须由 Safe 显式 setDomainVerifier 绑定 verifier。恶意 verifier 无法为「未授权的域」
 * 通过校验，因为 Muxer 只会在 domainVerifiers[safe][domainSeparator] 非零时委托，且调用前会校验
 * _hash == EIP712Digest(domainSeparator, typeHash, encodeData)，避免 verifier 伪造或误用其他域的数据。
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 * 四、默认路径与 Safe 一致性的原因
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Safe 原生 ERC-1271 会对「原始 _hash」先包装成 SafeMessage(bytes message) 再算 messageHash，空签名查
 * signedMessages(messageHash)，非空签名用 messageHash 做 checkSignatures。defaultIsValidSignature 复现该逻辑，
 * 保证与 CompatibilityFallbackHandler / Safe 自身行为一致，便于兼容现有前端与协议。
 *
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 * 五、典型调用链
 * ═══════════════════════════════════════════════════════════════════════════════════════════════
 *
 *  路径 A：外部 → Safe.isValidSignature(hash, extSig) → Safe fallback → Handler.isValidSignature
 *          → 解析 extSig(selector+domain+typeHash+encodeData+payload) → 查 domainVerifiers[safe][domain]
 *          → 校验 hash == EIP712Digest(domain, typeHash, encodeData) → verifier.isValidSafeSignature(...) → 返回 magic。
 *
 *  路径 B：外部 → Safe.isValidSignature(hash, sig) → Safe fallback → Handler.isValidSignature
 *          → 不满足路径 A → defaultIsValidSignature → messageHash = EIP712(SafeMessage(_hash))
 *          → 空 sig 则 require(signedMessages(messageHash))；非空则 safe.checkSignatures(messageHash, sig) → 返回 magic。
 *
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
abstract contract SignatureVerifierMuxer is ExtensibleBase, ERC1271, ISignatureVerifierMuxer {
    // --- constants ---

    /** EIP-712 类型哈希：keccak256("SafeMessage(bytes message)")，默认路径下用 Safe 的 domainSeparator + 本常量包装 _hash 得到 messageHash。 */
    bytes32 private constant SAFE_MSG_TYPEHASH = 0x60b3cbf8b4a223d68d641b3b6ddf9a298e7f33710cf3d3a9d1146b5a6150fbca;
    /** 扩展签名格式的 selector：keccak256("safeSignature(bytes32,bytes32,bytes,bytes)")，用于识别「委托给外部 verifier」的签名，与路径 A 对应。 */
    bytes4 private constant SAFE_SIGNATURE_MAGIC_VALUE = 0x5fd7e97d;

    // --- storage ---

    /** 按 Safe 与 domainSeparator 存储该域下授权的签名校验器；未设置则走默认路径（路径 B）。 */
    mapping(ISafe => mapping(bytes32 => ISafeSignatureVerifier)) public override domainVerifiers;

    // --- events ---

    /** 某 Safe 对某 domainSeparator 绑定的 verifier 被 setDomainVerifier 更新时发出；newVerifier 为 0 表示该域改走默认路径。 */
    event ChangedDomainVerifier(
        ISafe indexed safe,
        bytes32 domainSeparator,
        ISafeSignatureVerifier oldVerifier,
        ISafeSignatureVerifier newVerifier
    );

    /**
     * @notice 为当前 Safe 绑定某 EIP-712 域的签名校验器；仅 Safe 通过 fallback 自调用有效（onlySelf）。
     * @dev 绑定后，当外部以「扩展签名格式」调用 isValidSignature(hash, sig) 且 sig 内 domainSeparator 与此处一致时，
     *      Muxer 会先校验 hash 与 EIP712Digest(domainSeparator, typeHash, encodeData) 一致，再委托给 newVerifier.isValidSafeSignature(...)。
     * @param domainSeparator 要绑定的域分隔符（通常为 dApp 的 EIP-712 domain hash）。
     * @param newVerifier 实现 ISafeSignatureVerifier 的合约；传 address(0) 可禁用该域委托，后续该域走默认路径。
     */
    function setDomainVerifier(bytes32 domainSeparator, ISafeSignatureVerifier newVerifier) public override onlySelf {
        ISafe safe = ISafe(payable(_msgSender()));
        ISafeSignatureVerifier oldVerifier = domainVerifiers[safe][domainSeparator];
        domainVerifiers[safe][domainSeparator] = newVerifier;
        emit ChangedDomainVerifier(safe, domainSeparator, oldVerifier, newVerifier);
    }

    /**
     * @notice 实现 ERC-1271：若 signature 为扩展格式且该 domain 已配置 verifier，则委托 verifier 校验；否则回退到 Safe 默认签名/approved hash 逻辑。
     * @param _hash 调用方声称已签名的 EIP-712 消息哈希（即 EIP-712 digest）。
     * @param signature 空表示「仅查 approved hash」；或为阈值签名字节；或为扩展格式（selector + domainSeparator + typeHash + encodeData + payload）。
     * @return magic 校验通过时返回 0x1626ba7e（ERC-1271 魔术值）。
     */
    function isValidSignature(bytes32 _hash, bytes calldata signature) external view override returns (bytes4 magic) {
        (ISafe safe, address sender) = _getContext();

        // ─── 路径 A：尝试按「扩展签名格式 + 域 verifier」处理 ───
        if (signature.length >= 4) {
            bytes4 sigSelector;
            /* solhint-disable no-inline-assembly */
            /// @solidity memory-safe-assembly
            assembly {
                sigSelector := calldataload(signature.offset)
            }
            /* solhint-enable no-inline-assembly */

            // 识别扩展格式：前 4 字节为 0x5fd7e97d，且至少含 domainSeparator(32) + typeHash(32) = 68 字节
            if (sigSelector == SAFE_SIGNATURE_MAGIC_VALUE && signature.length >= 68) {
                (bytes32 domainSeparator, bytes32 typeHash) = abi.decode(signature[4:68], (bytes32, bytes32));

                ISafeSignatureVerifier verifier = domainVerifiers[safe][domainSeparator];
                if (address(verifier) != address(0)) {
                    (, , bytes memory encodeData, bytes memory payload) = abi.decode(signature[4:], (bytes32, bytes32, bytes, bytes));

                    // 一致性校验：调用方传入的 _hash 必须等于用签名内 (domainSeparator, typeHash, encodeData) 算出的 EIP-712 digest，防止错域或篡改
                    if (keccak256(EIP712.encodeMessageData(domainSeparator, typeHash, encodeData)) == _hash) {
                        return verifier.isValidSafeSignature(safe, sender, _hash, domainSeparator, typeHash, encodeData, payload);
                    }
                }
            }
        }

        // ─── 路径 B：默认路径（空签名 / 普通多签 / 未配置 verifier）───
        return defaultIsValidSignature(safe, _hash, signature);
    }

    /**
     * @notice 默认路径（路径 B）：将 _hash 包装成 Safe 的 SafeMessage 结构后算 messageHash，再按「空签名 / 非空签名」走 approved hash 或阈值多签。
     * @dev
     * Safe 原生逻辑：isValidSignature(hash, sig) 内部会把 hash 当作「消息内容」，用 SafeMessage(bytes message) 即
     *   structHash = keccak256(SAFE_MSG_TYPEHASH || keccak256(abi.encode(hash)))，再与 domainSeparator 组成 EIP-712
     *   digest 得到 messageHash。空签名时要求该 messageHash 已被 approveHash 批准；非空时用 messageHash 做 checkSignatures。
     * 此处复现相同构造，保证与 Safe / CompatibilityFallbackHandler 行为一致。
     * @param safe 当前 Fallback 所属的 Safe。
     * @param _hash 声称已签名的原始数据哈希（通常为某 EIP-712 digest 或任意 32 字节）。
     * @param signature 空则仅查 safe.signedMessages(messageHash)；非空则交 safe.checkSignatures(0, messageHash, signature)。
     * @return magic 通过时返回 ERC1271.isValidSignature.selector (0x1626ba7e)。
     */
    function defaultIsValidSignature(ISafe safe, bytes32 _hash, bytes memory signature) internal view returns (bytes4 magic) {
        // SafeMessage(bytes message)：message 字段的编码为 abi.encode(keccak256(abi.encode(_hash)))
        bytes memory messageData = EIP712.encodeMessageData(
            safe.domainSeparator(),
            SAFE_MSG_TYPEHASH,
            abi.encode(keccak256(abi.encode(_hash)))
        );
        bytes32 messageHash = keccak256(messageData);

        if (signature.length == 0) {
            require(safe.signedMessages(messageHash) != 0, "Hash not approved");
        } else {
            safe.checkSignatures(address(0), messageHash, signature);
        }
        magic = ERC1271.isValidSignature.selector;
    }
}

/**
 * @title EIP712
 * @notice 构造 EIP-712 digest 的预像：0x19 0x01 || domainSeparator || structHash，其中 structHash = keccak256(typeHash || message)。
 * @dev
 * 本库在本合约内两处使用：
 * 1. isValidSignature 路径 A：用 (domainSeparator, typeHash, encodeData) 复算 digest，与传入的 _hash 比较，确保签名数据未被篡改或错配。
 * 2. defaultIsValidSignature：用 Safe 的 domainSeparator + SAFE_MSG_TYPEHASH + abi.encode(keccak256(abi.encode(_hash))) 构造 messageHash，与 Safe 原生 ERC-1271 逻辑一致。
 */
library EIP712 {
    /**
     * @notice 返回 EIP-712 编码后的 message 数据（用于计算 digest 或 structHash 的输入）。
     * @param domainSeparator 域分隔符（EIP-712 domain hash）。
     * @param typeHash 结构化数据类型哈希，如 keccak256("SafeMessage(bytes message)")。
     * @param message 类型化数据的编码（如 abi.encode(keccak256(abi.encode(hash)))）。
     * @return 预像字节：0x19 0x01 || domainSeparator || keccak256(typeHash || message)；对返回值做 keccak256 即得 EIP-712 digest。
     */
    function encodeMessageData(bytes32 domainSeparator, bytes32 typeHash, bytes memory message) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, keccak256(abi.encodePacked(typeHash, message)));
    }
}
