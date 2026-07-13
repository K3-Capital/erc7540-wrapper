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

### ERC-1271 support

`SmartAccountWrapper` does not implement ERC-1271 signature validation in the current version. The core ERC-7540/ERC-4626 flow does not use contract signatures: user requests and claims are direct token/vault calls, and settlement authority is enforced by `msg.sender == smartAccount()` for `closeEpoch` and `settleEpoch`.

If a future integration needs the wrapper itself to act as a contract-wallet-style signing identity, ERC-1271 can be added in an implementation upgrade with an explicit signer domain.

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

## Authorization controls

ERC-7540 separates the account that owns assets/shares (`owner`), the account that controls the pending request and later claim (`controller`), and the caller submitting the transaction. Operator approvals are scoped to a controller via `setOperator(operator, approved)`; they are not transitive across unrelated controllers.

Request authorization follows these rules:

| Flow | Allowed controller routing |
|---|---|
| `requestDeposit(assets, controller, owner)` with `msg.sender == owner` | The owner may deposit into `controller == owner`, or into a different `controller` only if that controller approved the owner/caller as operator. |
| `requestDeposit(assets, controller, owner)` with `msg.sender != owner` | The caller must be an operator for `owner`, and the request must use `controller == owner`. The operator cannot pull the owner's assets into another controller bucket. |
| `requestRedeem(shares, controller, owner)` with `msg.sender == owner` | The owner may redeem into `controller == owner`, or into a different `controller` only if that controller approved the owner/caller as operator. |
| `requestRedeem(shares, controller, owner)` with `msg.sender != owner` | The request must use `controller == owner`. The caller must either be an operator for `owner` or spend ERC-20 share allowance from `owner`; neither path can redirect the pending redeem claim to another controller. |

The ERC-20 share-allowance branch for `requestRedeem` is preserved for ERC-7540 compatibility. ERC-7540 describes redeem-request approval for `msg.sender != owner` as coming either from ERC-20 approval over the owner's shares or from owner/controller operator approval. Removing the allowance path would make integrations that use ordinary ERC-20 share approvals unable to request asynchronous redeems on behalf of the owner; they would need users to call `setOperator` instead.

Claim authorization is controller-scoped: `deposit`, `mint`, `withdraw`, and `redeem` claims with a `controller` parameter may be called only by the controller itself or by an operator approved by that controller. The caller may choose any output `receiver`, but only after satisfying that controller authorization.

These rules intentionally avoid inferring owner consent from two independent approvals. For example, if an owner approves an operator and an unrelated controller also approves the same operator, the operator still cannot pull the owner's assets/shares into that unrelated controller's request bucket. Supporting third-party owner-funded requests to another controller would require a separate explicit authorization that names both the owner and the destination controller.

## Security notes

- The smart account/Safe is trusted to provide correct NAV snapshots and settlement funding.
- The current accounting assumes a standard non-rebasing, no-transfer-fee ERC-20 underlying.
- Rounding dust follows the behavior documented in tests and architecture docs: per-epoch claim residuals are assigned to the final claimant for that epoch/side so no shares or assets remain stranded in `Staging`. In extreme dust cases, a non-final claim can round to zero output; claiming its entire remaining input intentionally burns/consumes that dust claim and advances the controller's epoch queue. Partial zero-output claims remain queued until their remaining input is consumed.
- Share allowance for `requestRedeem` authorizes a non-owner caller to lock the owner's shares into the owner's own controller bucket only. It does not authorize redirecting the pending redeem claim to a different controller.
- Owner, beacon, and smart-account privileges are high-trust controls.
- While an epoch is frozen, underlying-asset rescue and smart-account rotation are blocked so settlement prefunds cannot be redirected before reserve accounting is booked. Rescue of unrelated tokens remains available.
- Pause blocks new `requestDeposit` and `requestRedeem` calls only. The configured smart account may still close/settle epochs, and users/operators may still claim already-settled shares/assets; `maxDeposit`, `maxMint`, `maxWithdraw`, and `maxRedeem` continue to report claimable amounts while paused.
- Major accounting/control-flow changes require a fresh audit before production use.
