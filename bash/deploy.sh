#!/bin/bash
# =============================================================================
# Deploy All - Deploys implementation, beacon, and wrapper via CREATE3
# Defaults to dry-run; pass --broadcast to send transactions.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BROADCAST=0
AUTO_YES=0
for arg in "$@"; do
    case "$arg" in
        --broadcast)
            BROADCAST=1
            ;;
        --yes|-y)
            AUTO_YES=1
            ;;
        --help|-h)
            echo "Usage: $0 [--broadcast] [--yes]"
            echo "  default      dry-run deployment only"
            echo "  --broadcast  submit deployment transactions"
            echo "  --yes        skip interactive confirmation (use only in automation)"
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$arg'"
            exit 1
            ;;
    esac
done

# Load environment variables
if [ -f "$SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
elif [ -f "$PROJECT_ROOT/.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/.env"
else
    echo "Error: .env file not found"
    echo "Copy .env.example to .env and fill in your values"
    exit 1
fi

# Validate required variables
REQUIRED_VARS="NETWORK DEPLOYER_ADDRESS DEPLOY_SALT OWNER SMART_ACCOUNT UNDERLYING_TOKEN VAULT_NAME VAULT_SYMBOL"
for var in $REQUIRED_VARS; do
    if [ -z "${!var:-}" ]; then
        echo "Error: $var not set in .env"
        exit 1
    fi
done

MODE="DRY RUN"
if [ "$BROADCAST" -eq 1 ]; then
    MODE="BROADCAST"
fi

if [ "$BROADCAST" -eq 1 ] && [ -z "${CAST_WALLET_ACCOUNT:-}" ] && [ "${ANVIL_UNLOCKED:-}" != "1" ] && [ "${ANVIL_UNLOCKED:-}" != "true" ]; then
    echo "Error: broadcast mode requires CAST_WALLET_ACCOUNT or ANVIL_UNLOCKED=true"
    echo "Use 'cast wallet import <name> --interactive' and set CAST_WALLET_ACCOUNT=<name>."
    exit 1
fi

SIGNER_ARGS=(--sender "$DEPLOYER_ADDRESS")
if [ -n "${CAST_WALLET_ACCOUNT:-}" ]; then
    SIGNER_ARGS+=(--account "$CAST_WALLET_ACCOUNT")
elif [ "${ANVIL_UNLOCKED:-}" = "1" ] || [ "${ANVIL_UNLOCKED:-}" = "true" ]; then
    SIGNER_ARGS+=(--unlocked)
fi

echo "=========================================="
echo "CREATE3 Deployment Preview"
echo "=========================================="
echo "Mode:             $MODE"
echo "Network:          $NETWORK"
echo "Deployer:         $DEPLOYER_ADDRESS"
echo "Signer account:   ${CAST_WALLET_ACCOUNT:-${ANVIL_UNLOCKED:+unlocked}}"
echo "Salt:             $DEPLOY_SALT"
echo ""
echo "Parameters:"
echo "  Owner:            $OWNER"
echo "  Smart Account:    $SMART_ACCOUNT"
echo "  Underlying Token: $UNDERLYING_TOKEN"
echo "  Vault Name:       $VAULT_NAME"
echo "  Vault Symbol:     $VAULT_SYMBOL"
echo "=========================================="
echo ""

cd "$PROJECT_ROOT"

if [ "$BROADCAST" -eq 1 ]; then
    echo "Dry-running deployment before broadcast..."
    set +e
    forge script script/Deploy.s.sol:DeployAll \
        --rpc-url "$NETWORK" \
        "${SIGNER_ARGS[@]}" \
        -vvvv 2>&1 | tee /tmp/erc7540_predict_output.txt
    PREDICT_EXIT=${PIPESTATUS[0]}
    set -e

    if [ "$PREDICT_EXIT" -ne 0 ]; then
        echo ""
        echo "Dry-run preview FAILED. Check output above."
        exit 1
    fi

    echo ""
    echo "=========================================="
    echo ""
fi

if [ "$BROADCAST" -eq 1 ] && [ "$AUTO_YES" -ne 1 ]; then
    read -r -p "Broadcast deployment with these parameters? (y/N) " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled"
        exit 0
    fi
fi

if [ "$BROADCAST" -ne 1 ]; then
    echo "Dry-running deployment. No transaction will be broadcast."
else
    echo "Broadcasting deployment..."
fi

FORGE_ARGS=(script/Deploy.s.sol:DeployAll --rpc-url "$NETWORK" "${SIGNER_ARGS[@]}" -vvvv)
if [ "$BROADCAST" -eq 1 ]; then
    FORGE_ARGS+=(--broadcast)
fi

set +e
forge script "${FORGE_ARGS[@]}" 2>&1 | tee /tmp/erc7540_deploy_output.txt
EXIT_CODE=${PIPESTATUS[0]}
set -e

RESULT=$(cat /tmp/erc7540_deploy_output.txt)

if [ "$EXIT_CODE" -ne 0 ]; then
    echo ""
    echo "=========================================="
    echo "Deployment $MODE FAILED (exit code: $EXIT_CODE)"
    echo "=========================================="
    exit 1
fi

IMPL_ADDR=$(echo "$RESULT" | grep -oE "Implementation: (0x[a-fA-F0-9]{40})" | tail -1 | cut -d' ' -f2)
BEACON_ADDR=$(echo "$RESULT" | grep -oE "Beacon: (0x[a-fA-F0-9]{40})" | tail -1 | cut -d' ' -f2)
WRAPPER_ADDR=$(echo "$RESULT" | grep -oE "Wrapper: (0x[a-fA-F0-9]{40})" | tail -1 | cut -d' ' -f2)

echo ""
echo "=========================================="
echo "Deployment $MODE successful"
echo "=========================================="
if [ -n "$IMPL_ADDR" ] && [ -n "$BEACON_ADDR" ] && [ -n "$WRAPPER_ADDR" ]; then
    echo "Implementation: $IMPL_ADDR"
    echo "Beacon:         $BEACON_ADDR"
    echo "Wrapper:        $WRAPPER_ADDR"
    echo ""
    if [ "$BROADCAST" -eq 1 ]; then
        echo "Add to .env:"
        echo "  BEACON_ADDRESS=$BEACON_ADDR"
        echo "  WRAPPER_ADDRESS=$WRAPPER_ADDR"
        echo ""
        echo "Verify contracts:"
        echo "  ./bash/verify.sh implementation $IMPL_ADDR"
        echo "  ./bash/verify.sh beacon $BEACON_ADDR"
        echo "  ./bash/verify.sh wrapper $WRAPPER_ADDR"
    else
        echo "Dry run only. Re-run with --broadcast to deploy on-chain."
    fi
else
    echo "Check output above for addresses."
fi
echo "=========================================="
