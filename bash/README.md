# SmartAccountWrapper Deployment Guide

Step-by-step guide to deploy SmartAccountWrapper contracts using CREATE3 for deterministic addresses across all EVM chains.

## Architecture Overview

```
┌─────────────────────┐
│  UpgradeableBeacon  │ ← Controls all proxies
└──────────┬──────────┘
           │ points to implementation
           ▼
┌─────────────────────┐
│ SmartAccountWrapper │ ← Logic contract (no state)
│   Implementation    │
└─────────────────────┘
           ▲
           │ delegatecall
┌──────────┴──────────┐
│ BeaconProxy         │ ← User-facing wrapper proxy
└─────────────────────┘
```

**Key benefits of CREATE3:**
- Same addresses on all EVM chains with same salt
- Frontrunning protection
- Single transaction deployment (impl + beacon + wrapper)

## Prerequisites

1. **Install Foundry**
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

2. **Install dependencies**
   ```bash
   cd semi-async-vault
   forge install
   ```

3. **Get API keys**
   - RPC URL (Alchemy, Infura, or public)
   - Block explorer API key (Basescan, Arbiscan)

4. **Fund deployer wallet**
   - ~0.015 ETH for full deployment (impl + beacon + wrapper)

## Step 1: Configure Environment

```bash
cd semi-async-vault/bash

# Copy example config
cp .env.example .env

# Edit with your values
nano .env
```

**Required variables:**

| Variable | Description | Example |
|----------|-------------|---------|
| `PRIVATE_KEY` | Deployer private key (no 0x) | `abc123...` |
| `DEPLOY_SALT` | CREATE3 salt (bytes32) | `0x0000...0001` |
| `OWNER` | Admin address (can upgrade) | `0x...` |
| `OPERATOR` | Signs on behalf of wrapper | `0x...` |
| `SMART_ACCOUNT` | Receives deposited assets | `0x...` |
| `UNDERLYING_TOKEN` | ERC20 token (e.g., USDC) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `VAULT_NAME` | ERC20 token name | `MySmartAccountWrapper` |
| `VAULT_SYMBOL` | ERC20 token symbol | `MSAW` |

## Step 2: Preview Addresses

Before deploying, preview the deterministic addresses:

```bash
chmod +x *.sh
./predict.sh
```

**Output:**
```
==========================================
CREATE3 Address Prediction
==========================================
Network: base
Salt:    0x0000000000000000000000000000000000000000000000000000000000000001
==========================================

Predicted addresses:
  Implementation: 0x1234...
  Beacon:         0x5678...
  Wrapper:        0x9abc...

These addresses will be the same on any EVM chain with the same salt.
```

## Step 3: Deploy All Contracts

Deploy implementation, beacon, and wrapper in a single transaction:

```bash
./deploy.sh
```

**Output:**
```
==========================================
CREATE3 Deployment Preview
==========================================
Network:          base
Salt:             0x0000...0001

Parameters:
  Owner:            0x...
  Operator:         0x...
  Smart Account:    0x...
  Underlying Token: 0x...
  Vault Name:       MySmartAccountWrapper
  Vault Symbol:     MSAW
==========================================

Predicting addresses...
  Implementation: 0x1234...
  Beacon:         0x5678...
  Wrapper:        0x9abc...

Deploy with these addresses? (y/N) y

Deployment successful!
==========================================
Implementation: 0x1234...
Beacon:         0x5678...
Wrapper:        0x9abc...
```

**After deployment:**

1. Add to `.env`:
   ```
   BEACON_ADDRESS=0x5678...
   WRAPPER_ADDRESS=0x9abc...
   ```

2. Verify on block explorer:
   ```bash
   ./verify.sh implementation 0x1234...
   ./verify.sh beacon 0x5678...
   ./verify.sh wrapper 0x9abc...
   ```

## Step 4: Deploy on Other Chains

Use the **same salt** to get identical addresses on other chains:

```bash
# Deploy on Arbitrum with same addresses
NETWORK=arbitrum_one ./deploy.sh
```

## Step 5: Upgrade (When Needed)

To upgrade **all** wrapper proxies to a new implementation:

```bash
./upgrade.sh
```

This will:
1. Deploy new SmartAccountWrapper implementation
2. Call `beacon.upgradeTo(newImpl)`
3. Reinitialize wrapper with owner
4. All proxies using this beacon are instantly upgraded

**Important:** Only the beacon `owner` can upgrade.

## Scripts Reference

| Script | Description |
|--------|-------------|
| `predict.sh` | Preview CREATE3 addresses without deploying |
| `deploy.sh` | Deploy impl + beacon + wrapper in one tx |
| `upgrade.sh` | Deploy new impl and upgrade beacon |
| `verify.sh` | Verify contracts on block explorer |

## Verification Commands

```bash
# Verify implementation
./verify.sh implementation 0x...

# Verify beacon
./verify.sh beacon 0x...

# Verify wrapper proxy
./verify.sh wrapper 0x...
```

## Network Configuration

Edit `.env` to change network:

```bash
# Base (default)
NETWORK=base
BASE_RPC_URL=https://mainnet.base.org

# Arbitrum
NETWORK=arbitrum_one
ARBITRUM_ONE_RPC_URL=https://arb1.arbitrum.io/rpc
```

## Troubleshooting

### "DEPLOY_SALT not set"
```bash
# Add a unique salt to .env
DEPLOY_SALT=0x0000000000000000000000000000000000000000000000000000000000000001
```

### "Address already deployed"
CREATE3 addresses are deterministic. If the address is taken:
- Use a different `DEPLOY_SALT`
- Or the contract was already deployed with this salt

### Verification fails
- Wait 30-60 seconds after deployment
- Ensure correct API key in `.env`
- Check compiler version matches (0.8.30)

### Transaction reverts
- Check owner/operator addresses are correct
- Ensure underlying token is valid ERC20
- Verify sufficient gas

## Contract Addresses (Base Mainnet)

| Contract | Address |
|----------|---------|
| Beacon | `0x94062886D060E3a80aaB17951c6E087a153e8AE8` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| ZyFAI Wrapper | `0xf3Cfe4f445a6d4C95e02F9A66eDCFABF9Ea5E7cd` |

## Security Notes

1. **Never commit `.env`** - It contains your private key
2. **Use a fresh deployer wallet** - Don't use your main wallet
3. **Test on testnet first** - Use Base Sepolia before mainnet
4. **Verify owner address** - Only owner can upgrade beacon
5. **Operator trust** - Operator has signing authority via ERC-1271
6. **Salt uniqueness** - Use unique salt per deployment to avoid collisions
