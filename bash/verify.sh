#!/bin/bash
# =============================================================================
# Verify Contracts on Block Explorer
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load environment variables
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
elif [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
fi

NETWORK=${NETWORK:-base}
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
    echo "  $0 beacon 0x94062886D060E3a80aaB17951c6E087a153e8AE8"
    echo "  $0 implementation 0x..."
    echo "  $0 wrapper 0xf3Cfe4f445a6d4C95e02F9A66eDCFABF9Ea5E7cd"
    exit 1
}

if [ -z "$CONTRACT_TYPE" ] || [ -z "$CONTRACT_ADDRESS" ]; then
    usage
fi

cd "$PROJECT_ROOT"

# Set chain and API key based on network
case $NETWORK in
    base)
        CHAIN="base"
        ETHERSCAN_API_KEY=${BASESCAN_API_KEY:-}
        ;;
    arbitrum_one)
        CHAIN="arbitrum"
        ETHERSCAN_API_KEY=${ARBISCAN_API_KEY:-}
        ;;
    *)
        echo "Error: Unsupported network $NETWORK"
        exit 1
        ;;
esac

if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo "Warning: No API key set for $NETWORK verification"
    echo "Set BASESCAN_API_KEY or ARBISCAN_API_KEY in .env"
fi

echo "=========================================="
echo "Verifying Contract"
echo "=========================================="
echo "Network:  $NETWORK"
echo "Chain:    $CHAIN"
echo "Type:     $CONTRACT_TYPE"
echo "Address:  $CONTRACT_ADDRESS"
echo "=========================================="
echo ""

case $CONTRACT_TYPE in
    beacon)
        echo "Verifying UpgradeableBeacon..."
        forge verify-contract "$CONTRACT_ADDRESS" \
            lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon \
            --chain "$CHAIN" \
            --verifier etherscan \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch
        ;;

    implementation)
        echo "Verifying SmartAccountWrapper implementation..."
        forge verify-contract "$CONTRACT_ADDRESS" \
            src/SmartAccountWrapper.sol:SmartAccountWrapper \
            --chain "$CHAIN" \
            --verifier etherscan \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --watch
        ;;

    wrapper)
        echo "Verifying BeaconProxy (wrapper)..."
        forge verify-contract "$CONTRACT_ADDRESS" \
            lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol:BeaconProxy \
            --chain "$CHAIN" \
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
