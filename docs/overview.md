## Safe Protocol

The Safe Protocol is a non-custodial set of smart contracts that allows users to create programmable multi-signature accounts that require multiple parties to authorize transactions. This provides an added layer of security and reduces the risk of funds being lost or stolen compared to regular EOA accounts.

Safe Protocol 是一组非托管智能合约，允许用户创建可编程的多签账户，并要求多个参与方共同授权交易。相比普通 EOA 账户，这种方式增加了一层安全保障，降低了资金丢失或被盗的风险。

### Basic flows:

### 基本流程：

**Deploying a Safe account**

**部署 Safe 账户**

- A user creates a Safe account by deploying a Proxy contract pointing to the Safe implementation contract. The implementation itself is Proxy-agnostic.
- 用户通过部署一个指向 Safe 实现合约的 Proxy 合约来创建 Safe 账户。实现合约本身并不依赖特定的 Proxy 实现。
- The user configures the Safe wallet by setting the number of required signatures and the list of owners.
- 用户通过设置所需签名数和 owner 列表来完成 Safe 钱包的初始化配置。

**Executing a transaction**

**执行交易**

- To sign a transaction, the user generates a Safe transaction hash using the EIP-712 typed structured data hashing scheme.
- 在签署交易前，用户先基于 EIP-712 结构化数据哈希方案生成 Safe 交易哈希。
- The required amount of parties sign it either with a private key, onchain approval, or a smart contract wallet
- 满足阈值要求的参与方可以使用私钥、链上批准，或智能合约钱包对该哈希进行签名。
- The user submits the transaction to the Safe account onchain.
- 用户随后将该交易提交到链上的 Safe 账户执行。

**Updating the owner structure or policies**

**更新 owner 结构或策略**

- The implementation contract has self-authorised (can be called by the Safe account itself) methods to update the owner structure or policies of the Safe account.
- 实现合约中包含一组 self-authorised 方法（只能由 Safe 自身调用），用于更新 Safe 账户的 owner 结构或策略配置。

**Signing a message**
The message can be signed in two ways: onchain and offchain.

**签署消息**
消息可以通过两种方式签署：链上签署和链下签署。

- Onchain signing:
- Onchain signing:
    - The user generates a Safe message hash using the EIP-712 typed structured data hashing scheme.
    - 用户基于 EIP-712 结构化数据哈希方案生成 Safe message hash。
    - The user submits a delegatecall transaction to `SignMessageLib` contract to mark the hash as signed.
    - 用户提交一笔对 `SignMessageLib` 合约的 `delegatecall` 交易，将该哈希标记为已签名。
    - The hash now can be verified through the EIP-1271 interface.
    - 之后，这个哈希即可通过 EIP-1271 接口进行验证。
- Offchain signing:
- Offchain signing:
    - The user generates a Safe message hash using the EIP-712 typed structured data hashing scheme.
    - 用户基于 EIP-712 结构化数据哈希方案生成 Safe message hash。
    - The user signs the message hash with a private key or a smart contract wallet.
    - 用户使用私钥或智能合约钱包对该消息哈希进行签名。
    - The signature now can be verified through the EIP-1271 interface.
    - 之后，这个签名也可以通过 EIP-1271 接口进行验证。

### Advanced features

### 高级特性

#### Modules

#### 模块（Modules）

Modules add additional functionalities to the Safe Smart Account contracts. They are smart contracts that implement the Safe’s functionality while separating module logic from the Safe’s core contract.

模块为 Safe Smart Account 合约增加额外功能。它们本质上是将某些 Safe 功能以独立智能合约的形式实现，从而把模块逻辑与 Safe 核心合约解耦。

A basic Safe does not require any modules. Adding and removing a module requires confirmation from all owners. Events are emitted whenever a module is added or removed and also whenever a module transaction succeeds or fails.

一个基础版 Safe 并不依赖任何模块。新增或移除模块都需要 owners 确认；当模块被添加、移除，或者模块交易执行成功/失败时，系统都会发出相应事件。

> ⚠️ WARNING: Modules are a security risk since they can execute arbitrary transactions,
> so only trusted and audited modules should be added to a Safe. A malicious module can completely take over a Safe

> ⚠️ 警告：模块具有安全风险，因为它们可以执行任意交易。
> 因此，只有受信任且经过审计的模块才应被添加到 Safe 中。恶意模块可能完全接管一个 Safe。

#### Transaction guards

#### 交易守卫（Transaction guards）

Transaction guards can make checks before and after a Safe transaction.
The pre-transaction check can, for example, validate all parameters of the transaction before execution. The post-transaction check can, for example, perform checks on the final state of the Safe.

交易守卫可以在 Safe 交易执行前后执行检查。
例如，前置检查可以在执行前校验交易的全部参数；后置检查则可以对 Safe 的最终状态进行约束或验证。

> ⚠️ IMPORTANT: Since a guard has full power to block Safe transaction execution,
> a broken guard can cause a denial of service for the Safe. Make sure to carefully audit the guard code and design recovery mechanisms.

> ⚠️ 重要：由于 guard 拥有阻止 Safe 交易执行的完整权限，
> 一个有缺陷的 guard 可能导致 Safe 发生拒绝服务。应当仔细审计 guard 代码，并设计相应的恢复机制。

### Technical Overview

### 技术概览

#### Safe Domain Separator

#### Safe Domain Separator（域分隔符）

```js
DomainSeparator {
    uint256 chainId;
    address verifyingContract;
}
```

The domain includes the chainId and the address of the Safe account to prevent replay attacks across chains/safes.

该 domain 包含 `chainId` 和 Safe 账户地址，用于防止跨链或跨 Safe 的重放攻击。

#### Safe Transaction

#### Safe Transaction（Safe 交易）

The Safe transaction is defined by the following EIP-712 typed structured data:

Safe 交易由如下 EIP-712 结构化数据定义：

```js
SafeTx {
    bytes to;
    uint256 value;
    bytes data;
    Enum.Operation operation;
    uint256 safeTxGas;
    uint256 baseGas;
    uint256 gasPrice;
    address gasToken;
    address refundReceiver;
    uint256 nonce;
}
```

- to: address of the account to which the transaction is being sent
- `to`：交易发送到的目标账户地址
- value: value in wei to be sent with the transaction
- `value`：交易中附带发送的 wei 数量
- data: data to be sent with the transaction
- `data`：交易附带的数据
- operation: type of operation (0: CALL, 1: DELEGATECALL)
- `operation`：操作类型（0 表示 `CALL`，1 表示 `DELEGATECALL`）
- safeTxGas: gas that should be used for the Safe transaction
- `safeTxGas`：该笔 Safe 交易可使用的 gas
- baseGas: gas costs for data that needs to be paid for by the Safe regardless of the used gas amount
- `baseGas`：Safe 无论实际消耗多少 gas 都需要承担的数据等基础 gas 成本
- gasPrice: gas price that should be used for the payment calculation
- `gasPrice`：用于退款/支付计算的 gas 单价
- gasToken: token address (or 0 if ETH) that is used for the payment
- `gasToken`：用于支付 gas 的代币地址（若为 ETH 则填 0）
- refundReceiver: address of receiver of gas payment (or 0 if tx.origin)
- `refundReceiver`：接收 gas 退款的地址（若为 0 则默认为 `tx.origin`）
- nonce: unique number to make sure this transaction can only be executed once
- `nonce`：唯一编号，确保该交易只能被执行一次

#### Safe Transaction Hash

#### Safe Transaction Hash（Safe 交易哈希）

The Safe transaction hash is generated by hashing the Safe transaction with the EIP-712 typed structured data hashing scheme.

Safe 交易哈希是通过 EIP-712 结构化数据哈希方案对 Safe 交易进行哈希得到的。

#### Safe Transaction Signature

#### Safe Transaction Signature（Safe 交易签名）

A Safe transaction signature is generated by signing the Safe transaction hash.

Safe 交易签名是通过对 Safe 交易哈希进行签名生成的。

To learn more about supported signature formats, please refer to the [Signatures](./signatures.md) documentation.

关于支持的签名格式，请参考 [Signatures](./signatures.md) 文档。

#### Safe Transaction Gas

#### Safe Transaction Gas

For a detailed description of the Safe transaction gas, please refer to the [safeTxGas](./safe_tx_gas.md) documentation.

关于 Safe 交易 gas 的详细说明，请参考 [safeTxGas](./safe_tx_gas.md) 文档。

#### Safe Message

#### Safe Message（Safe 消息）

The Safe message is defined by the following EIP-712 typed structured data:

Safe 消息由如下 EIP-712 结构化数据定义：

```js
SafeMessage {
    bytes message;
}
```

#### Owner Management

#### Owner 管理

Owners are managed in the `OwnerManager` contract. It uses a linked list to store the owners because the EVM bytecode `solc` generates for a dynamic array is not the most efficient.

Owners 由 `OwnerManager` 合约管理。之所以使用链表来存储 owners，是因为 `solc` 为动态数组生成的 EVM 字节码并不是最节省 gas 的方案。

The linked list head and tail are the 0x1 address. The head and tail are never removed from the list. The head and tail are never owners.

该链表的头和尾都使用 `0x1` 地址作为哨兵节点。哨兵节点永远不会从链表中移除，也永远不会被视为 owner。

#### Module Management

#### Module 管理

Modules are managed in the `ModuleManager` contract. It uses a linked list to store the modules because the EVM bytecode `solc` generates for a dynamic array is not the most efficient.

Modules 由 `ModuleManager` 合约管理。它同样使用链表来存储模块，因为动态数组在 EVM 中并不是最优的实现方式。

The linked list head and tail are the 0x1 address. The head and tail are never removed from the list. The head and tail are never modules.

模块链表的头和尾同样都是 `0x1` 哨兵地址。哨兵节点不会从链表中移除，也不会被视为模块本身。

#### Transaction execution

#### 交易执行

The method `execTransaction` in the Safe.sol contract is the main entry point for executing transactions.
It takes the transaction parameters and nonce/chain ID from the chain, generates the Safe transaction hash and verifies the signatures.

`Safe.sol` 中的 `execTransaction` 方法是执行交易的主入口。
它会读取交易参数以及链上的 nonce / chain ID，生成 Safe 交易哈希，并验证签名。

If a transaction guard is set, it forwards the transaction to the guard for additional checks. If the guard check passes, it executes the transaction. After the transaction is executed, it forwards the hash and success boolean to the guard.

如果设置了交易 guard，Safe 会先将交易转发给 guard 做额外检查；只有 guard 检查通过后，交易才会被执行。交易执行完成后，Safe 还会把交易哈希和成功标记再传给 guard 做后置检查。

If the refund parameter is set to true, the Safe will refund the gas costs to the refund receiver. If the refund receiver is set to 0, the Safe will refund the gas costs to the tx.origin.

如果退款参数被启用，Safe 会将 gas 成本退还给 `refundReceiver`。如果 `refundReceiver` 被设置为 0，则退款默认发送给 `tx.origin`。

#### Fallback contract

#### Fallback 合约

A Fallback contract contains logic outside of the scope of the core Safe Smart Account, such as the token callback logic and/or logic that didn't fit into the core contracts because of bytecode size limitations.

Fallback 合约承载的是核心 Safe Smart Account 范围之外的逻辑，例如 token 回调逻辑，或者由于字节码大小限制而无法放入核心合约中的其他逻辑。
