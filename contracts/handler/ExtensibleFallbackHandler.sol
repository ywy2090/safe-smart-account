// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {ERC165Handler} from "./extensible/ERC165Handler.sol";
import {IFallbackHandler, FallbackHandler} from "./extensible/FallbackHandler.sol";
import {ERC1271, ISignatureVerifierMuxer, SignatureVerifierMuxer} from "./extensible/SignatureVerifierMuxer.sol";
import {ERC721TokenReceiver, ERC1155TokenReceiver, TokenCallbacks} from "./extensible/TokenCallbacks.sol";

/**
 * @title Extensible Fallback Handler
 * @notice 为 Safe 提供的可扩展 Fallback Handler：支持 ERC-721/ERC-1155 接收回调、EIP-1271 签名验证、以及可配置的 fallback 方法路由。
 * @dev 需 Safe >= 1.3.0（fallback 时在 calldata 末尾附加 caller）。通过 _supportsInterface 声明支持的接口 ID。
 * @author mfw78 <mfw78@rndlabs.xyz>
 */
contract ExtensibleFallbackHandler is FallbackHandler, SignatureVerifierMuxer, TokenCallbacks, ERC165Handler {
    /** 声明本 handler 支持的接口：ERC721/ERC1155 接收、ERC1271、SignatureVerifierMuxer、ERC165、IFallbackHandler。 */
    function _supportsInterface(bytes4 interfaceId) internal pure override returns (bool) {
        return
            interfaceId == type(ERC721TokenReceiver).interfaceId ||
            interfaceId == type(ERC1155TokenReceiver).interfaceId ||
            interfaceId == type(ERC1271).interfaceId ||
            interfaceId == type(ISignatureVerifierMuxer).interfaceId ||
            interfaceId == type(ERC165Handler).interfaceId ||
            interfaceId == type(IFallbackHandler).interfaceId;
    }
}
