#!/bin/bash
# =============================================================================
# Upgrade Beacon - Deploys a new implementation and upgrades all beacon proxies
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
            echo "  default      dry-run upgrade only"
            echo "  --broadcast  submit upgrade transaction"
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
    exit 1
fi

REQUIRED_VARS="NETWORK DEPLOYER_ADDRESS BEACON_ADDRESS OWNER"
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
echo "Beacon Implementation Upgrade"
echo "=========================================="
echo "Mode:    $MODE"
echo "Network: $NETWORK"
echo "Deployer: $DEPLOYER_ADDRESS"
echo "Signer:  ${CAST_WALLET_ACCOUNT:-${ANVIL_UNLOCKED:+unlocked}}"
echo "Beacon:  $BEACON_ADDRESS"
echo "Owner:   $OWNER"
if [ -n "${WRAPPER_ADDRESS:-}" ]; then
    echo "Wrapper: $WRAPPER_ADDRESS"
fi
echo "=========================================="
echo ""
echo "This will:"
echo "  1. Deploy a new SmartAccountWrapper implementation"
echo "  2. Call UpgradeableBeacon.upgradeTo(newImplementation)"
echo "  3. Upgrade every proxy that uses this beacon"
echo ""
echo "It will NOT reinitialize existing wrapper proxies."
echo ""

if [ "$BROADCAST" -eq 1 ] && [ "$AUTO_YES" -ne 1 ]; then
    read -r -p "Broadcast upgrade for this beacon? (y/N) " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Upgrade cancelled"
        exit 0
    fi
fi

cd "$PROJECT_ROOT"

if [ "$BROADCAST" -ne 1 ]; then
    echo "Dry-running upgrade. No transaction will be broadcast."
else
    echo "Broadcasting upgrade..."
fi

FORGE_ARGS=(script/Upgrade.s.sol:Upgrade --rpc-url "$NETWORK" "${SIGNER_ARGS[@]}" -vvvv)
if [ "$BROADCAST" -eq 1 ]; then
    FORGE_ARGS+=(--broadcast)
fi

set +e
forge script "${FORGE_ARGS[@]}" 2>&1 | tee /tmp/erc7540_upgrade_output.txt
EXIT_CODE=${PIPESTATUS[0]}
set -e

RESULT=$(cat /tmp/erc7540_upgrade_output.txt)

if [ "$EXIT_CODE" -ne 0 ]; then
    echo ""
    echo "=========================================="
    echo "Upgrade $MODE FAILED (exit code: $EXIT_CODE)"
    echo "=========================================="
    exit 1
fi

NEW_IMPL=$(echo "$RESULT" | grep -oE "new SmartAccountWrapper@(0x[a-fA-F0-9]{40})" | head -1 | cut -d'@' -f2)

echo ""
echo "=========================================="
echo "Upgrade $MODE successful"
echo "=========================================="
if [ -n "$NEW_IMPL" ]; then
    echo "New Implementation: $NEW_IMPL"
    if [ "$BROADCAST" -eq 1 ]; then
        echo ""
        echo "All proxies using beacon $BEACON_ADDRESS now point to the new implementation."
        echo "Verify:"
        echo "  ./bash/verify.sh implementation $NEW_IMPL"
    else
        echo "Dry run only. Re-run with --broadcast to upgrade on-chain."
    fi
else
    echo "Check output above for implementation address."
fi
echo "=========================================="
