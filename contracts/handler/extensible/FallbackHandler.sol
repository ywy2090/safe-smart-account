// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ISafe, IStaticFallbackMethod, IFallbackMethod, ExtensibleBase} from "./ExtensibleBase.sol";

/**
 * @title IFallbackHandler
 * @notice 由 Safe 通过 fallback 自调用，用于配置「selector → 编码后的 method」路由。
 * @dev newMethod 通常由 MarshalLib.encode(isStatic, handler) 或 encodeWithSelector 得到；传 bytes32(0) 可禁用该 selector。
 */
interface IFallbackHandler {
    function setSafeMethod(bytes4 selector, bytes32 newMethod) external;
}

/**
 * @title FallbackHandler
 * @notice 可扩展 Fallback 的入口：根据调用 selector 将请求转发到已配置的外部处理器（IFallbackMethod / IStaticFallbackMethod）。
 * @dev
 * - 需 Safe >= 1.3.0：FallbackManager 在无匹配函数且带 data 的调用时，将请求转发到 handler，并在 calldata 末尾追加 20 字节的原始 caller。
 * - 本合约不实现具体业务（如 ERC-1271、token 回调），只做路由：通过 setSafeMethod 为每个 selector 绑定一个外部处理器，
 *   未绑定的 selector 会 require(handler != 0) 失败。ExtensibleFallbackHandler 在继承本合约基础上再混入 ERC165、Token、签名等实现。
 * - 转发前会剥离 calldata 末尾 20 字节（Safe 追加的 sender），把「原始 selector + 参数」传给处理器，处理器通过 handle(safe, sender, ...) 的 sender 参数仍可拿到原始调用者。
 *
 * ─── fallback() 何时被触发 ───
 * 本 fallback 在「对 Handler 的调用」的 selector 与 Handler 上任何已声明函数（setSafeMethod、isValidSignature、onERC721Received 等）都不匹配时触发。
 * 而对 Handler 的调用只可能来自 Safe：外部先调 Safe，Safe 无匹配函数后由 FallbackManager 转发到 Handler。因此实际触发链为：
 *   外部 call(Safe, selector_X || args) → Safe 无 selector_X → FallbackManager.fallback() → call(Handler, selector_X || args || caller)
 *   → Handler 无 selector_X → 本 fallback()。若 selector_X 已通过 setSafeMethod 配置，则查 safeMethods 并转发到 processor；未配置则 revert。
 *
 * ─── 调用栈（自顶向下）───
 *   1. 外部 (EOA/合约)  call(Safe, data)，data[0:4]=selector_X，Safe 上无该 selector
 *   2. Safe (FallbackManager.fallback)  sload(handler), call(handler, data||caller())
 *   3. ExtensibleFallbackHandler  收到 msg.sender=Safe, msg.data=data||sender；selector_X 与 Handler 上函数均不匹配 → 本 fallback()
 *   4. FallbackHandler.fallback()  _getContextAndHandler(), safeMethods[safe][selector_X] → 若已配置则 call(processor.handle(...))
 *
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
abstract contract FallbackHandler is ExtensibleBase, IFallbackHandler {
    // --- setters ---

    /**
     * @notice 为当前 Safe 设置某 selector 对应的 fallback 处理器（仅 Safe 通过 fallback 调用有效）。
     * @param selector 要配置的 4 字节函数选择器（如 ERC1271.isValidSignature.selector）。
     * @param newMethod MarshalLib.encode(isStatic, handler) 或 encodeWithSelector 的结果；bytes32(0) 表示禁用该 selector。
     */
    function setSafeMethod(bytes4 selector, bytes32 newMethod) public override onlySelf {
        _setSafeMethod(ISafe(payable(_msgSender())), selector, newMethod);
    }

    // --- fallback ---

    /**
     * @notice Fallback 入口：根据 msg.sig 查路由，将请求转发到已配置的处理器，并剥离 calldata 末尾 20 字节后再传递。
     * @dev Safe 传入的 msg.data 格式为：originalCalldata || sender(20 bytes)。长度至少 24（4 字节 selector + 20 字节 sender）。
     *      若该 selector 未配置或 handler 为 0，会 revert "method handler not set"。
     */
    // solhint-disable-next-line
    fallback(bytes calldata) external returns (bytes memory result) {
        require(msg.data.length >= 24, "invalid method selector");
        (ISafe safe, address sender, bool isStatic, address handler) = _getContextAndHandler();
        require(handler != address(0), "method handler not set");

        bytes calldata dataWithoutSender = msg.data[:msg.data.length - 20];
        if (isStatic) {
            result = IStaticFallbackMethod(handler).handle(safe, sender, 0, dataWithoutSender);
        } else {
            result = IFallbackMethod(handler).handle(safe, sender, 0, dataWithoutSender);
        }
    }
}
