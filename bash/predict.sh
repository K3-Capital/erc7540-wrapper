#!/bin/bash
# =============================================================================
# Predict Addresses - Preview CREATE3 addresses without deploying
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load environment variables
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

if [ -z "$DEPLOY_SALT" ]; then
    echo "Error: DEPLOY_SALT not set in .env"
    exit 1
fi

NETWORK=${NETWORK:-base}

echo "=========================================="
echo "CREATE3 Address Prediction"
echo "=========================================="
echo "Network: $NETWORK"
echo "Salt:    $DEPLOY_SALT"
echo "=========================================="
echo ""

cd "$PROJECT_ROOT"
set +e
forge script script/Deploy.s.sol:PredictAddresses --rpc-url "$NETWORK" 2>&1 | tee /tmp/predict_output.txt
EXIT_CODE=${PIPESTATUS[0]}
set -e

if [ "$EXIT_CODE" -ne 0 ]; then
    echo ""
    echo "Prediction FAILED (exit code: $EXIT_CODE)"
    exit 1
fi

grep -E "(Predicted|Implementation|Beacon|Wrapper|Salt):" /tmp/predict_output.txt || true

echo ""
echo "These addresses will be the same on any EVM chain with the same salt."
