# Signatures
# 签名

The Safe supports different types of signatures. All signatures are combined into a single `bytes` and transmitted to the contract when a transaction should be executed.
Safe 支持不同类型的签名。所有签名被组合成一个单一的 `bytes` 并在应当执行交易时传输给合约。

### Encoding
### 编码

Each signature has a constant length of 65 bytes. If more data is necessary, it can be appended to the end of concatenated constant data of all signatures. The position is encoded into the constant length data.
每个签名有一个固定的 65 字节长度。如果需要更多数据，它可以被追加到所有签名拼接后的固定长度数据末尾。该位置（偏移量）被编码在固定长度数据中。

Constant part per signature: `{(max) 64-bytes signature data}{1-byte signature type}`
每个签名的固定部分：`{(最多) 64 字节签名数据}{1 字节签名类型}`

All the signatures are sorted by the signer address and concatenated.
所有的签名根据签名者地址进行排序并拼接。

#### ECDSA Signature
#### ECDSA 签名

`31 > signature type > 26`

To be able to have the ECDSA signature without the need for additional data we use the signature type byte to encode `v`.
为了能够在不需要额外数据的情况下使用 ECDSA 签名，我们使用签名类型的字节来编码 `v`。

**Constant part:**
**固定部分：**

`{32-bytes r}{32-bytes s}{1-byte v}`

`r`, `s` and `v` are the required parts of the ECDSA signature to recover the signer.
`r`、`s` 和 `v` 是 ECDSA 签名中恢复签名者所需的必要部分。

#### `eth_sign` signature
#### `eth_sign` 签名

`signature type > 30`

To be able to use `eth_sign` we need to take the parameters `r`, `s` and `v` from calling `eth_sign` and set `v = v + 4`
为了能够使用 `eth_sign`，我们需要从调用 `eth_sign` 中获取参数 `r`、`s` 和 `v`，并设置 `v = v + 4`。

**Constant part:**
**固定部分：**

`{32-bytes r}{32-bytes s}{1-byte v}`

`r`, `s` and `v` are the required parts of the ECDSA signature to recover the signer. `v` will be subtracted by `4` to calculate the signature.
`r`、`s` 和 `v` 是 ECDSA 签名中恢复签名者所需的必要部分。在计算签名时，`v` 将被减去 `4`。

#### Contract Signature \(EIP-1271\)
#### 合约签名 \(EIP-1271\)

`signature type == 0`

**Constant part:**
**固定部分：**

`{32-bytes signature verifier}{32-bytes data position}{1-byte signature type}`

**Signature verifier** - Padded address of the contract that implements the EIP-1271 interface to verify the signature
**Signature verifier (签名验证者)** - 实现了 EIP-1271 接口以验证签名的合约地址（左侧补零填充至 32 字节）。

**Data position** - Position of the start of the signature data \(offset relative to the beginning of the signature data\)
**Data position (数据位置)** - 签名数据起始点的位置（相对于整个签名数据起始点的偏移量）。

**Signature type** - 0
**Signature type (签名类型)** - 0

**Dynamic part \(solidity bytes\):**
**动态部分 \(Solidity bytes\)：**

`{32-bytes signature length}{bytes signature data}`

**Signature data** - Signature bytes that are verified by the signature verifier
**Signature data (签名数据)** - 被签名验证者所验证的签名字节流。

The method `signMessage` can be used to mark a message as signed onchain.
可以使用 `signMessage` 方法在链上将某条消息标记为已签名。

#### Pre-Validated Signatures
#### 预验证签名 (Pre-Validated Signatures)

`signature type == 1`

**Constant Part:**
**固定部分：**

`{32-bytes hash validator}{32-bytes ignored}{1-byte signature type}`

**Hash validator** - Padded address of the account that pre-validated the hash that should be validated. The Safe keeps track of all hashes that have been pre-validated. This is done with a **mapping address to mapping of bytes32 to boolean** where it is possible to set a hash as validated by a certain address \(hash validator\). To add an entry to this mapping use `approveHash`. Also, if the validator is the sender of the transaction that executed the Safe transaction, it is **not** required to use `approveHash` to add an entry to the mapping. \(This can be seen in the [Team Edition tests](https://github.com/safe-global/safe-smart-account/blob/v1.0.0/test/gnosisSafeTeamEdition.js)\)
**Hash validator (哈希验证者)** - 预先验证了应被验证哈希的账户地址（填充后的）。Safe 会记录所有已预先验证的哈希。这是通过一个 **address 映射到 bytes32 再映射到 boolean 的嵌套 mapping** 来实现的，它允许将某个哈希设置为已被特定地址（哈希验证者）所验证。使用 `approveHash` 可以向这个映射中添加条目。此外，如果该验证者正是执行 Safe 交易的交易发送者（sender），则**不需要**使用 `approveHash` 来向映射中添加条目。\(这在 [Team Edition tests](https://github.com/safe-global/safe-smart-account/blob/v1.0.0/test/gnosisSafeTeamEdition.js) 中可以看到\)

**Signature type** - 1
**Signature type (签名类型)** - 1

### Examples
### 示例

Assuming that three signatures are required to confirm a transaction where one signer uses an EOA to generate a ECDSA signature, another a contract signature and the last a pre-validated signature:
假设一笔交易需要三个签名来确认，其中一个签名者使用 EOA 生成 ECDSA 签名，另一个使用合约签名，最后一个使用预验证签名：

We assume that the following addresses generate the following signatures:
我们假设以下地址生成了如下签名：

1. `0x3` \(EOA address\) -&gt; `bde0b9f486b1960454e326375d0b1680243e031fd4fb3f070d9a3ef9871ccfd5` \(r\) + `7d1a653cffb6321f889169f08e548684e005f2b0c3a6c06fba4c4a68f5e00624` \(s\) + `1c` \(v\)
2. `0x1` \(EIP-1271 validator contract address\) -&gt; `0000000000000000000000000000000000000000000000000000000000000001` \(address\) + `00000000000000000000000000000000000000000000000000000000000000c3` \(dynamic position\) + `00` \(signature type\)
    - The contract takes the following `bytes` \(dynamic part\) for verification `00000000000000000000000000000000000000000000000000000000deadbeef`
    - 该合约使用以下 `bytes`（动态部分）进行验证：`00000000000000000000000000000000000000000000000000000000deadbeef`
3. `0x2` \(Validator address\) -&gt; `0000000000000000000000000000000000000000000000000000000000000002` \(address\) +`0000000000000000000000000000000000000000000000000000000000000000` \(padding - not used\) + `01` \(signature type\)

The constant parts need to be sorted so that the recovered signers are sorted **ascending** \(natural order\) by address \(not checksummed\).
这些固定部分需要被排序，以使恢复出来的签名者地址按**升序**（自然顺序，非 checksum 格式）排列。

The signature bytes used for `execTransaction` would therefore be the following:
因此，用于 `execTransaction` 的签名 `bytes` 将如下所示：

```text
"0x" +
"000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000c300" + // encoded EIP-1271 signature / 编码的 EIP-1271 签名
"0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000001" + // encoded pre-validated signature / 编码的预验证签名
"bde0b9f486b1960454e326375d0b1680243e031fd4fb3f070d9a3ef9871ccfd57d1a653cffb6321f889169f08e548684e005f2b0c3a6c06fba4c4a68f5e006241c" + // encoded ECDSA signature / 编码的 ECDSA 签名
"000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000deadbeef"     // length of bytes + data of bytes / bytes 的长度 + bytes 的数据
```
