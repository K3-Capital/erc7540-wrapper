# SmartAccountWrapper Deployment Runbook

This directory contains thin bash wrappers around the Foundry deployment scripts.

> Current status: this repository does not document any production deployment of the current epoch-staged ERC-7540 implementation. Historical addresses from earlier implementations must not be reused as references for this code.

## Scripts

| Script | Purpose | Default behavior |
| --- | --- | --- |
| `predict.sh` | Dry-run `DeployAll` and preview deployed addresses | read-only |
| `deploy.sh` | Deploy implementation, beacon, and wrapper proxy | dry-run unless `--broadcast` is passed |
| `upgrade.sh` | Deploy a new implementation and upgrade an existing beacon | dry-run unless `--broadcast` is passed |
| `verify.sh` | Submit block-explorer verification | submits verification request |

## Configuration

From the repository root:

```bash
cp .env.example .env
$EDITOR .env
```

Required deployment variables:

| Variable | Description |
| --- | --- |
| `CAST_WALLET_ACCOUNT` | Foundry/cast encrypted wallet account name, e.g. `deployer`. |
| `DEPLOYER_ADDRESS` | Public address of the deployer/upgrader account. |
| `DEPLOY_SALT` | bytes32 CREATE3 salt for implementation/beacon/wrapper addresses. |
| `OWNER` | Owner/admin for the beacon and wrapper. Usually a Safe. |
| `SMART_ACCOUNT` | Smart account/Safe authorized to close and settle epochs. |
| `UNDERLYING_TOKEN` | ERC-20 asset used by this wrapper. |
| `VAULT_NAME` | ERC-20 name for wrapper shares. |
| `VAULT_SYMBOL` | ERC-20 symbol for wrapper shares. |
| `RPC_URL` | RPC endpoint used by deployment, preview, and upgrade scripts. |

Optional post-deployment variables:

| Variable | Description |
| --- | --- |
| `BEACON_ADDRESS` | Existing beacon to upgrade or verify. |
| `WRAPPER_ADDRESS` | Existing wrapper proxy to record/verify. |
| `NETWORK` | Block explorer chain name used by `forge verify-contract --chain`, e.g. `mainnet` or `sepolia`. |
| `ETHERSCAN_API_KEY` | Block explorer API key used by `forge verify-contract`. |


Create the deployer account in Foundry's encrypted keystore instead of writing a plaintext private key to `.env`:

```bash
cast wallet import deployer --interactive
```

Set `CAST_WALLET_ACCOUNT=deployer` and `DEPLOYER_ADDRESS=0x...` in `.env`. Foundry will prompt for the keystore password when `--broadcast` is used. For local Anvil-only testing, set `ANVIL_UNLOCKED=true` and `DEPLOYER_ADDRESS` to one of Anvil's unlocked accounts instead of using a cast wallet account.

## Preview deployment addresses

```bash
./bash/predict.sh
```

This runs the real `DeployAll` script in dry-run mode and does not send transactions.

## Deploy

Always dry-run first:

```bash
./bash/deploy.sh
```

If the dry-run output and deployment addresses are correct, broadcast explicitly:

```bash
./bash/deploy.sh --broadcast
```

Use `--yes` only in automation after another process has validated the parameters:

```bash
./bash/deploy.sh --broadcast --yes
```

After a successful broadcast, record the emitted addresses in `.env`:

```bash
BEACON_ADDRESS=0x...
WRAPPER_ADDRESS=0x...
```

Then verify:

```bash
./bash/verify.sh implementation 0x...
./bash/verify.sh beacon 0x...
./bash/verify.sh wrapper 0x...
```

## Upgrade

Dry-run first:

```bash
./bash/upgrade.sh
```

Broadcast only after reviewing the target beacon and signer:

```bash
./bash/upgrade.sh --broadcast
```

The upgrade script deploys a fresh `SmartAccountWrapper` implementation and calls `UpgradeableBeacon.upgradeTo(newImplementation)`. It does **not** reinitialize existing proxies.

## Safety checklist before broadcasting

- Confirm the selected `RPC_URL` and verification `NETWORK`.
- Confirm the cast wallet account or Anvil unlocked `DEPLOYER_ADDRESS` is authorized for the action.
- Confirm `OWNER`, `SMART_ACCOUNT`, `UNDERLYING_TOKEN`, `VAULT_NAME`, and `VAULT_SYMBOL`.
- Confirm dry-run deployment addresses are new/expected.
- For upgrades, confirm the beacon currently belongs to the intended deployment.
- Run `forge test` and `forge build --sizes` on the exact commit being deployed.
- Ensure the exact commit has received the required audit/security review.

## Notes

- CREATE3 gives deterministic addresses for the same deployer and salt. Changing deployer or salt changes the addresses.
- The smart account/Safe is the only account allowed to close and settle epochs.
- Do not use addresses from older deployments as evidence that the current contracts are deployed.
