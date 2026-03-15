# Safe Smart Account 源码解析与机制分析

## 目录

- [1. 概述与阅读指引](#1-概述与阅读指引)
  - [1.1 项目简介](#11-项目简介)
  - [1.2 项目结构](#12-项目结构)
  - [1.3 建议阅读路径](#13-建议阅读路径)
- [2. 架构设计与核心概念](#2-架构设计与核心概念)
  - [2.1 总体架构](#21-总体架构)
  - [2.2 核心概念](#22-核心概念)
  - [2.3 Safe 与 SafeL2](#23-safe-与-safel2)
- [3. 核心生命周期](#3-核心生命周期)
  - [3.1 账户创建](#31-账户创建)
  - [3.2 主交易执行](#32-主交易执行)
- [4. 关键机制](#4-关键机制)
  - [4.1 交易哈希与 EIP-712](#41-交易哈希与-eip-712)
  - [4.2 签名验证系统](#42-签名验证系统)
  - [4.3 Gas 估算与退款](#43-gas-估算与退款)
  - [4.4 Fallback 体系](#44-fallback-体系)
- [5. 扩展系统：Module 与 Guard](#5-扩展系统module-与-guard)
  - [5.1 模块执行](#51-模块执行)
  - [5.2 Guard 机制](#52-guard-机制)
  - [5.3 权限风险矩阵](#53-权限风险矩阵)
- [6. 存储布局](#6-存储布局)
  - [6.1 关键 slot 分布](#61-关键-slot-分布)
  - [6.2 链表管理](#62-链表管理)
- [7. 开发者参考](#7-开发者参考)
  - [7.1 常见错误码索引](#71-常见错误码索引)
  - [7.2 核心函数索引](#72-核心函数索引)
  - [7.3 相关工具库](#73-相关工具库)
- [源码引用](#源码引用)

---

## 1. 概述与阅读指引

### 1.1 项目简介

**Safe Smart Account**（原 Gnosis Safe）是一套非托管的智能合约协议，用于创建可编程的多签账户。交易需经多个所有者（owners）授权才能执行，相比普通 EOA 提供更高安全性与资金保护。当前仓库版本为 **v1.5.0**，合约采用 Solidity 0.7.6，构建系统为 Hardhat。

本报告围绕三个问题展开：Safe 的账户模型是怎样组织的，多签与模块调用是如何落到链上执行的，以及 fallback、Guard、签名验证等扩展机制如何与主流程配合。

### 1.2 项目结构

#### 目录与模块

| 目录/文件 | 职责 |
|-----------|------|
| `contracts/Safe.sol` | 主实现：多签核心逻辑（L1 版，基础事件更少，不发完整交易参数事件） |
| `contracts/SafeL2.sol` | L2 版 Safe，继承 Safe 并增加交易/模块执行事件 |
| `contracts/base/` | 基础能力：OwnerManager、ModuleManager、GuardManager、FallbackManager、Executor |
| `contracts/common/` | 通用组件：Singleton、SelfAuthorized、签名解码、EIP 扩展等 |
| `contracts/proxies/` | SafeProxy（委托调用实现）、SafeProxyFactory（CREATE2 工厂） |
| `contracts/handler/` | Fallback 处理器（Compatibility / Extensible）及 HandlerContext |
| `contracts/libraries/` | MultiSend、CreateCall、SignMessageLib、SafeMigration、SafeStorage 等 |
| `contracts/interfaces/` | ISafe、IModuleManager、IGuardManager、Enum 等接口定义 |
| `contracts/accessors/` | SimulateTxAccessor（模拟执行） |
| `src/` | TypeScript 部署脚本与工具（deploy_*、utils） |
| `test/` | Hardhat 测试；`certora/` 为形式化验证配置与规格 |
| `docs/TeachingSafe-教学版说明.md` | 教学说明文档，用于辅助理解 Safe 核心机制 |

#### 技术栈

- **语言**: Solidity ≥0.7.0 <0.9.0（主合约固定 0.7.6 以保证字节码稳定与部署确定性）
- **构建**: Hardhat 2.x，solc 0.7.6
- **脚本**: TypeScript（部署、任务、工具函数）
- **验证**: Certora 规格与配置

### 1.3 建议阅读路径

如果是第一次阅读这个仓库，建议按“先主线、后扩展、再辅助组件”的顺序看：

1. `contracts/proxies/SafeProxy.sol`、`contracts/proxies/SafeProxyFactory.sol`
   先理解 proxy 模式、`CREATE2` 地址生成，以及为什么 `initializer` 会参与地址计算。
2. `contracts/Safe.sol`
   抓住两条主线：`setup()` 初始化与 `execTransaction()` 多签执行。
3. `contracts/base/OwnerManager.sol`、`contracts/base/ModuleManager.sol`、`contracts/base/GuardManager.sol`、`contracts/base/FallbackManager.sol`
   这四个 base 合约分别对应 owner、module、guard、fallback 四个核心扩展面。
4. `contracts/handler/CompatibilityFallbackHandler.sol` 与 `contracts/handler/ExtensibleFallbackHandler.sol`
   对比旧兼容处理器与新 extensible 处理器的职责差异。
5. `contracts/handler/extensible/`
   这一层再深入读 `ExtensibleBase`、`FallbackHandler`、`SignatureVerifierMuxer`、`ERC165Handler`、`MarshalLib`，理解可扩展 fallback 处理器的内部路由机制。
6. `contracts/libraries/` 与 `contracts/accessors/`
   最后再看 `MultiSend`、`MultiSendCallOnly`、`SafeToL2Setup`、`SignMessageLib`、`SimulateTxAccessor` 等辅助组件，理解生态使用方式。

---

## 2. 架构设计与核心概念

### 2.1 总体架构

下图从分层与合约职责角度概括 Safe Smart Account 的整体结构。自上而下分别是入口层、代理层、核心实现层、基础能力层与扩展层；实线表示调用或委托关系，虚线表示按需挂载的扩展关系。

```mermaid
flowchart TB
    subgraph 入口层
        User[用户 / 中继 / 前端]
        Factory[SafeProxyFactory]
    end

    subgraph 代理层
        Proxy[SafeProxy<br/>仅存 singleton]
    end

    subgraph 核心实现层
        Safe[Safe / SafeL2<br/>多签与执行入口]
    end

    subgraph 基础能力层
        OM[OwnerManager<br/>owners / threshold]
        MM[ModuleManager<br/>modules / execFromModule]
        GM[GuardManager<br/>transaction guard]
        FM[FallbackManager<br/>fallback 转发]
        Exec[Executor<br/>call / delegatecall]
    end

    subgraph 扩展层
        Handler[FallbackHandler<br/>ERC1271 / 回调]
        TGuard[TransactionGuard<br/>前后检查]
        MGuard[ModuleGuard<br/>模块交易检查]
        Module[Module<br/>任意逻辑扩展]
    end

    User -->|创建并初始化| Factory
    Factory -->|CREATE2 部署| Proxy
    User -->|调用 Safe 方法| Proxy
    Proxy -->|delegatecall 全部调用| Safe

    Safe --> OM
    Safe --> MM
    Safe --> GM
    Safe --> FM
    Safe --> Exec

    FM -.->|未匹配时 call| Handler
    GM -.->|若已设置| TGuard
    MM -.->|若已设置| MGuard
    Module -->|调用 execTransactionFromModule| MM
```

**图 1：分层架构**：入口层负责创建和发起调用；代理层负责转发；核心实现层负责多签与执行；基础能力层提供 owner、module、Guard、fallback 处理与执行能力；扩展层提供可选的处理器、Guard 与模块。注意 Module 箭头方向：是模块主动调用 `ModuleManager`，而不是 `ModuleManager` 调用模块。

### 2.2 核心概念

#### Proxy-Singleton 模式

Safe 采用的是一种**自定义的 singleton delegatecall proxy**：`SafeProxy` 持有状态与余额，`Safe` / `SafeL2` 作为实现合约提供逻辑，二者通过 `delegatecall` 结合。它和常见升级框架里的 Transparent Proxy 并不完全相同，但目标一致，都是把状态与逻辑分开。

```mermaid
sequenceDiagram
    participant User
    participant SafeProxy
    participant Safe

    User->>SafeProxy: 任意调用 (calldata)
    SafeProxy->>SafeProxy: sload(singleton)
    SafeProxy->>Safe: delegatecall(singleton, calldata)
    Safe->>Safe: 使用 Proxy 的 storage/msg.value
    Safe-->>SafeProxy: return data
    SafeProxy-->>User: return/revert
```

- **SafeProxy**：仅保存 `singleton`（实现地址），所有调用都通过 `delegatecall` 转发到实现合约。
- **实现合约**：`Safe` / `SafeL2` 中第一个状态变量同样是 `singleton`，与 Proxy 的 storage slot 0 对齐，目的是保证 `delegatecall` 时的存储布局一致。
- **初始化保护**：实现合约自身不会被当作钱包使用。原因是 `Safe` 构造函数先把 `threshold` 设为 `1`，因此如果有人直接对实现合约调用 `setup()`，`setupOwners()` 会因“已初始化”而回滚。

#### 核心继承与组合（UML 类图）

Safe 通过多重继承组合 owner、module、guard、fallback 等能力。下图展示核心类之间的关系：

```mermaid
classDiagram
    class SafeProxyFactory {
        +createProxyWithNonce(_singleton, initializer, saltNonce)
        +createProxyWithNonceL2(_singleton, initializer, saltNonce)
        +createChainSpecificProxyWithNonce(_singleton, initializer, saltNonce)
        +createChainSpecificProxyWithNonceL2(_singleton, initializer, saltNonce)
    }

    class SafeProxy {
        -singleton : address
        +fallback()
    }

    class Safe {
        +setup(_owners, _threshold, to, data, fallbackHandler, paymentToken, payment, paymentReceiver)
        +execTransaction(to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, signatures)
        +checkSignatures(executor, dataHash, signatures)
        +checkNSignatures(executor, dataHash, signatures, requiredSignatures)
        +approveHash(hashToApprove)
        +getTransactionHash(...)
        +domainSeparator()
    }

    class SafeL2 {
        +onBeforeExecTransaction(...)
        +onBeforeExecTransactionFromModule(...)
    }

    class Singleton
    class OwnerManager {
        +addOwnerWithThreshold(owner, threshold)
        +removeOwner(prevOwner, owner, threshold)
        +swapOwner(prevOwner, oldOwner, newOwner)
        +changeThreshold(threshold)
    }
    class ModuleManager {
        +enableModule(module)
        +disableModule(prevModule, module)
        +execTransactionFromModule(to, value, data, operation)
        +execTransactionFromModuleReturnData(to, value, data, operation)
        +setModuleGuard(moduleGuard)
    }
    class GuardManager {
        +setGuard(guard)
    }
    class FallbackManager {
        +setFallbackHandler(handler)
        +fallback()
    }
    class Executor {
        #execute(to, value, data, operation, txGas)
    }
    class StorageAccessible {
        +getStorageAt(offset, length)
        +simulateAndRevert(targetContract, calldataPayload)
    }
    class EIP7702
    class EIP7951

    class CompatibilityFallbackHandler {
        +isValidSignature(_dataHash, _signature)
        +simulate(targetContract, calldataPayload)
        +encodeTransactionData(...)
    }

    class ExtensibleFallbackHandler
    class FallbackHandler {
        +setSafeMethod(selector, newMethod)
        +fallback(data)
    }
    class ExtensibleBase {
        +safeMethods : mapping
    }
    class SignatureVerifierMuxer {
        +setDomainVerifier(domainSeparator, verifier)
        +isValidSignature(_hash, signature)
    }
    class ERC165Handler {
        +setSupportedInterface(interfaceId, supported)
        +addSupportedInterfaceBatch(interfaceId, handlerWithSelectors)
        +removeSupportedInterfaceBatch(interfaceId, selectors)
    }
    class TokenCallbacks

    Singleton <|-- Safe
    OwnerManager <|-- Safe
    ModuleManager <|-- Safe
    GuardManager <|-- Safe
    FallbackManager <|-- Safe
    StorageAccessible <|-- Safe
    EIP7951 <|-- Safe
    EIP7702 <|-- OwnerManager
    Executor <|-- ModuleManager
    Safe <|-- SafeL2

    FallbackHandler <|-- ExtensibleFallbackHandler
    SignatureVerifierMuxer <|-- ExtensibleFallbackHandler
    TokenCallbacks <|-- ExtensibleFallbackHandler
    ERC165Handler <|-- ExtensibleFallbackHandler
    ExtensibleBase <|-- FallbackHandler
    ExtensibleBase <|-- SignatureVerifierMuxer
    ExtensibleBase <|-- ERC165Handler
    ExtensibleBase <|-- TokenCallbacks

    SafeProxyFactory --> SafeProxy : deploys
    SafeProxy ..> Safe : delegatecall to singleton
    Safe --> CompatibilityFallbackHandler : can set as fallback handler
    Safe --> ExtensibleFallbackHandler : can set as fallback handler
    FallbackManager --> CompatibilityFallbackHandler : forwards unknown calls
    FallbackManager --> ExtensibleFallbackHandler : forwards unknown calls
```

### 2.3 Safe 与 SafeL2

| 项目 | Safe (L1) | SafeL2 |
|------|-----------|--------|
| **事件** | 仅必要事件（如 ExecutionSuccess/Failure），不包含完整交易参数 | 在 `onBeforeExecTransaction` 中 emit **SafeMultiSigTransaction**（含完整交易参数与 additionalInfo：nonce, msg.sender, threshold） |
| **模块执行** | 无额外事件 | 在 `onBeforeExecTransactionFromModule` 中 emit **SafeModuleTransaction** |
| **使用场景** | 省 Gas，依赖链上 tracing 索引 | L2 或需要链上事件索引的场景 |

逻辑与存储完全一致，SafeL2 仅增加上述事件发射。

---

## 3. 核心生命周期

### 3.1 账户创建

#### 工厂部署与原子化初始化

`SafeProxyFactory.createProxyWithNonce(_singleton, initializer, saltNonce)` 的关键点不只在于 `CREATE2`，还在于“地址如何与初始化参数绑定”以及“为什么可以把创建和初始化放进同一笔交易”：

- 工厂先计算 `salt = keccak256(keccak256(initializer), saltNonce)`；因此 **initializer 变化会导致 proxy 地址变化**。
- `deployProxy` 使用 `type(SafeProxy).creationCode + singleton` 作为部署字节码，通过 `create2` 生成新 proxy。
- 若 `initializer.length > 0`，工厂会立即对新 proxy 执行一次 `call(initializer)`；在大多数场景下，这个 `initializer` 就是 `Safe.setup(...)` 的 calldata。
- 若初始化调用失败，工厂会把 revert data 原样向上抛出。因此整个“创建 + 初始化”是原子操作，不会留下“已经部署但尚未正确 setup”的半成品。

```mermaid
sequenceDiagram
    participant User
    participant Factory as SafeProxyFactory
    participant Proxy as SafeProxy
    participant Safe as Safe(singleton)

    User->>Factory: createProxyWithNonce(singleton, initializer, saltNonce)
    Factory->>Factory: salt = keccak256(keccak256(initializer), saltNonce)
    Factory->>Factory: create2(proxyCreationCode + singleton, salt)
    Factory-->>Proxy: 部署新 SafeProxy
    alt initializer 非空
        Factory->>Proxy: call(initializer)
        Proxy->>Safe: delegatecall(setup(...))
        Safe->>Safe: emit SafeSetup（先发事件，确保链下索引顺序正确）
        Safe->>Safe: setupOwners / setFallback / setupModules / handlePayment
        Safe-->>Proxy: return
        Proxy-->>Factory: return
    else initializer 为空
        Note over Proxy: 产生未初始化 proxy，存在被抢先 setup 风险
    end
    Factory-->>User: 返回 proxy 地址并 emit ProxyCreation
```

### 3.2 主交易执行

#### `execTransaction` 完整流程

```mermaid
sequenceDiagram
    participant Caller
    participant Proxy as SafeProxy
    participant Safe as Safe(singleton)
    participant Guard
    participant Target

    Caller->>Proxy: execTransaction(to, value, data, operation, ...)
    Proxy->>Safe: delegatecall（使用 Proxy 的 storage 与上下文）
    Safe->>Safe: onBeforeExecTransaction(...)
    Safe->>Safe: getTransactionHash(..., nonce++)
    Safe->>Safe: checkSignatures(executor, txHash, signatures)
    Safe->>Safe: getGuard()
    alt guard != 0
        Safe->>Guard: checkTransaction(...)
    end
    Safe->>Safe: 检查 gasleft >= f(safeTxGas)
    Safe->>Target: execute → call/delegatecall
    Target-->>Safe: success/fail
    Safe->>Safe: handlePayment(...) 若 gasPrice > 0
    Safe->>Safe: emit ExecutionSuccess / ExecutionFailure
    alt guard != 0
        Safe->>Guard: checkAfterExecution(txHash, success)
    end
    Safe-->>Proxy: return success
    Proxy-->>Caller: return success
```

#### 状态流转与回滚机制

下图把 Safe 交易最容易混淆的几类结果拆开：前置检查失败、内部目标调用失败、`estimateGas` 特殊回滚路径、退款阶段失败，以及后置 Guard 否决。

```mermaid
stateDiagram-v2
    [*] --> Precheck: 进入 execTransaction
    Precheck --> Reverted: 签名校验 / gas 检查 / guard 前置检查失败
    Precheck --> Executing: 前置检查通过
    Executing --> TargetSuccess: execute(...) 返回 success=true
    Executing --> TargetFailure: execute(...) 返回 success=false
    TargetFailure --> Reverted: estimateGas 模式\nsafeTxGas=0 && gasPrice=0
    TargetSuccess --> Paying: gasPrice > 0
    TargetSuccess --> Emitting: gasPrice == 0\n跳过退款
    TargetFailure --> Paying: gasPrice > 0\n且非 estimateGas 模式
    TargetFailure --> Emitting: gasPrice == 0\n且非 estimateGas 模式
    Paying --> Reverted: handlePayment 失败（GS011/GS012）
    Paying --> Emitting: emit ExecutionSuccess / ExecutionFailure
    Emitting --> PostGuard: 进入 checkAfterExecution
    PostGuard --> Reverted: checkAfterExecution revert
    PostGuard --> ReturnedTrue: success=true
    PostGuard --> ReturnedFalse: success=false
    ReturnedTrue --> [*]
    ReturnedFalse --> [*]
    Reverted --> [*]
```

- **签名或前置检查失败**：`revert`，无副作用。
- **estimateGas 特殊模式**：当 `safeTxGas == 0 && gasPrice == 0` 且内部目标调用失败时，Safe 会直接冒泡目标的 revert data，便于链下工具估算最小可执行 gas。
- **内部目标调用失败**：`ReturnedFalse` 表示 Safe 外层调用**成功返回**，但内部目标调用失败。只要不处于 `estimateGas` 模式，且后续逻辑（退款/Guard）未回滚，交易仍可成功上链。
- **退款不是必经阶段**：只有 `gasPrice > 0` 才会进入 `handlePayment`；`gasPrice == 0` 时会跳过退款直接进入事件与后置 Guard。
- **后置 Guard 失败**：`checkAfterExecution` 回滚会连同此前的内部调用效果、退款、事件一起撤销，拥有“最终否决权”。

#### 多签路径 vs 模块路径对照

Safe 中最容易混淆的两条执行路径是 `execTransaction` 与 `execTransactionFromModule`。二者都会落到 `Executor.execute`，但进入执行前的鉴权方式完全不同：

```mermaid
flowchart LR
    subgraph A[多签路径 `execTransaction`]
        A1[外部调用者 / 中继] --> A2[SafeProxy]
        A2 --> A3[Safe.execTransaction]
        A3 --> A4[计算 txHash + nonce++]
        A4 --> A5[checkSignatures]
        A5 --> A6[Transaction Guard]
        A6 --> A7[execute]
        A7 --> A8[handlePayment]
    end

    subgraph B[模块路径 `execTransactionFromModule`]
        B1[已启用模块] --> B2[SafeProxy]
        B2 --> B3[Safe.execTransactionFromModule]
        B3 --> B4[模块白名单检查]
        B4 --> B5[Module Guard]
        B5 --> B6[execute]
    end
```

| 维度 | 多签路径 | 模块路径 |
|------|----------|----------|
| 入口 | `execTransaction(...)` | `execTransactionFromModule(...)` |
| 调用者身份 | 任意外部调用者均可提交，但必须附带有效签名 | 仅已启用模块可直接调用 |
| 鉴权依据 | `checkSignatures` / `checkNSignatures` | `modules[msg.sender] != address(0)` 且不是哨兵地址 |
| nonce | 使用，且在计算哈希后自增 | 不使用 |
| Guard | `Transaction Guard` | `Module Guard` |
| 退款 | 支持 `handlePayment` | 不走退款逻辑 |
| 风险特征 | 依赖 owner 签名与阈值控制 | 依赖模块本身的代码质量与访问控制 |

---

## 4. 关键机制

### 4.1 交易哈希与 EIP-712

在进入签名分流之前，先要明确 owner 到底签的是什么。`execTransaction` 并不是直接对原始 calldata 做签名，而是先构造一个 EIP-712 交易哈希：

```text
txHash =
  keccak256(
    0x19 0x01
    || domainSeparator()
    || keccak256(
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
       )
  )
```

其中有两个关键层次：

- **Domain Separator**：`EIP712Domain(uint256 chainId, address verifyingContract)`，把签名绑定到当前链和当前 Safe 地址，防止跨链或跨 Safe 重放。
- **SafeTx 结构体哈希**：把一笔 Safe 交易的全部关键参数编码后再哈希，其中 `bytes data` 不直接参与编码，而是先做 `keccak256(data)`。

可以把这套结构理解为：

```mermaid
flowchart TD
    A[交易参数 to/value/data/operation/.../nonce] --> B[SafeTx structHash]
    C[chainId + Safe 地址] --> D[domainSeparator]
    B --> E[EIP-712 digest]
    D --> E
    E --> F[owner 实际签名的 txHash]
```

这也是为什么 Safe 的签名校验天然具备三层约束：
- 交易参数不能被修改，否则 `SafeTx structHash` 改变；
- 不能跨链复用，否则 `chainId` 改变；
- 不能在另一个 Safe 上复用，否则 `verifyingContract` 改变。

### 4.2 签名验证系统

`checkNSignatures` 是 Safe 多签验证的核心枢纽。它逐条读取 `signatures` 中的 65 字节静态头部，并按 `v` 值决定后续验证路径：

```mermaid
flowchart TD
    A[读取一条签名的 v r s] --> B{v 值}
    B -->|0| C[合约签名 EIP-1271]
    B -->|1| D[approved hash]
    B -->|2| E[P-256 / secp256r1]
    B -->|27/28| F[标准 ECDSA]
    B -->|>30| G[eth_sign / personal_sign]

    C --> C1[r 中取 owner 地址]
    C1 --> C2[s 作为动态偏移]
    C2 --> C3[调用 owner.isValidSignature]

    D --> D1[r 中取 owner 地址]
    D1 --> D2{executor == owner 或<br/>approvedHashes[owner][hash] != 0}

    E --> E1[r 中取声明 owner]
    E1 --> E2[s 指向动态区<br/>读取 sig_r sig_s qx qy]
    E2 --> E3[由 qx qy 派生地址]
    E3 --> E4[p256Verify]

    F --> F1[ecrecover(dataHash)]
    G --> G1[ecrecover(EIP-191 前缀哈希)]

    C3 --> H[owner 合法性与严格升序检查]
    D2 --> H
    E4 --> H
    F1 --> H
    G1 --> H
    H --> I[继续下一条签名]
```

- **EIP-7951 / RIP-7212（P-256）**：Safe 在 `v = 2` 的签名分支中调用 `address(0x100)` 预编译验证 secp256r1（P-256）签名。
- **EIP-7702**：`OwnerManager` 继承 `EIP7702`，用于检测当前执行是否处于 delegated account 上下文。

### 4.3 Gas 估算与退款

Safe 实现了 Relayer 场景下的 Gas 补偿逻辑：

- **计算**：`payment = (gasUsed + baseGas) * min(gasPrice, tx.gasprice)`（原生币）或 `(gasUsed + baseGas) * gasPrice`（ERC20）。
- **支付**：通过 `handlePayment` 将款项转给 `refundReceiver`（0 则 tx.origin）。
- **条件**：只有 `gasPrice > 0` 时才会进入退款逻辑；`gasPrice == 0` 时跳过 `handlePayment`。
- **保证**：若内部目标调用失败但外层 Safe 交易未 revert，且 `gasPrice > 0`，退款仍会发生；若整笔 `execTransaction` 最终 revert，则退款也会回滚。
- **特殊模式**：当 `safeTxGas == 0 && gasPrice == 0` 时，Safe 进入 `estimateGas` 友好的特殊路径；若目标调用失败，会直接冒泡 revert data，而不是继续执行后续事件与 Guard 流程。

**模拟执行 (Simulation)**：
- `StorageAccessible.simulateAndRevert(target, calldata)` 通过 `delegatecall` 在 Safe 的 storage 上下文中执行**任意目标逻辑**，但不会正常返回，而是把 `success + returndata` 编码进 revert 数据再回滚。
- `SimulateTxAccessor` 是专门给 `simulateAndRevert` 搭配使用的辅助合约：它内部复用 `Executor.execute` 执行一次 `(to, value, data, operation)`，常被前端、SDK 或调试工具用来预演一次 Safe 风格的调用结果，而不只是服务于 `execTransaction` 单一路径。

### 4.4 Fallback 体系

未匹配到函数时进入 `FallbackManager.fallback()`，从 `FALLBACK_HANDLER_STORAGE_SLOT` 读取处理器地址，将 **calldata + msg.sender（20 字节）** 拼在一起再 `call(handler)`。注意：此 `call` 的 **value 为 0**，即随 fallback 发送给 Safe 的 ETH 不会被转发到处理器。

#### 两类处理器的区别

当前仓库里主要有两类 fallback 处理器：一类用于兼容旧接口，另一类用于按 Safe 维度做可扩展路由：

| 维度 | `CompatibilityFallbackHandler` | `ExtensibleFallbackHandler` |
|------|-------------------------------|-----------------------------|
| 设计目标 | 兼容 pre-1.3.0 与 1.3.0+ Safe 的常见接口 | 提供可配置、按 selector 路由的扩展式处理器 |
| ERC-1271 | 支持，走默认 Safe message 校验路径 | 支持，且可通过 `SignatureVerifierMuxer` 做 domain 级分流 |
| Token 回调 | 支持 ERC-721 / ERC-1155 / ERC-777 | 支持 ERC-721 / ERC-1155，不含 ERC-777 |
| 模拟执行 | 内置 `simulate(targetContract, calldataPayload)` | 不内置该兼容接口 |
| 交易哈希辅助 | 提供 `encodeTransactionData(...)` | 不提供该兼容接口 |
| 路由能力 | 固定接口集合 | 支持 `setSafeMethod(selector, newMethod)` 做 Safe 级别路由 |
| ERC-165 | 仅基础 token callback 接口 | 通过 `ERC165Handler` 支持标准接口声明与批量注册 |
| 典型适用场景 | 老生态兼容、通用钱包工具支持 | 高度定制的 Safe 扩展、模块化 fallback 体系 |

#### Extensible Fallback Handler 机制

`ExtensibleFallbackHandler` 由多个组件组合而成，核心作用是按 selector 和 Safe 维度做路由：

- `FallbackHandler`：提供通用 fallback 入口；按 `msg.sig` 查找当前 Safe 对应的方法处理器。
- `ExtensibleBase`：维护 `safeMethods[safe][selector]` 路由表，并通过 `HandlerContext` 恢复原始调用者。
- `MarshalLib`：编解码处理器元数据（isStatic + address）。
- `SignatureVerifierMuxer`：为不同 `domainSeparator` 绑定不同 verifier。
- `ERC165Handler`：支持 ERC-165 接口声明与批量注册。

```mermaid
graph TD
    Safe[Safe / FallbackManager]
    EFH[ExtensibleFallbackHandler]

    subgraph 组合组件
        FB[FallbackHandler<br/>selector 路由入口]
        EB[ExtensibleBase<br/>safeMethods / 上下文恢复]
        ML[MarshalLib<br/>bytes32 编解码]
        SVM[SignatureVerifierMuxer<br/>domain verifier 分流]
        E165[ERC165Handler<br/>接口声明与批量注册]
        TC[TokenCallbacks<br/>ERC721 / ERC1155 回调]
    end

    Safe -->|fallback 转发| EFH
    EFH --> FB
    FB --> EB
    EB --> ML
    EFH --> SVM
    EFH --> E165
    EFH --> TC
    E165 -->|批量导入 selector| ML
```

---

## 5. 扩展系统：Module 与 Guard

### 5.1 模块执行

模块执行路径与 owner 多签路径不同。它不经过 `checkSignatures` 与 nonce，而是直接检查当前调用者是否已经出现在模块链表中：

```mermaid
sequenceDiagram
    participant Module
    participant Proxy as SafeProxy
    participant Safe as Safe(singleton)
    participant MGuard as ModuleGuard
    participant Target

    Module->>Proxy: execTransactionFromModule(to, value, data, operation)
    Proxy->>Safe: delegatecall（msg.sender 仍为 Module）
    Safe->>Safe: onBeforeExecTransactionFromModule(...)
    Safe->>Safe: getModuleGuard()
    Safe->>Safe: 校验 modules[msg.sender] != 0\n且 msg.sender != SENTINEL_MODULES
    alt moduleGuard != 0
        Safe->>MGuard: checkModuleTransaction(...)
    end
    Safe->>Target: execute → call/delegatecall
    Target-->>Safe: success/fail
    alt moduleGuard != 0
        Safe->>MGuard: checkAfterModuleExecution(guardHash, success)
    end
    Safe->>Safe: emit ExecutionFromModuleSuccess / Failure
    Safe-->>Proxy: return success
    Proxy-->>Module: return success
```

- 仅允许已启用模块调用：`msg.sender != SENTINEL_MODULES && modules[msg.sender] != address(0)`（排除哨兵地址 0x1）。
- 使用 `Executor.execute`，gas 传 `type(uint256).max`，不限制 Safe 侧 gas。
- 模块不走多签校验，也不检查 nonce；它是一条预先授权的执行通道。
- `execTransactionFromModuleReturnData` 与上图主流程相同，只是在 `execute` 之后额外拷贝 `returndata` 并返回。

### 5.2 Guard 机制

- **Transaction Guard**：作用于 `execTransaction`，拥有前置检查（`checkTransaction`）和后置检查（`checkAfterExecution`）能力。
- **Module Guard**：作用于 `execTransactionFromModule`，拥有类似的 `checkModuleTransaction` 和 `checkAfterModuleExecution` 能力。

### 5.3 权限风险矩阵

| 组件 | 挂载方式 | 触发时机 | 能否主动发起调用 | 能否阻止交易 | 对 Safe 存储/权限面的影响 | 主要风险 |
|------|----------|----------|------------------|--------------|---------------------------|----------|
| `Module` | `enableModule()` | 模块自行调用 `execTransactionFromModule` | **可以**。可让 Safe 执行任意 `CALL/DELEGATECALL` | 间接可以。模块本身可选择不发起 | **最高**。本质上获得接近 Safe 自身的执行权限 | 恶意模块可转走资产、改配置、执行任意 delegatecall |
| `Transaction Guard` | `setGuard()` | 每次 `execTransaction()` 前后 | 不可以 | **可以**。前置或后置检查均可回滚整笔交易 | 对 Safe 主流程有强约束力 | 守卫逻辑写错会造成永久 DoS；后置回滚撤销所有执行结果 |
| `Module Guard` | `setModuleGuard()` | 每次 `execTransactionFromModule` 前后 | 不可以 | **可以**。阻止模块交易 | 仅约束模块路径 | 若规则失当，可能让模块路径失效 |
| `Fallback Handler` | `setFallbackHandler()` | Safe 未匹配函数选择器时 | 不可以 | 不属于“审批交易”的阻止器 | 取决于 handler 设计 | 错误 handler 可能暴露额外入口或误解析拼接 calldata |

---

## 6. 存储布局

### 6.1 关键 slot 分布

Safe 采用固定的存储布局，以支持 Proxy 模式、工具库复用以及版本迁移场景中的兼容性。

| 用途 | 存储位置 / 常量 | 说明 |
|------|------------------|------|
| 实现地址 | slot 0 (`singleton`) | Proxy 与 Singleton 共用，必须为首个变量 |
| 模块链表 | `modules` mapping | SENTINEL_MODULES = 0x1，modules[module] = next |
| 所有者链表 | `owners` mapping | SENTINEL_OWNERS = 0x1，owners[owner] = next |
| 所有者数量 | `ownerCount` | |
| 阈值 | `threshold` | 所需签名数 |
| 交易 nonce | `nonce` | 每次 execTransaction 用后自增 |
| 弃用 domain separator | `_deprecatedDomainSeparator` | 保留以兼容布局 |
| 已签消息 | `signedMessages` mapping | 消息哈希 → 1 表示已全签 |
| 已批准哈希 | `approvedHashes[owner][hash]` | 用于 v=1 签名 |
| Fallback Handler | `FALLBACK_HANDLER_STORAGE_SLOT` | keccak256("fallback_manager.handler.address") |
| Transaction Guard | `GUARD_STORAGE_SLOT` | keccak256("guard_manager.guard.address") |
| Module Guard | `MODULE_GUARD_STORAGE_SLOT` | keccak256("module_manager.module_guard.address") |

### 6.2 链表管理

所有者和模块列表均使用 **单向链表 + Mapping** 实现：
- `owners[SENTINEL_OWNERS]` 指向第一个 owner。
- `owners[owner]` 指向下一个 owner。
- `owners[last_owner]` 指回 `SENTINEL_OWNERS`。
- 增删改均为 O(1)，且支持 `prev + current` 校验防止并发修改冲突。

---

## 7. 开发者参考

### 7.1 常见错误码索引

| 错误码 | 典型触发位置 | 含义 |
|--------|--------------|------|
| `GS000` | `ModuleManager.setupModules` | setup 阶段对初始化模块的 `delegatecall` 执行失败 |
| `GS001` | `Safe.checkSignatures` | Safe 尚未初始化，`threshold == 0` |
| `GS002` | `ModuleManager.setupModules` | setup 传入的 `to` 不是合约地址 |
| `GS010` | `Safe.execTransaction` | 剩余 gas 不足 |
| `GS011` | `Safe.handlePayment` | 原生币退款失败 |
| `GS012` | `Safe.handlePayment` | ERC20 退款失败 |
| `GS020` | `Safe.checkNSignatures` | 签名总长度不足 |
| `GS021` | `Safe.checkNSignatures` | 动态签名偏移指向静态区 |
| `GS022` | `Safe.checkContractSignature` | 合约签名偏移读取越界 |
| `GS023` | `Safe.checkContractSignature` | 合约签名动态数据越界 |
| `GS024` | `Safe.checkContractSignature` | EIP-1271 验证失败 |
| `GS025` | `Safe.checkNSignatures` | v=1 签名未批准且 executor 非 owner |
| `GS026` | `Safe.checkNSignatures` | owner 非法、重复或未排序 |
| `GS027` | `Safe.checkNSignatures` | P-256 动态签名数据越界 |
| `GS028` | `Safe.checkNSignatures` | P-256 验签失败 |
| `GS030` | `Safe.approveHash` | 非 owner 调用 `approveHash` |
| `GS031` | `SelfAuthorized.authorized` | 非自调用 |
| `GS100` | `ModuleManager.setupModules` | 模块链表重复初始化 |
| `GS101` | `ModuleManager.enable/disableModule` | 模块地址为 `0` 或哨兵地址 |
| `GS102` | `ModuleManager.enableModule` | 模块重复添加 |
| `GS103` | `ModuleManager.disableModule` | `prevModule` 与 `module` 链表关系不匹配 |
| `GS104` | `ModuleManager.preModuleExecution` | 调用者不是已启用模块 |
| `GS105` | `ModuleManager.getModulesPaginated` | 分页起点非法 |
| `GS106` | `ModuleManager.getModulesPaginated` | `pageSize == 0` |
| `GS200` | `OwnerManager.setupOwners` | owner/threshold 已初始化，重复 setup |
| `GS201` | `OwnerManager.setupOwners/changeThreshold/removeOwner` | threshold 大于 owner 数量 |
| `GS202` | `OwnerManager.setupOwners/changeThreshold` | threshold 不能为 0 |
| `GS203` | `OwnerManager.requireIsValidOwner`（由 `requireCanAddOwner` / `requireCanRemoveOwner` 调用） | owner 地址非法（如 0、哨兵、非允许场景下的 self） |
| `GS204` | `OwnerManager.setupOwners/requireCanAddOwner` | owner 重复 |
| `GS205` | `OwnerManager.requireCanRemoveOwner`（由 `removeOwner` / `swapOwner` 调用） | `prevOwner` 与待删 owner 链表关系不匹配 |
| `GS300` | `GuardManager.setGuard` | guard 不支持 `ITransactionGuard` 接口 |
| `GS301` | `ModuleManager.setModuleGuard` | module guard 不支持 `IModuleGuard` 接口 |
| `GS400` | `FallbackManager.internalSetFallbackHandler` | fallback 处理器被设置为 Safe 自身 |

### 7.2 核心函数索引

| 函数 / 入口 | 所在文件 | 作用 |
|------------|----------|------|
| `setup(...)` | `contracts/Safe.sol` | Safe 一次性初始化入口 |
| `execTransaction(...)` | `contracts/Safe.sol` | 多签主入口 |
| `checkSignatures(...)` | `contracts/Safe.sol` | 签名验证入口 |
| `checkNSignatures(...)` | `contracts/Safe.sol` | Safe 核心签名分流器，按 `v` 值切换 ECDSA / EIP-1271 / approved hash / P-256 路径 |
| `approveHash(...)` | `contracts/Safe.sol` | owner 预批准某个 hash，供 `v = 1` 签名路径使用 |
| `execTransactionFromModule(...)` | `contracts/base/ModuleManager.sol` | 模块执行入口 |
| `execTransactionFromModuleReturnData(...)` | `contracts/base/ModuleManager.sol` | 模块执行并返回 `returndata` |
| `setFallbackHandler(...)` | `contracts/base/FallbackManager.sol` | 设置 fallback 处理器 |
| `simulateAndRevert(...)` | `contracts/common/StorageAccessible.sol` | 在 Safe 上下文中模拟执行并把结果编码进 revert data |
| `simulate(...)` | `contracts/accessors/SimulateTxAccessor.sol` | 与 `simulateAndRevert` 配合使用的执行器 |
| `setSafeMethod(...)` | `contracts/handler/extensible/FallbackHandler.sol` | 为指定 selector 配置 extensible fallback 路由 |
| `setDomainVerifier(...)` | `contracts/handler/extensible/SignatureVerifierMuxer.sol` | 为某个 `domainSeparator` 绑定 verifier |
| `addSupportedInterfaceBatch(...)` | `contracts/handler/extensible/ERC165Handler.sol` | 批量注册 interface 的 selector 路由并启用 ERC-165 声明 |
| `createProxyWithNonce(...)` | `contracts/proxies/SafeProxyFactory.sol` | 使用 CREATE2 部署 proxy，并可原子化执行 initializer |
| `fallback()` | `contracts/proxies/SafeProxy.sol` | Proxy 转发入口 |

### 7.3 相关工具库

- **SafeToL2Setup**：用于“跨网络同地址部署”，在 setup 阶段通过 `delegatecall` 将实现合约从 `Safe` 切换到 `SafeL2`。
- **MultiSend**：支持在一次打包调用中混合执行 `CALL` 与 `DELEGATECALL`。
- **MultiSendCallOnly**：仅支持 `CALL` 的批量执行工具，适合不希望批量载荷获得 Safe 上下文写权限的场景。

---

## 源码引用

| 项目 | 信息 |
|------|------|
| **仓库** | [safe-fndn/safe-smart-account](https://github.com/safe-fndn/safe-smart-account) |
| **版本** | v1.5.0 |
| **Commit** | [`a2e19c6`](https://github.com/safe-fndn/safe-smart-account/commit/a2e19c6aa42a45ceec68057f3fa387f169c5b321) |
| **License** | LGPL-3.0 |

*本报告基于上述 commit 的源码整理，若需与某次发布版本严格对应，请以该版本 tag 为准。*
