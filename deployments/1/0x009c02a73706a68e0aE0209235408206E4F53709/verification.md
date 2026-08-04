# Ethereum mainnet deployment verification — K3 cbBTC Vault

## Verdict

**Deployment verified and mainnet smoke-tested.**

The live implementation, beacon, wrapper proxy, and `Staging` runtime bytecode match the artifacts built from commit [`46abe4206993dc5340e092e30e78a45caaf02357`](https://github.com/K3-Capital/erc7540-wrapper/commit/46abe4206993dc5340e092e30e78a45caaf02357). The ERC-1967 beacon-proxy wiring, initialization, owner and settlement authority, cbBTC asset configuration, authorization boundaries, and post-deployment request/settlement/claim flows were checked on Ethereum mainnet.

This report records deployment provenance and observed behavior at explicit blocks. It is not a security audit. The beacon owner can upgrade the implementation, so integrators must also check the current beacon state.

## Deployment identity

| Field | Value |
| --- | --- |
| Network | Ethereum mainnet (`chainId = 1`) |
| Completion block | [`25,680,513`](https://etherscan.io/block/25680513) |
| Completion time | `2026-08-04T09:00:35Z` |
| Deployer | [`0x43F4600D98Ae531D7e5F1f8FF68ef97779d31641`](https://etherscan.io/address/0x43f4600d98ae531d7e5f1f8ff68ef97779d31641) |
| Source commit | [`46abe4206993dc5340e092e30e78a45caaf02357`](https://github.com/K3-Capital/erc7540-wrapper/commit/46abe4206993dc5340e092e30e78a45caaf02357) |
| Deployment script | `script/Deploy.s.sol:DeployAll` |
| Solidity | `0.8.30+commit.73712a01` |
| Optimizer | Enabled, 200 runs |
| EVM version | `osaka` |
| Effective metadata settings | `viaIR = false`, `bytecodeHash = ipfs`, CBOR metadata enabled, literal source content disabled |
| Reproduction toolchain | Foundry `1.7.1` (`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`) |

## Contracts and configuration

| Component | Address | Configuration |
| --- | --- | --- |
| Wrapper proxy | [`0x009c02a73706a68e0aE0209235408206E4F53709`](https://etherscan.io/address/0x009c02a73706a68e0ae0209235408206e4f53709#code) | `BeaconProxy`; canonical integration address |
| Beacon | [`0x7b80bdb8F0777F52A6054A0E48AFc15200b780B8`](https://etherscan.io/address/0x7b80bdb8f0777f52a6054a0e48afc15200b780b8#code) | `UpgradeableBeacon` |
| Implementation | [`0xC768529098e20e089Efd28A32c6Afa1D569b831a`](https://etherscan.io/address/0xc768529098e20e089efd28a32c6afa1d569b831a#code) | `SmartAccountWrapper` |
| Staging | [`0x21636C226e113d7Dd59dA2987eaA7dAbBE4159c7`](https://etherscan.io/address/0x21636c226e113d7dd59da2987eaa7dabbe4159c7#code) | Immutable vault is the wrapper proxy |
| Underlying | [`0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf`](https://etherscan.io/token/0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf) | Coinbase Wrapped BTC (`cbBTC`), 8 decimals |
| Owner/admin | [`0x349bB895dB64f74AB9788693a16Ee03776195504`](https://etherscan.io/address/0x349bb895db64f74ab9788693a16ee03776195504) | EOA; wrapper owner, beacon owner, virtual `DEFAULT_ADMIN_ROLE` |
| Smart account | [`0x034d1E094Efd47d4e738033d0157f31718820470`](https://etherscan.io/address/0x034d1e094efd47d4e738033d0157f31718820470) | EIP-7702 delegated EOA; sole `closeEpoch` and `settleEpoch` authority |

Wrapper metadata:

- Name: `K3 cbBTC Vault`
- Symbol: `k3cbBTC`
- Decimals: 8
- Asset: canonical Ethereum cbBTC

All four project deployment contracts are published on Etherscan as exact source matches. `Staging` is verified with constructor argument `0x009c02a73706a68e0aE0209235408206E4F53709`.

## Deployment transactions

The CREATE3 deployment produced six mainnet transactions. Every receipt has `status = 1`.

The exact generated [`run-1785834040477.json`](../../../broadcast/Deploy.s.sol/1/run-1785834040477.json) artifact is retained with SHA-256 `1eb5ecad499e10649040a7e8ac071605889f36aba1610433ba876f22009f0e88` for forensic completeness, but it has a known integrity defect: four `transactions[].hash` values are associated with the wrong transaction payload objects. Its receipt array is valid; its per-object transaction hash fields are **not authoritative**.

| Payload object | Incorrect artifact hash | Correct receipt/live hash |
| --- | --- | --- |
| Deploy implementation | `0x329350…ccb9` | `0xc4e8c7…b2f3f` |
| Create beacon CREATE3 deployer | `0xc80393…2247` | `0x73c1d7…31c2` |
| Deploy beacon | `0xc4e8c7…b2f3f` | `0x329350…ccb9` |
| Deploy wrapper and initialize `Staging` | `0x73c1d7…31c2` | `0xc80393…2247` |

The sequence below is normalized from live receipts by block number and transaction index. Use this table or `deployment.json`, not the raw artifact's `transactions[].hash` associations.

| Sequence | Purpose | Transaction | Block |
| ---: | --- | --- | ---: |
| 1 | Create implementation's CREATE3 deployer | [`0x3c3c…e4d9`](https://etherscan.io/tx/0x3c3c2312cf40f635952e159312aa897696bd2f4bef63cc730b80fd64c9b1e4d9) | 25,680,512 |
| 2 | Deploy `SmartAccountWrapper` implementation | [`0xc4e8…f3f`](https://etherscan.io/tx/0xc4e8c72fb41d7580e8ddaf98a4f2bef082133d5c05168fd6c3468ca4b58b2f3f) | 25,680,513 |
| 3 | Create beacon's CREATE3 deployer | [`0x73c1…31c2`](https://etherscan.io/tx/0x73c1d7404790d876f44ce17886b573a425f598a48c1a8630329d396f645031c2) | 25,680,513 |
| 4 | Deploy `UpgradeableBeacon` | [`0x3293…cb9`](https://etherscan.io/tx/0x3293507bc32e9d34b778432274de2e6d680b4cee20f899f88d805d380eabccb9) | 25,680,513 |
| 5 | Create wrapper's CREATE3 deployer | [`0x7003…3f`](https://etherscan.io/tx/0x70037a879aba638c63893e90c0748487df83b751c66dd1b0b8816e37c1ddac3f) | 25,680,513 |
| 6 | Deploy and initialize `BeaconProxy`; initializer deploys `Staging` | [`0xc803…2247`](https://etherscan.io/tx/0xc80393c3a336cb351ed0899f82e303a6c5fde9156f6b8756a39b4a13f54c2247) | 25,680,513 |

The public derived salts and ephemeral CREATE3 deployer addresses are preserved in [`deployment.json`](deployment.json). The original local `DEPLOY_SALT` is not needed to validate the completed deployment and is not stored in this public record.

## Proxy and initialization verification

The wrapper is an OpenZeppelin v5 beacon proxy.

| ERC-1967 slot | Value | Result |
| --- | --- | --- |
| Beacon `0xa3f0…d50` | `0x0000000000000000000000007b80bdb8f0777f52a6054a0e48afc15200b780b8` | Correct beacon |
| Implementation `0x3608…bbc` | Zero | Correct for beacon proxy |
| Admin `0xb531…103` | Zero | Correct for beacon proxy |

The OpenZeppelin v5 proxy runtime also embeds the beacon as an immutable. Reconstructing the runtime with the deployed beacon at immutable offset 29 produced an exact live-code match.

The beacon reported:

- `implementation()` → `0xC768529098e20e089Efd28A32c6Afa1D569b831a`
- `owner()` → `0x349bB895dB64f74AB9788693a16Ee03776195504`

Initialization checks confirmed:

- wrapper initializer version is 1;
- the standalone implementation's initializers are disabled;
- reinitializing either the proxy or implementation reverts;
- `Staging.vault()` returns the wrapper proxy;
- pending owner is the zero address; and
- wrapper owner, smart account, asset, name, and symbol match the intended constructor payload.

## Runtime-bytecode provenance

Live runtime was compared with locally rebuilt artifacts from the deployed source commit.

| Contract | Bytes | Live runtime keccak256 | Artifact result |
| --- | ---: | --- | --- |
| `SmartAccountWrapper` | 18,868 | `0xae2c796dac5a5960ec2cee000843017598854a32473b77426d51377c38b87803` | Exact match |
| `UpgradeableBeacon` | 644 | `0x0ce4415c191fe5f2c89e67fd04fc646aa9b61958a01026bf58029708b8bd2a51` | Exact match |
| `BeaconProxy` | 283 | `0xaf79977087d29e846e31c49ebce3f72c322575d227f1c44a8e62c17eb2226c25` | Exact after beacon immutable substitution |
| `Staging` | 577 | `0xaa3c279ffa5b301ff95420e2fd67ac73898480622ed490116162c68fad825c69` | Exact after wrapper immutable substitution |

The deployed source commit was also rebuilt from a clean checkout with `forge build --sizes`. `SmartAccountWrapper` compiled to 18,868 runtime bytes, leaving 5,708 bytes below the EIP-170 limit. `forge fmt --check` passed, and the clean full suite passed with 83 tests and no failures.

## Authorization verification

Read-only `eth_call` simulations at the initial verification snapshot established both positive and negative boundaries:

- smart account can call `closeEpoch`;
- owner cannot call `closeEpoch`;
- owner can rotate the smart account;
- smart account cannot rotate itself;
- owner can pause;
- smart account cannot pause without `PAUSER_ROLE`;
- owner can call `UpgradeableBeacon.upgradeTo`;
- smart account cannot upgrade the beacon;
- wrapper can instruct `Staging` to transfer tokens; and
- owner cannot directly instruct `Staging` to transfer tokens.

## Mainnet smoke test

After deployment verification, the production flow was exercised with 14 successful calls visible in the [wrapper transaction history](https://etherscan.io/txs?a=0x009c02a73706a68e0ae0209235408206e4f53709):

| Operation | Successful calls |
| --- | ---: |
| `requestDeposit` | 2 |
| `deposit` claim | 2 |
| `requestRedeem` | 2 |
| `redeem` claim | 2 |
| `closeEpoch` | 3 |
| `settleEpoch` | 3 |

The complete immutable receipt/input record is in [`smoke-test.json`](smoke-test.json), SHA-256 `254571b22f0c3389f0f2604d4aadc4606aa19e82d6852be5a8f0e3708e2dbcd3`. Amounts and NAV snapshots are recorded in 8-decimal base units. The exact sequence was:

| # | Block | Call and principal arguments | Sender | Transaction |
| ---: | ---: | --- | --- | --- |
| 1 | 25,680,569 | `requestDeposit(39883, testAccount, testAccount)` | Test account | [`0xf363…deb53`](https://etherscan.io/tx/0xf3631ae6c04810e5ba3fb27129c98953cc9c93dca7f834fe5f0b17e8eacdeb53) |
| 2 | 25,681,887 | `closeEpoch()` | Smart account | [`0x67ab…af0e`](https://etherscan.io/tx/0x67abe8b0ddb7c31501a0d009b7510cd089c04725bdde025d7f2ecbc8dcebaf0e) |
| 3 | 25,681,953 | `settleEpoch(1, 0)` | Smart account | [`0x32d5…dda4`](https://etherscan.io/tx/0x32d5ef1262ee349fd99003e3b3dc42e9da9122cceaa6dceb17c1b6694705dda4) |
| 4 | 25,681,964 | `deposit(39883, testAccount, testAccount)` | Test account | [`0x4991…51ff`](https://etherscan.io/tx/0x4991ac06bb0d5526c69f7541e5309e0b9c8f7942b87bf6cd375ea90a830b51ff) |
| 5 | 25,681,966 | `requestRedeem(20000, testAccount, testAccount)` | Test account | [`0xe605…714a`](https://etherscan.io/tx/0xe605f6b9e2d8112207eb09bdf8a634e6016f949e0476748c36eeffda5b84714a) |
| 6 | 25,681,977 | `closeEpoch()` | Smart account | [`0xdde0…0961`](https://etherscan.io/tx/0xdde00161f6c375032dd9efcb5e9ca7b355feca77c07ec74bfaca941f8ace0961) |
| 7 | 25,682,224 | `settleEpoch(2, 39883)` | Smart account | [`0xadfe…39ea`](https://etherscan.io/tx/0xadfea6eef6357220d3d759b1ab2237d56ab9ffb2cb821e91f43d4beef85339ea) |
| 8 | 25,682,244 | `redeem(20000, testAccount, testAccount)` | Test account | [`0xc336…a289`](https://etherscan.io/tx/0xc3360a446dc82139b59e9e30562e78a2fac3bd84f3db791b6ad6bc74b018a289) |
| 9 | 25,682,248 | `requestDeposit(20000, testAccount, testAccount)` | Test account | [`0x8333…c8b7`](https://etherscan.io/tx/0x83339702914d2c5d986a0e70b169871927d605a5386a7eab99a8209695e5c8b7) |
| 10 | 25,682,251 | `requestRedeem(19883, testAccount, testAccount)` | Test account | [`0xaab2…201e`](https://etherscan.io/tx/0xaab210906d148f6d791b9ec1a458eb6cf721a5a008ab460b28f9b194c599201e) |
| 11 | 25,682,272 | `closeEpoch()` | Smart account | [`0xfb04…8cf7`](https://etherscan.io/tx/0xfb042e2d79dfa0219be729389027729bff7395d62aba6b1239010046d54b8cf7) |
| 12 | 25,682,288 | `settleEpoch(3, 19883)` | Smart account | [`0x492d…28ef`](https://etherscan.io/tx/0x492d6822eda6edf3e5902636ff8a944119bb694713114b3f71dd2d1e4cf528ef) |
| 13 | 25,682,380 | `deposit(20000, testAccount, testAccount)` | Test account | [`0x3d58…3163`](https://etherscan.io/tx/0x3d58b8b2b01b39b5781873474cffdfdcd2883fe045dae2d666d3ac457b313163) |
| 14 | 25,682,381 | `redeem(19883, testAccount, testAccount)` | Test account | [`0x4939…dbf0`](https://etherscan.io/tx/0x49395bb929ce8f5abe68a03e20c57189ee9f4441e7834bc9644c51229ee5dbf0) |

The calls span blocks 25,680,569 through 25,682,381. User request/claim operations were submitted by the deployment test account, while the configured smart account submitted all six epoch-management calls.

A coherent post-smoke snapshot was read at block [`25,682,656`](https://etherscan.io/block/25682656), timestamp `2026-08-04T16:09:47Z`:

- paused: `false`
- current epoch: `4`
- frozen epoch: `0`
- total supply: `20,000` base units
- total assets: `20,000` base units
- redeem claim reserves: `0`
- beacon still points to the deployed implementation
- owner and smart account remain unchanged
- smart account is now an active EIP-7702 delegated account and successfully executed the six epoch calls
- `Staging` remains bound to the wrapper

The initial smart-account operational caveat was superseded by its EIP-7702 delegation and six successful epoch-management transactions. The owner was funded and active, but remained an EOA without an on-chain multisig or timelock; that trust assumption was not removed by the smoke test.

## Privileged-account trust assumptions

At snapshot block 25,682,656:

- **Owner/admin:** `0x349b…5504` had nonce 2, a nonzero balance, and empty runtime code and was therefore an EOA. It directly controlled wrapper administration and beacon upgrades. There was no on-chain multisig threshold, timelock, or other contract-enforced upgrade policy at this address.
- **Settlement smart account:** `0x034d…0470` had nonce 8 and the EIP-7702 delegation designator `0xef0100e6cae83bde06e4c305530e199d7217f42808555b`, and successfully executed all three closes and all three settlements.
- **Delegation target:** [`0xe6Cae83BdE06E4c305530e199D7217f42808555B`](https://etherscan.io/address/0xe6cae83bde06e4c305530e199d7217f42808555b#code) is the exact-match-verified `Simple7702Account` implementation. Its 3,639-byte runtime hash was `0xcc7b633aef4b2543cb8f37522adf1a401f910f0f6b2430c1eecc11f401ccfcf3`. This is an external dependency; this deployment report does not establish its audit status.

Loss or compromise of the owner can change the implementation and administrative configuration. Loss or compromise of the settlement smart account can control epoch timing and reported NAV snapshots. Integrators must evaluate both control planes, not only the vault bytecode.

## Ongoing verification

Before relying on this deployment, recheck at minimum:

```shell
cast call 0x7b80bdb8F0777F52A6054A0E48AFc15200b780B8 "implementation()(address)" --rpc-url "$RPC_URL"
cast call 0x7b80bdb8F0777F52A6054A0E48AFc15200b780B8 "owner()(address)" --rpc-url "$RPC_URL"
cast call 0x009c02a73706a68e0aE0209235408206E4F53709 "owner()(address)" --rpc-url "$RPC_URL"
cast call 0x009c02a73706a68e0aE0209235408206E4F53709 "smartAccount()(address)" --rpc-url "$RPC_URL"
cast call 0x009c02a73706a68e0aE0209235408206E4F53709 "asset()(address)" --rpc-url "$RPC_URL"
cast code 0x349bB895dB64f74AB9788693a16Ee03776195504 --rpc-url "$RPC_URL"
cast code 0x034d1E094Efd47d4e738033d0157f31718820470 --rpc-url "$RPC_URL"
cast keccak "$(cast code 0xe6Cae83BdE06E4c305530e199D7217f42808555B --rpc-url "$RPC_URL")"
```

Future beacon upgrades must be documented as append-only records alongside this deployment. Major accounting or control-flow changes require a fresh audit before production use.
