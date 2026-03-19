// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {IERC165} from "../../interfaces/IERC165.sol";
import {ISafe, MarshalLib, ExtensibleBase} from "./ExtensibleBase.sol";

/**
 * @title IERC165Handler
 * @notice 可扩展 Handler 的 ERC-165 与按接口批量路由的扩展点：按 Safe 声明支持的 interface，并支持批量注册/移除 selector→handler。
 * @dev safeInterfaces 记录某 Safe 是否声明支持某 interfaceId；addSupportedInterfaceBatch 会同时写入 safeMethods 路由并置 supported=true。
 */
interface IERC165Handler {
    function safeInterfaces(ISafe safe, bytes4 interfaceId) external view returns (bool);

    function setSupportedInterface(bytes4 interfaceId, bool supported) external;

    function addSupportedInterfaceBatch(bytes4 interfaceId, bytes32[] calldata handlerWithSelectors) external;

    function removeSupportedInterfaceBatch(bytes4 interfaceId, bytes4[] calldata selectors) external;
}

/**
 * @title ERC165Handler
 * @notice 为 Safe（通过本 Handler）实现 ERC-165 接口检测，并支持「按接口批量绑定 selector→handler」与运行时声明/撤销接口支持。
 * @dev
 * - supportsInterface 的判定顺序：IERC165 / IERC165Handler 固定支持 → 子类 _supportsInterface（如 ERC721/ERC1155/ERC1271）→ 运行时 safeInterfaces[safe][id]。
 * - 接口 ID 按 ERC-165 定义为该接口内所有函数 selector 的 XOR。addSupportedInterfaceBatch 时用 handlerWithSelectors 解码出的 selector 做 XOR，必须等于传入的 interfaceId，防止配置错误。
 * - 批量添加会为每个 selector 调用 _setSafeMethod，并最后 setSupportedInterface(interfaceId, true)；批量移除会清空路由并 setSupportedInterface(interfaceId, false)。
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
abstract contract ERC165Handler is ExtensibleBase, IERC165Handler {
    // --- events ---

    /** 某 Safe 新声明支持某 interfaceId 时发出（含批量注册后首次置为 true）。 */
    event AddedInterface(ISafe indexed safe, bytes4 interfaceId);
    /** 某 Safe 取消对某 interfaceId 的支持时发出。 */
    event RemovedInterface(ISafe indexed safe, bytes4 interfaceId);

    // --- storage ---

    /** 按 Safe 与 interfaceId 记录该 Safe 是否声明支持该接口（用于 supportsInterface 查询）。 */
    mapping(ISafe => mapping(bytes4 => bool)) public override safeInterfaces;

    // --- setters ---

    /**
     * @notice 设置当前 Safe 对某 interfaceId 的声明支持状态（仅 Safe 通过 fallback 调用有效）。
     * @dev 0xffffffff 为 ERC-165 保留值，必须拒绝。仅当 supported 与当前值不同时才更新存储并发事件。
     * @param interfaceId 要设置支持状态的 4 字节接口 ID。
     * @param supported true 表示支持，false 表示不支持。
     */
    function setSupportedInterface(bytes4 interfaceId, bool supported) public override onlySelf {
        ISafe safe = ISafe(payable(_manager()));
        require(interfaceId != 0xffffffff, "invalid interface id");
        mapping(bytes4 => bool) storage safeInterface = safeInterfaces[safe];
        bool current = safeInterface[interfaceId];
        if (supported != current) {
            safeInterface[interfaceId] = supported;
            if (supported) {
                emit AddedInterface(safe, interfaceId);
            } else {
                emit RemovedInterface(safe, interfaceId);
            }
        }
    }

    /**
     * @notice 批量为某接口注册 selector→handler 路由，并将该 interfaceId 标记为已支持。
     * @dev handlerWithSelectors 每项为 MarshalLib.encodeWithSelector(isStatic, selector, handler)。解码后 XOR(selectors) 必须等于 _interfaceId，否则 revert "interface id mismatch"。
     *
     * handlerWithSelectors 编码格式（每项一个 bytes32，由 MarshalLib.encodeWithSelector(isStatic, selector, handler) 得到）：
     *
     *   布局（bytes32，索引 0 为最高字节）：
     *   ┌──────────┬────────────────────┬─────────────────────────────────────────┐
     *   │ 1 byte   │ 4 bytes             │ 7 bytes 零填充 + 20 bytes handler 地址   │
     *   │ flags    │ selector           │                                         │
     *   │ [0]      │ [1..4]             │ [12..31] 低 20 字节 = handler              │
     *   └──────────┴────────────────────┴─────────────────────────────────────────┘
     *
     *   - flags：最高字节 [0]。0x00 = 只读（IStaticFallbackMethod），0x01 = 可写（IFallbackMethod）。
     *   - selector：4 字节，[1..4]（bit 247~216）。handler：低 20 字节 [12..31]；[5..11] 为 0。
     *
     * 约束：该接口下所有 selector 的 XOR 必须等于 _interfaceId（ERC-165 规定 interfaceId = XOR(接口内所有函数 selector)）。
     *
     * 前端/脚本编码可参考 test/utils/extensible.ts 的 encodeHandlerFunction(isStatic, selector, handler)。
     *
     * @param _interfaceId 要注册的接口 ID（必须等于所有 selector 的 XOR）。
     * @param handlerWithSelectors 编码后的路由条目数组，每项为 MarshalLib.encodeWithSelector(isStatic, selector, handlerAddress)。
     */
    function addSupportedInterfaceBatch(bytes4 _interfaceId, bytes32[] calldata handlerWithSelectors) external override onlySelf {
        ISafe safe = ISafe(payable(_msgSender()));
        bytes4 interfaceId = bytes4(0);
        uint256 len = handlerWithSelectors.length;
        for (uint256 i = 0; i < len; ++i) {
            (bool isStatic, bytes4 selector, address handlerAddress) = MarshalLib.decodeWithSelector(handlerWithSelectors[i]);
            _setSafeMethod(safe, selector, MarshalLib.encode(isStatic, handlerAddress));
            interfaceId ^= selector;
        }

        require(interfaceId == _interfaceId, "interface id mismatch");
        setSupportedInterface(_interfaceId, true);
    }

    /**
     * @notice 批量移除某接口下所有 selector 的路由，并取消对该 interfaceId 的支持声明。
     * @dev selectors 的 XOR 必须等于 _interfaceId，防止误删其他接口的 selector。
     * @param _interfaceId 要移除的接口 ID。
     * @param selectors 该接口下要移除的 4 字节 selector 列表。
     */
    function removeSupportedInterfaceBatch(bytes4 _interfaceId, bytes4[] calldata selectors) external override onlySelf {
        ISafe safe = ISafe(payable(_msgSender()));
        bytes4 interfaceId = bytes4(0);
        uint256 len = selectors.length;
        for (uint256 i = 0; i < len; ++i) {
            _setSafeMethod(safe, selectors[i], bytes32(0));
            interfaceId ^= selectors[i];
        }

        require(interfaceId == _interfaceId, "interface id mismatch");
        setSupportedInterface(_interfaceId, false);
    }

    /**
     * @notice 实现 ERC-165：查询当前 Fallback 所属 Safe 是否支持给定 interfaceId。
     * @dev 判定顺序：IERC165 / IERC165Handler → 子类 _supportsInterface（硬编码的 ERC721/1155/ERC1271 等）→ safeInterfaces[safe][interfaceId]（运行时配置）。
     * @param interfaceId 4 字节 ERC-165 接口 ID。
     * @return 若该 Safe 通过本 Handler 声明或继承支持该接口则返回 true，否则 false。
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC165Handler).interfaceId ||
            _supportsInterface(interfaceId) ||
            safeInterfaces[ISafe(payable(_manager()))][interfaceId];
    }

    // --- internal ---

    /**
     * @notice 子类覆盖此方法以声明额外支持的接口（如 ERC721TokenReceiver、ERC1271）。
     * @param interfaceId 待检测的接口 ID。
     * @return 若子类支持该接口返回 true，否则 false。
     */
    function _supportsInterface(bytes4 interfaceId) internal view virtual returns (bool);
}
