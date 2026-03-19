// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ISafe} from "../../interfaces/ISafe.sol";
import {HandlerContext} from "../HandlerContext.sol";
import {MarshalLib} from "./MarshalLib.sol";

/**
 * @title IFallbackMethod
 * @notice 可修改状态的 Fallback 方法处理器接口：由 Extensible Fallback Handler 按 selector 路由后调用。
 * @dev 实现者可在 handle 内执行任意逻辑（含对 Safe 的 execTransaction 等），适用于需要写存储或发起链上交易的场景。
 *      handle(safe, sender, value, data) 中 safe 为当前 Fallback 所属的 Safe，sender 为原始调用者，data 为剥离尾部 20 字节后的 calldata；返回 result 作为 fallback 返回值。
 */
interface IFallbackMethod {
    function handle(ISafe safe, address sender, uint256 value, bytes calldata data) external returns (bytes memory result);
}

/**
 * @title IStaticFallbackMethod
 * @notice 只读（view）Fallback 方法处理器接口：不允许状态修改，适用于查询、编码、模拟等场景。
 * @dev 与 IFallbackMethod 区分后，便于在 fallback 内根据 isStatic 选择 view 调用，避免不必要的状态变更风险。
 */
interface IStaticFallbackMethod {
    function handle(ISafe safe, address sender, uint256 value, bytes calldata data) external view returns (bytes memory result);
}

/**
 * @title ExtensibleBase
 * @notice 可扩展 Fallback Handler 的基类：提供「按 Safe + selector 路由到外部处理器」的存储与上下文读取。
 * @dev
 * - 与 CompatibilityFallbackHandler 不同，本系列 Handler 不写死接口实现，而是通过 safeMethods[Safe][selector]
 *   将未匹配的调用转发到外部合约（IFallbackMethod / IStaticFallbackMethod），从而实现可插拔扩展。
 * - 仅当调用来自 Safe 的 fallback（即 msg.sender 为 Safe、且 Safe 的 fallback handler 指向本合约）时，
 *   _manager() 为 Safe、_msgSender() 为原始调用者；配置接口通过 onlySelf 限制为「Safe 自己」调用，避免任意地址篡改路由。
 * - packed method 的编解码统一由 MarshalLib 完成，子类只需使用 _setSafeMethod / _getContextAndHandler 即可。
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
abstract contract ExtensibleBase is HandlerContext {
    // --- events ---

    /** 当某 Safe 的某 selector 对应的路由（packed method）被更新时发出。 */
    event ChangedSafeMethod(ISafe indexed safe, bytes4 selector, bytes32 oldMethod, bytes32 newMethod);

    // --- storage ---

    /**
     * Safe 级别的方法路由表：safeMethods[safe][selector] = packed(method)。
     * packed method（bytes32）编码规则（详见 MarshalLib）：
     * - 最高 1 字节：0x00 = static(view)，0x01 = 非 static。
     * - 低 20 字节：处理器合约地址。
     * 未设置的 selector 或 handler 为 0 表示「未配置」，fallback 会 require(handler != 0)。
     */
    mapping(ISafe => mapping(bytes4 => bytes32)) public safeMethods;

    // --- modifiers ---

    /** 仅允许「当前 Fallback 所属的 Safe」调用（即 Safe 通过 fallback 自调用配置接口），防止外部随意改路由。 */
    modifier onlySelf() {
        require(_msgSender() == _manager(), "only safe can call this method");
        _;
    }

    // --- internal ---

    /**
     * @notice 设置某 Safe 下某 selector 对应的路由（packed method）。
     * @dev 若 newMethod 解码后 handler 为 address(0)，则视为禁用该 selector，存储写入 bytes32(0)。
     * @param safe 目标 Safe。
     * @param selector 函数选择器（4 字节）。
     * @param newMethod MarshalLib.encode(isStatic, handler) 或 encodeWithSelector 的编码结果。
     */
    function _setSafeMethod(ISafe safe, bytes4 selector, bytes32 newMethod) internal {
        mapping(bytes4 => bytes32) storage safeMethod = safeMethods[safe];
        bytes32 oldMethod = safeMethod[selector];

        (, address newHandler) = MarshalLib.decode(newMethod);
        if (address(newHandler) == address(0)) {
            newMethod = bytes32(0);
        }

        safeMethod[selector] = newMethod;
        emit ChangedSafeMethod(safe, selector, oldMethod, newMethod);
    }

    /**
     * @notice 从 Fallback 上下文中取得当前 Safe 与原始调用者。
     * @dev 仅在通过 Safe 的 fallback 进入时有效：_manager() 为 Safe，_msgSender() 为 FallbackManager 追加的 caller。
     * @return safe 触发本次 fallback 的 Safe（即 msg.sender）。
     * @return sender 原始调用者地址（calldata 末尾 20 字节）。
     */
    function _getContext() internal view returns (ISafe safe, address sender) {
        safe = ISafe(payable(_manager()));
        sender = _msgSender();
    }

    /**
     * @notice 在 Fallback 上下文中取得 Safe、原始调用者、以及当前调用 selector 对应的处理器（是否 static、地址）。
     * @dev 用 msg.sig 作为 selector 查 safeMethods[safe]；若未配置则 handler 为 0，调用方需 require(handler != 0)。
     * @return safe 当前 Fallback 所属的 Safe。
     * @return sender 原始调用者。
     * @return isStatic 该 selector 是否配置为 view 处理器（true 则走 IStaticFallbackMethod）。
     * @return handler 处理器合约地址；为 0 表示未配置。
     */
    function _getContextAndHandler() internal view returns (ISafe safe, address sender, bool isStatic, address handler) {
        (safe, sender) = _getContext();
        (isStatic, handler) = MarshalLib.decode(safeMethods[safe][msg.sig]);
    }
}
