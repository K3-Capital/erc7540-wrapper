#!/bin/bash
# =============================================================================
# Preview Deployment - dry-runs DeployAll and prints the addresses it would deploy
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
elif [ -f "$PROJECT_ROOT/.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.env"
else
    echo "Error: .env file not found"
    exit 1
fi

REQUIRED_VARS="DEPLOYER_ADDRESS DEPLOY_SALT OWNER SMART_ACCOUNT UNDERLYING_TOKEN VAULT_NAME VAULT_SYMBOL"
for var in $REQUIRED_VARS; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var not set in .env"
        exit 1
    fi
done

NETWORK=${NETWORK:-base}

echo "=========================================="
echo "CREATE3 Deployment Dry-Run Preview"
echo "=========================================="
echo "Network:          $NETWORK"
echo "Deployer:         $DEPLOYER_ADDRESS"
echo "Salt:             $DEPLOY_SALT"
echo "Owner:            $OWNER"
echo "Smart Account:    $SMART_ACCOUNT"
echo "Underlying Token: $UNDERLYING_TOKEN"
echo "Vault Name:       $VAULT_NAME"
echo "Vault Symbol:     $VAULT_SYMBOL"
echo "=========================================="
echo ""

cd "$PROJECT_ROOT"
set +e
forge script script/Deploy.s.sol:DeployAll \
    --rpc-url "$NETWORK" \
    --sender "$DEPLOYER_ADDRESS" \
    -vvvv 2>&1 | tee /tmp/erc7540_predict_output.txt
EXIT_CODE=${PIPESTATUS[0]}
set -e

if [ "$EXIT_CODE" -ne 0 ]; then
    echo ""
    echo "Preview FAILED (exit code: $EXIT_CODE)"
    exit 1
fi

echo ""
echo "Preview complete. No transaction was broadcast."
