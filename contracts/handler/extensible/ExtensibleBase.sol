// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ISafe} from "../../interfaces/ISafe.sol";
import {HandlerContext} from "../HandlerContext.sol";
import {MarshalLib} from "./MarshalLib.sol";

interface IFallbackMethod {
    // 非 static fallback 方法：允许状态修改。
    function handle(ISafe safe, address sender, uint256 value, bytes calldata data) external returns (bytes memory result);
}

interface IStaticFallbackMethod {
    // static fallback 方法：只读，不允许状态修改。
    function handle(ISafe safe, address sender, uint256 value, bytes calldata data) external view returns (bytes memory result);
}

/**
 * @title Base contract for Extensible Fallback Handlers
 * @dev This contract provides the base for storage and modifiers for extensible fallback handlers
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
abstract contract ExtensibleBase is HandlerContext {
    // --- events ---
    event ChangedSafeMethod(ISafe indexed safe, bytes4 selector, bytes32 oldMethod, bytes32 newMethod);

    // --- storage ---

    // Safe 级别的方法路由表：Safe => selector => packed method。
    // packed method 的编码规则：
    // - 最高字节：0x00 表示 static(view)，0x01 表示非 static。
    // - 低 20 字节：具体处理器地址。
    // 编解码由 MarshalLib 负责。
    mapping(ISafe => mapping(bytes4 => bytes32)) public safeMethods;

    // --- modifiers ---
    modifier onlySelf() {
        // 仅允许 Safe 自身通过 fallback 上下文调用配置接口，避免外部地址直接改路由。
        require(_msgSender() == _manager(), "only safe can call this method");
        _;
    }

    // --- internal ---

    function _setSafeMethod(ISafe safe, bytes4 selector, bytes32 newMethod) internal {
        mapping(bytes4 => bytes32) storage safeMethod = safeMethods[safe];
        bytes32 oldMethod = safeMethod[selector];

        (, address newHandler) = MarshalLib.decode(newMethod);
        if (address(newHandler) == address(0)) {
            // handler == 0 视为“禁用方法”，此时忽略 isStatic 标记，统一归零存储。
            newMethod = bytes32(0);
        }

        safeMethod[selector] = newMethod;
        emit ChangedSafeMethod(safe, selector, oldMethod, newMethod);
    }

    /**
     * Dry code to get the Safe and the original `msg.sender` from the FallbackManager
     * @return safe The Safe whose FallbackManager is making this call
     * @return sender The original `msg.sender` (as received by the FallbackManager)
     */
    function _getContext() internal view returns (ISafe safe, address sender) {
        // _manager() 是触发 fallback 的 Safe；_msgSender() 是原始外部调用者。
        safe = ISafe(payable(_manager()));
        sender = _msgSender();
    }

    /**
     * Get the context and the method handler applicable to the current call
     * @return safe The Safe whose FallbackManager is making this call
     * @return sender The original `msg.sender` (as received by the FallbackManager)
     * @return isStatic Whether the method is static (`view`) or not
     * @return handler the address of the handler contract
     */
    function _getContextAndHandler() internal view returns (ISafe safe, address sender, bool isStatic, address handler) {
        (safe, sender) = _getContext();
        // msg.sig 是当前 fallback 调用的 selector，用于按 Safe+selector 查路由。
        (isStatic, handler) = MarshalLib.decode(safeMethods[safe][msg.sig]);
    }
}
