#!/bin/bash
# =============================================================================
# Verify Contracts on Block Explorer
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
fi

NETWORK=${NETWORK:-}
ETHERSCAN_API_KEY=${ETHERSCAN_API_KEY:-}
CONTRACT_TYPE=${1:-}
CONTRACT_ADDRESS=${2:-}

usage() {
    echo "Usage: $0 <contract_type> <address>"
    echo ""
    echo "Contract types:"
    echo "  beacon         - UpgradeableBeacon contract"
    echo "  implementation - SmartAccountWrapper implementation"
    echo "  wrapper        - SmartAccountWrapper proxy"
    echo ""
    echo "Examples:"
    echo "  $0 beacon 0x..."
    echo "  $0 implementation 0x..."
    echo "  $0 wrapper 0x..."
    exit 1
}

if [ -z "$CONTRACT_TYPE" ] || [ -z "$CONTRACT_ADDRESS" ]; then
    usage
fi

if [ -z "$NETWORK" ]; then
    echo "Error: NETWORK not set in .env"
    exit 1
fi


cd "$PROJECT_ROOT"

if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo "Warning: ETHERSCAN_API_KEY is not set; verification may fail"
fi

echo "=========================================="
echo "Verifying Contract"
echo "=========================================="
echo "Network:  $NETWORK"
echo "Type:     $CONTRACT_TYPE"
echo "Address:  $CONTRACT_ADDRESS"
echo "=========================================="
echo ""

case $CONTRACT_TYPE in
    beacon)
        echo "Verifying UpgradeableBeacon..."
        forge verify-contract "$CONTRACT_ADDRESS" \
            lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon \
            --chain "$NETWORK" \
            --verifier etherscan \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch
        ;;

    implementation)
        echo "Verifying SmartAccountWrapper implementation..."
        forge verify-contract "$CONTRACT_ADDRESS" \
            src/SmartAccountWrapper.sol:SmartAccountWrapper \
            --chain "$NETWORK" \
            --verifier etherscan \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch
        ;;

    wrapper)
        echo "Verifying BeaconProxy (wrapper)..."
        forge verify-contract "$CONTRACT_ADDRESS" \
            lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol:BeaconProxy \
            --chain "$NETWORK" \
            --verifier etherscan \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch
        ;;

    *)
        echo "Error: Unknown contract type '$CONTRACT_TYPE'"
        usage
        ;;
esac

echo ""
echo "Verification submitted. Check block explorer for status."
