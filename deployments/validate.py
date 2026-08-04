#!/usr/bin/env python3
"""Validate committed deployment manifests and their local evidence."""

from __future__ import annotations

import hashlib
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEPLOYMENTS = ROOT / "deployments"
ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}\Z")
HASH = re.compile(r"0x[0-9a-fA-F]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")


def reject_constant(value: str) -> None:
    raise ValueError(f"non-standard JSON constant: {value}")


def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=reject_duplicates,
        parse_constant=reject_constant,
    )


def require_address(value: str, label: str) -> None:
    if not ADDRESS.fullmatch(value):
        raise ValueError(f"{label} is not an EVM address: {value}")


def require_hash(value: str, label: str) -> None:
    if not HASH.fullmatch(value):
        raise ValueError(f"{label} is not a bytes32 hash: {value}")


def validate_transactions(transactions: list[dict[str, Any]], label: str) -> None:
    if not transactions:
        raise ValueError(f"{label} has no transactions")
    expected_sequence = list(range(1, len(transactions) + 1))
    if [transaction["sequence"] for transaction in transactions] != expected_sequence:
        raise ValueError(f"{label} sequence is not contiguous")
    hashes = [transaction["hash"] for transaction in transactions]
    if len(hashes) != len(set(hashes)):
        raise ValueError(f"{label} contains duplicate transaction hashes")
    for transaction in transactions:
        require_hash(transaction["hash"], f"{label} transaction hash")
        if transaction["status"] != 1:
            raise ValueError(f"{label} contains a non-successful transaction")
    positions = [(transaction["block"], transaction["transactionIndex"]) for transaction in transactions]
    if positions != sorted(positions):
        raise ValueError(f"{label} is not ordered by block and transaction index")


def validate_smoke_test(path: Path, manifest: dict[str, Any]) -> None:
    smoke = load_json(path)
    if smoke["schemaVersion"] != 1 or smoke["evidenceType"] != "mainnet-smoke-test":
        raise ValueError(f"unsupported smoke-test schema: {path}")
    if smoke["status"] != "passed":
        raise ValueError(f"smoke test is not marked passed: {path}")
    if smoke["network"]["chainId"] != manifest["network"]["chainId"]:
        raise ValueError(f"smoke-test chain mismatch: {path}")
    if smoke["wrapper"].lower() != manifest["contracts"]["wrapperProxy"]["address"].lower():
        raise ValueError(f"smoke-test wrapper mismatch: {path}")
    require_address(smoke["wrapper"], "smoke-test wrapper")
    for role, actor in smoke["actors"].items():
        require_address(actor, f"smoke-test actor {role}")
    if smoke["units"]["decimals"] != manifest["vault"]["decimals"]:
        raise ValueError(f"smoke-test unit decimals mismatch: {path}")
    validate_transactions(smoke["transactions"], str(path))
    if smoke["firstBlock"] != smoke["transactions"][0]["block"]:
        raise ValueError(f"smoke-test first block mismatch: {path}")
    if smoke["lastBlock"] != smoke["transactions"][-1]["block"]:
        raise ValueError(f"smoke-test last block mismatch: {path}")
    manifest_smoke = manifest["verification"]["mainnetSmokeTest"]
    if manifest_smoke["transactionCount"] != len(smoke["transactions"]):
        raise ValueError(f"smoke-test transaction count mismatch: {path}")
    if manifest_smoke["firstBlock"] != smoke["firstBlock"] or manifest_smoke["lastBlock"] != smoke["lastBlock"]:
        raise ValueError(f"smoke-test block range mismatch: {path}")
    expected_counts = manifest_smoke["operations"]
    actual_counts = Counter(transaction["method"].split("(", 1)[0] for transaction in smoke["transactions"])
    if dict(actual_counts) != expected_counts:
        raise ValueError(f"smoke-test operation counts mismatch: {path}")


def validate_manifest(path: Path) -> None:
    manifest = load_json(path)
    if manifest["schemaVersion"] != 1:
        raise ValueError(f"unsupported manifest schema: {path}")
    chain_id = manifest["network"]["chainId"]
    wrapper = manifest["contracts"]["wrapperProxy"]["address"]
    if path.parent.parent.name != str(chain_id):
        raise ValueError(f"manifest directory chain mismatch: {path}")
    if path.parent.name.lower() != wrapper.lower():
        raise ValueError(f"manifest directory wrapper mismatch: {path}")
    if not COMMIT.fullmatch(manifest["source"]["commit"]):
        raise ValueError(f"source commit must be a full SHA-1: {path}")

    require_address(manifest["configuration"]["deployer"], "deployer")
    require_address(manifest["configuration"]["owner"], "owner")
    require_address(manifest["configuration"]["smartAccount"], "smart account")
    privileged = manifest["privilegedAccounts"]
    for role in ("owner", "smartAccount"):
        require_address(privileged[role]["address"], f"privileged account {role}")
        if not isinstance(privileged[role]["nonce"], int) or privileged[role]["nonce"] < 0:
            raise ValueError(f"invalid nonce for privileged account {role}")
        if not privileged[role]["balanceWei"].isdigit():
            raise ValueError(f"invalid balance for privileged account {role}")
    if privileged["owner"]["address"].lower() != manifest["configuration"]["owner"].lower():
        raise ValueError(f"privileged owner mismatch: {path}")
    if privileged["smartAccount"]["address"].lower() != manifest["configuration"]["smartAccount"].lower():
        raise ValueError(f"privileged smart-account mismatch: {path}")
    require_hash(privileged["owner"]["runtimeBytecodeKeccak256"], "owner runtime hash")
    require_hash(privileged["smartAccount"]["delegationCodeKeccak256"], "smart-account delegation hash")
    delegation_target = privileged["smartAccount"]["delegationTarget"]
    require_address(delegation_target["address"], "smart-account delegation target")
    require_hash(delegation_target["runtimeBytecodeKeccak256"], "delegation-target runtime hash")
    post_smoke_target = manifest["verification"]["postSmokeState"]["smartAccountDelegationTarget"]
    if delegation_target["address"].lower() != post_smoke_target.lower():
        raise ValueError(f"smart-account delegation-target mismatch: {path}")
    for name, contract in manifest["contracts"].items():
        require_address(contract["address"], f"contract {name}")
    for name, entry in manifest["verification"]["runtimeBytecode"].items():
        require_hash(entry["keccak256"], f"runtime hash {name}")
    for name, entry in manifest["verification"]["proxySlots"].items():
        require_hash(entry["slot"], f"proxy slot {name}")
        require_hash(entry["value"], f"proxy slot value {name}")

    validate_transactions(manifest["deployment"]["transactions"], str(path))

    broadcast = manifest["source"]["foundryBroadcast"]
    broadcast_path = ROOT / broadcast["fileName"]
    if not broadcast_path.is_file():
        raise ValueError(f"missing Foundry broadcast artifact: {broadcast_path}")
    actual_sha256 = hashlib.sha256(broadcast_path.read_bytes()).hexdigest()
    if actual_sha256 != broadcast["sha256"]:
        raise ValueError(f"Foundry broadcast SHA-256 mismatch: {broadcast_path}")
    if broadcast["integrityStatus"] != "known-hash-to-payload-misassociations":
        raise ValueError(f"Foundry artifact integrity caveat missing: {path}")
    misassociations = broadcast["knownHashMisassociations"]
    if len(misassociations) != 4:
        raise ValueError(f"unexpected Foundry hash-misassociation count: {path}")
    deployment_hashes = {transaction["hash"] for transaction in manifest["deployment"]["transactions"]}
    for entry in misassociations:
        require_hash(entry["recordedHash"], "misassociated recorded transaction hash")
        require_hash(entry["correctHash"], "misassociated correct transaction hash")
        if entry["recordedHash"] == entry["correctHash"] or entry["correctHash"] not in deployment_hashes:
            raise ValueError(f"invalid Foundry hash-misassociation entry: {path}")

    documentation = manifest["documentation"]
    for key in ("humanVerificationReport", "smokeTestEvidence", "registryIndex"):
        target = path.parent / documentation[key]
        if not target.is_file():
            raise ValueError(f"missing documentation target {key}: {target}")
    smoke_path = path.parent / documentation["smokeTestEvidence"]
    smoke_sha256 = hashlib.sha256(smoke_path.read_bytes()).hexdigest()
    if smoke_sha256 != manifest["verification"]["mainnetSmokeTest"]["evidenceSha256"]:
        raise ValueError(f"smoke-test SHA-256 mismatch: {smoke_path}")
    validate_smoke_test(smoke_path, manifest)
    print(f"validated {path.relative_to(ROOT)}")


def main() -> None:
    manifests = sorted(DEPLOYMENTS.glob("*/0x*/deployment.json"))
    if not manifests:
        raise SystemExit("no deployment manifests found")
    for manifest in manifests:
        validate_manifest(manifest)


if __name__ == "__main__":
    main()
