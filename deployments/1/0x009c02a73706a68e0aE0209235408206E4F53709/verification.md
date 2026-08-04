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

## Contracts and configuration

| Component | Address | Configuration |
| --- | --- | --- |
| Wrapper proxy | [`0x009c02a73706a68e0aE0209235408206E4F53709`](https://etherscan.io/address/0x009c02a73706a68e0ae0209235408206e4f53709#code) | `BeaconProxy`; canonical integration address |
| Beacon | [`0x7b80bdb8F0777F52A6054A0E48AFc15200b780B8`](https://etherscan.io/address/0x7b80bdb8f0777f52a6054a0e48afc15200b780b8#code) | `UpgradeableBeacon` |
| Implementation | [`0xC768529098e20e089Efd28A32c6Afa1D569b831a`](https://etherscan.io/address/0xc768529098e20e089efd28a32c6afa1d569b831a#code) | `SmartAccountWrapper` |
| Staging | [`0x21636C226e113d7Dd59dA2987eaA7dAbBE4159c7`](https://etherscan.io/address/0x21636c226e113d7dd59da2987eaa7dabbe4159c7#code) | Immutable vault is the wrapper proxy |
| Underlying | [`0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf`](https://etherscan.io/token/0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf) | Coinbase Wrapped BTC (`cbBTC`), 8 decimals |
| Owner/admin | [`0x349bB895dB64f74AB9788693a16Ee03776195504`](https://etherscan.io/address/0x349bb895db64f74ab9788693a16ee03776195504) | Wrapper owner, beacon owner, virtual `DEFAULT_ADMIN_ROLE` |
| Smart account | [`0x034d1E094Efd47d4e738033d0157f31718820470`](https://etherscan.io/address/0x034d1e094efd47d4e738033d0157f31718820470) | Sole `closeEpoch` and `settleEpoch` authority |

Wrapper metadata:

- Name: `K3 cbBTC Vault`
- Symbol: `k3cbBTC`
- Decimals: 8
- Asset: canonical Ethereum cbBTC

All four project deployment contracts are published on Etherscan as exact source matches. `Staging` is verified with constructor argument `0x009c02a73706a68e0aE0209235408206E4F53709`.

## Deployment transactions

The CREATE3 deployment produced six mainnet transactions. Every receipt has `status = 1`.

The exact generated [`run-1785834040477.json`](../../../broadcast/Deploy.s.sol/1/run-1785834040477.json) artifact is retained with SHA-256 `1eb5ecad499e10649040a7e8ac071605889f36aba1610433ba876f22009f0e88`. The sequence below is normalized from receipt block numbers and transaction indexes; consumers should not infer chronological order from the generated artifact's transaction-array order.

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

The initial operational caveat—privileged addresses had not yet demonstrated control on mainnet—was therefore superseded by the funded/delegated account state and successful end-to-end transactions recorded above.

## Ongoing verification

Before relying on this deployment, recheck at minimum:

```shell
cast call 0x7b80bdb8F0777F52A6054A0E48AFc15200b780B8 "implementation()(address)" --rpc-url "$RPC_URL"
cast call 0x7b80bdb8F0777F52A6054A0E48AFc15200b780B8 "owner()(address)" --rpc-url "$RPC_URL"
cast call 0x009c02a73706a68e0aE0209235408206E4F53709 "owner()(address)" --rpc-url "$RPC_URL"
cast call 0x009c02a73706a68e0aE0209235408206E4F53709 "smartAccount()(address)" --rpc-url "$RPC_URL"
cast call 0x009c02a73706a68e0aE0209235408206E4F53709 "asset()(address)" --rpc-url "$RPC_URL"
```

Future beacon upgrades must be documented as append-only records alongside this deployment. Major accounting or control-flow changes require a fresh audit before production use.
