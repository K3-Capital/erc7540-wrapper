# SmartAccountWrapper

Epoch-staged ERC-7540/ERC-4626 wrapper for a manually managed smart account/Safe.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the as-built architecture, accounting model, trust assumptions, and audit-facing design notes.

The current contracts implement a fully asynchronous request -> epoch close -> settlement -> claim flow:

- `requestDeposit` stages assets in `Staging` and records the request for the current epoch.
- `requestRedeem` stages shares in `Staging` and records the request for the current epoch.
- the configured smart account closes and settles one frozen epoch at a time with a NAV snapshot.
- users or approved ERC-7540 operators claim settled shares/assets through the ERC-4626 `deposit`, `mint`, `withdraw`, and `redeem` claim functions.

## Deployment status

There are **no documented production deployments of the current epoch-staged ERC-7540 code in this repository**.

Older addresses that previously appeared in this README were deployed from an earlier implementation and should not be treated as instances of the current contracts. They intentionally are not listed here to avoid confusing integrators or auditors.

Before publishing any new deployment address, verify that:

1. the deployed implementation bytecode matches the current audited commit;
2. the beacon points to that implementation;
3. the wrapper proxy is initialized with the intended owner, smart account, asset, name, and symbol;
4. the deployment has been verified on the target chain block explorer;
5. the deployment has gone through the required security review for this code version.

## Architecture

```text
Users / Operators
      │
      │ requestDeposit / requestRedeem
      ▼
SmartAccountWrapper ─────► Staging
      │                     │
      │ closeEpoch          │ staged assets / staged shares / redeem reserves
      │ settleEpoch         │
      ▼                     │
Smart account / Safe ◄─────┘
      │
      │ off-chain strategies + NAV calculation
      ▼
Settlement + user claims
```

The wrapper is upgradeable through an `UpgradeableBeacon`; all beacon upgrade authority belongs to the configured owner.

## Licensing

This repository uses mixed licensing on a file-by-file basis:

- files marked `SPDX-License-Identifier: BUSL-1.1` are K3-owned code licensed under the Business Source License 1.1 terms in [`LICENSE.md`](LICENSE.md), based on the license form used by Euler Vault Kit;
- files marked `SPDX-License-Identifier: MIT` remain under the MIT license, including lightly modified upstream-derived Solidity and deployment helper files; and
- third-party dependencies under `lib/` remain under their own licenses.

See [`LICENSE.md`](LICENSE.md), [`LICENSE-MIT.md`](LICENSE-MIT.md), and [`NOTICE.md`](NOTICE.md) for the controlling license terms and file classification notes.

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Contract size check

```shell
forge build --sizes
```

## Deployment tooling

Deployment helpers live under `script/` and `bash/`.

- `bash/predict.sh` dry-runs `DeployAll` and prints the addresses the current script path would deploy.
- `script/Deploy.s.sol:DeployAll` deploys implementation, beacon, and wrapper proxy.
- `script/Upgrade.s.sol:Upgrade` deploys a new implementation and upgrades an existing beacon.
- `bash/*.sh` wrap those scripts with environment loading, previews, and block-explorer verification helpers.

The bash wrappers default to **dry-run mode**. Pass `--broadcast` only when the previewed parameters and addresses are ready to submit on-chain.

See [`bash/README.md`](bash/README.md) for the deployment runbook.

## Required deployment environment

Copy `.env.example` to `.env` and fill in values for the target chain. At minimum:

- `CAST_WALLET_ACCOUNT` — Foundry/cast wallet account name created with `cast wallet import <name> --interactive`.
- `DEPLOYER_ADDRESS` — public address for that wallet. Do not store plaintext private keys in `.env`.
- `BEACON_OWNER_WALLET_ACCOUNT` / `BEACON_OWNER` — Foundry/cast wallet account and public address for the beacon owner/admin used by upgrade broadcasts.
- `DEPLOY_SALT` — bytes32 CREATE3 salt.
- `OWNER` — owner/admin address for wrapper and beacon.
- `SMART_ACCOUNT` — smart account/Safe allowed to close and settle epochs.
- `UNDERLYING_TOKEN` — ERC-20 asset.
- `VAULT_NAME` / `VAULT_SYMBOL` — ERC-20 metadata for the vault share token.
- `RPC_URL` — RPC endpoint for deployment previews, broadcasts, and upgrades.
- `NETWORK` — block explorer chain name for verification, such as `mainnet` or `sepolia`.
- chain RPC and block explorer API keys as needed.

Request helper scripts require `REQUEST_OWNER_WALLET_ACCOUNT` / `REQUEST_OWNER` and optionally `REQUEST_CONTROLLER` so deposits/redeems are broadcast by the account that owns the assets/shares or an explicitly configured operator path.

## Security notes

- The smart account/Safe is trusted to provide correct NAV snapshots and settlement funding.
- The current accounting assumes a standard non-rebasing, no-transfer-fee ERC-20 underlying.
- Rounding dust follows the behavior documented in tests and architecture docs: per-epoch claim residuals are assigned to the final claimant for that epoch/side so no shares or assets remain stranded in `Staging`.
- Owner, beacon, and smart-account privileges are high-trust controls.
- Pause blocks new `requestDeposit` and `requestRedeem` calls only. The configured smart account may still close/settle epochs, and users/operators may still claim already-settled shares/assets; `maxDeposit`, `maxMint`, `maxWithdraw`, and `maxRedeem` continue to report claimable amounts while paused.
- Major accounting/control-flow changes require a fresh audit before production use.
