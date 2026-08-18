#!/usr/bin/env python3
"""Validate committed deployment manifests and their local evidence."""

from __future__ import annotations

import hashlib
import json
import re
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEPLOYMENTS = ROOT / "deployments"
ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}\Z")
HASH = re.compile(r"0x[0-9a-fA-F]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
DECIMAL = re.compile(r"(?:0|[1-9][0-9]*)\Z")
CANONICAL_TIMESTAMP = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
SMOKE_DOCUMENT_FIELDS = {
    "schemaVersion",
    "evidenceType",
    "network",
    "wrapper",
    "actors",
    "units",
    "status",
    "firstBlock",
    "lastBlock",
    "transactions",
}
SMOKE_TRANSACTION_FIELDS = {
    "sequence",
    "hash",
    "block",
    "transactionIndex",
    "timestamp",
    "status",
    "sender",
    "method",
    "arguments",
    "gasUsed",
}
DEPLOYMENT_TRANSACTION_FIELDS = {
    "sequence",
    "purpose",
    "hash",
    "block",
    "transactionIndex",
    "status",
    "gasUsed",
}
MANIFEST_SMOKE_FIELDS = {
    "status",
    "transactionCount",
    "firstBlock",
    "lastBlock",
    "evidenceFile",
    "evidenceSha256",
    "operations",
    "transactionList",
}

SMOKE_METHODS = {
    "requestDeposit(uint256,address,address)": (
        "testAccount",
        {"assets": "uint256", "controller": "address", "owner": "address"},
    ),
    "deposit(uint256,address,address)": (
        "testAccount",
        {"assets": "uint256", "receiver": "address", "controller": "address"},
    ),
    "requestRedeem(uint256,address,address)": (
        "testAccount",
        {"shares": "uint256", "controller": "address", "owner": "address"},
    ),
    "redeem(uint256,address,address)": (
        "testAccount",
        {"shares": "uint256", "receiver": "address", "controller": "address"},
    ),
    "closeEpoch()": ("smartAccount", {}),
    "settleEpoch(uint40,uint256)": (
        "smartAccount",
        {"epochId": "uint40", "navSnapshot": "uint256"},
    ),
}


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
    result = json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=reject_duplicates,
        parse_constant=reject_constant,
    )
    if type(result) is not dict:
        raise ValueError(f"JSON document must be an object: {path}")
    return result


def require_int(value: Any, label: str, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        raise ValueError(f"{label} must be an integer >= {minimum}: {value!r}")
    return value


def require_string(value: Any, label: str) -> str:
    if type(value) is not str or not value:
        raise ValueError(f"{label} must be a non-empty string: {value!r}")
    return value


def require_fields(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if type(value) is not dict or set(value) != expected:
        raise ValueError(f"{label} fields must be exactly {sorted(expected)}")
    return value


def require_address(value: Any, label: str) -> None:
    if type(value) is not str or not ADDRESS.fullmatch(value):
        raise ValueError(f"{label} is not an EVM address: {value}")


def require_hash(value: Any, label: str) -> None:
    if type(value) is not str or not HASH.fullmatch(value):
        raise ValueError(f"{label} is not a bytes32 hash: {value}")


def require_sha256(value: Any, label: str) -> None:
    if type(value) is not str or not SHA256.fullmatch(value):
        raise ValueError(f"{label} is not a lowercase SHA-256 digest: {value}")


def resolve_local_path(base: Path, reference: Any, root: Path, label: str) -> Path:
    value = require_string(reference, label)
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"{label} must be a traversal-free relative path: {value}")
    target = (base / relative).resolve()
    try:
        target.relative_to(root.resolve())
    except ValueError as exc:
        raise ValueError(f"{label} escapes {root}: {value}") from exc
    return target


def validate_argument(value: Any, kind: str, label: str) -> None:
    if kind == "address":
        require_address(value, label)
        return
    if type(value) is not str or not DECIMAL.fullmatch(value):
        raise ValueError(f"{label} must be an unsigned decimal string: {value!r}")
    number = int(value)
    bit_width = 40 if kind == "uint40" else 256
    if number >= 1 << bit_width:
        raise ValueError(f"{label} exceeds {kind}: {value}")


def validate_transactions(
    transactions: Any,
    label: str,
    smoke_actors: dict[str, str] | None = None,
) -> None:
    if type(transactions) is not list or not transactions:
        raise ValueError(f"{label} has no transactions")
    hashes: list[str] = []
    positions: list[tuple[int, int]] = []
    timestamps: list[datetime] = []
    for expected_sequence, transaction in enumerate(transactions, start=1):
        expected_fields = SMOKE_TRANSACTION_FIELDS if smoke_actors is not None else DEPLOYMENT_TRANSACTION_FIELDS
        transaction = require_fields(
            transaction,
            expected_fields,
            f"{label} transaction {expected_sequence}",
        )
        if require_int(transaction["sequence"], f"{label} sequence", 1) != expected_sequence:
            raise ValueError(f"{label} sequence is not contiguous")
        require_hash(transaction["hash"], f"{label} transaction hash")
        hashes.append(transaction["hash"])
        block = require_int(transaction["block"], f"{label} block", 1)
        index = require_int(transaction["transactionIndex"], f"{label} transaction index")
        positions.append((block, index))
        if require_int(transaction["status"], f"{label} status") != 1:
            raise ValueError(f"{label} contains a non-successful transaction")
        require_int(transaction["gasUsed"], f"{label} gas used", 1)
        if smoke_actors is not None:
            require_address(transaction["sender"], f"{label} sender")
            method = require_string(transaction["method"], f"{label} method")
            if method not in SMOKE_METHODS:
                raise ValueError(f"{label} has unsupported method: {method}")
            actor_role, argument_schema = SMOKE_METHODS[method]
            if transaction["sender"].lower() != smoke_actors[actor_role].lower():
                raise ValueError(f"{label} sender does not match {actor_role}: {method}")
            arguments = transaction["arguments"]
            if type(arguments) is not dict or set(arguments) != set(argument_schema):
                raise ValueError(f"{label} argument schema mismatch: {method}")
            for name, kind in argument_schema.items():
                validate_argument(arguments[name], kind, f"{label} argument {name}")
            timestamp = require_string(transaction["timestamp"], f"{label} timestamp")
            if not CANONICAL_TIMESTAMP.fullmatch(timestamp):
                raise ValueError(f"{label} has non-canonical UTC timestamp: {timestamp}")
            try:
                timestamps.append(datetime.strptime(timestamp, TIMESTAMP_FORMAT))
            except ValueError as exc:
                raise ValueError(f"{label} has invalid UTC timestamp: {timestamp}") from exc
        else:
            require_string(transaction["purpose"], f"{label} transaction purpose")

    if len(hashes) != len(set(hashes)):
        raise ValueError(f"{label} contains duplicate transaction hashes")
    if len(positions) != len(set(positions)):
        raise ValueError(f"{label} contains duplicate transaction positions")
    if positions != sorted(positions):
        raise ValueError(f"{label} is not ordered by block and transaction index")
    if timestamps and timestamps != sorted(timestamps):
        raise ValueError(f"{label} timestamps are not chronological")


def validate_smoke_test(path: Path, manifest: dict[str, Any]) -> None:
    smoke = require_fields(load_json(path), SMOKE_DOCUMENT_FIELDS, "smoke-test document")
    if require_int(smoke["schemaVersion"], "smoke-test schema version", 1) != 1:
        raise ValueError(f"unsupported smoke-test schema: {path}")
    if require_string(smoke["evidenceType"], "smoke-test evidence type") != "mainnet-smoke-test":
        raise ValueError(f"unsupported smoke-test schema: {path}")
    if require_string(smoke["status"], "smoke-test status") != "passed":
        raise ValueError(f"smoke test is not marked passed: {path}")
    network = require_fields(smoke["network"], {"name", "chainId"}, "smoke-test network")
    network_name = require_string(network["name"], "smoke-test network name")
    if network_name != manifest["network"]["name"]:
        raise ValueError(f"smoke-test network name mismatch: {path}")
    chain_id = require_int(network["chainId"], "smoke-test chain ID", 1)
    if chain_id != manifest["network"]["chainId"]:
        raise ValueError(f"smoke-test chain mismatch: {path}")
    require_address(smoke["wrapper"], "smoke-test wrapper")
    if smoke["wrapper"].lower() != manifest["contracts"]["wrapperProxy"]["address"].lower():
        raise ValueError(f"smoke-test wrapper mismatch: {path}")
    actors = require_fields(smoke["actors"], {"testAccount", "smartAccount"}, "smoke-test actors")
    for role, actor in actors.items():
        require_address(actor, f"smoke-test actor {role}")
    units = require_fields(
        smoke["units"],
        {"assets", "shares", "navSnapshot", "decimals"},
        "smoke-test units",
    )
    for unit in ("assets", "shares", "navSnapshot"):
        require_string(units[unit], f"smoke-test unit {unit}")
    if require_int(units["decimals"], "smoke-test unit decimals") != manifest["vault"]["decimals"]:
        raise ValueError(f"smoke-test unit decimals mismatch: {path}")
    validate_transactions(smoke["transactions"], str(path), actors)
    first_block = require_int(smoke["firstBlock"], "smoke-test first block", 1)
    last_block = require_int(smoke["lastBlock"], "smoke-test last block", 1)
    if first_block != smoke["transactions"][0]["block"]:
        raise ValueError(f"smoke-test first block mismatch: {path}")
    if last_block != smoke["transactions"][-1]["block"]:
        raise ValueError(f"smoke-test last block mismatch: {path}")
    manifest_smoke = require_fields(
        manifest["verification"]["mainnetSmokeTest"],
        MANIFEST_SMOKE_FIELDS,
        "manifest smoke-test record",
    )
    if require_string(manifest_smoke["status"], "manifest smoke-test status") != "passed":
        raise ValueError(f"manifest smoke test is not marked passed: {path}")
    require_string(manifest_smoke["evidenceFile"], "manifest smoke-test evidence filename")
    require_sha256(manifest_smoke["evidenceSha256"], "manifest smoke-test evidence SHA-256")
    require_string(manifest_smoke["transactionList"], "manifest smoke-test transaction list")
    count = require_int(manifest_smoke["transactionCount"], "manifest smoke-test transaction count", 1)
    if count != len(smoke["transactions"]):
        raise ValueError(f"smoke-test transaction count mismatch: {path}")
    manifest_first = require_int(manifest_smoke["firstBlock"], "manifest smoke-test first block", 1)
    manifest_last = require_int(manifest_smoke["lastBlock"], "manifest smoke-test last block", 1)
    if manifest_first != first_block or manifest_last != last_block:
        raise ValueError(f"smoke-test block range mismatch: {path}")
    expected_counts = manifest_smoke["operations"]
    if type(expected_counts) is not dict:
        raise ValueError(f"manifest smoke-test operation counts are invalid: {path}")
    for operation, count in expected_counts.items():
        require_string(operation, "manifest smoke-test operation")
        require_int(count, f"manifest smoke-test operation count {operation}")
    actual_counts = Counter(transaction["method"].split("(", 1)[0] for transaction in smoke["transactions"])
    if dict(actual_counts) != expected_counts:
        raise ValueError(f"smoke-test operation counts mismatch: {path}")


def validate_broadcast_integrity(
    broadcast: dict[str, Any],
    deployment_hashes: set[str],
    label: str,
) -> None:
    status = require_string(broadcast["integrityStatus"], "Foundry artifact integrity status")
    misassociations = broadcast.get("knownHashMisassociations", [])
    if type(misassociations) is not list:
        raise ValueError(f"Foundry hash-misassociation evidence must be a list: {label}")
    if status == "valid":
        if misassociations:
            raise ValueError(f"valid Foundry artifact declares hash misassociations: {label}")
        return
    if status != "known-hash-to-payload-misassociations":
        raise ValueError(f"unsupported Foundry artifact integrity status: {status}")
    if not misassociations:
        raise ValueError(f"Foundry artifact integrity caveat has no evidence: {label}")

    seen_pairs: set[tuple[str, str]] = set()
    for entry in misassociations:
        entry = require_fields(
            entry,
            {"payload", "recordedHash", "correctHash"},
            "Foundry hash-misassociation entry",
        )
        require_string(entry["payload"], "misassociated payload purpose")
        recorded_hash = entry["recordedHash"]
        correct_hash = entry["correctHash"]
        require_hash(recorded_hash, "misassociated recorded transaction hash")
        require_hash(correct_hash, "misassociated correct transaction hash")
        if recorded_hash == correct_hash:
            raise ValueError(f"Foundry hash-misassociation maps a hash to itself: {label}")
        if recorded_hash not in deployment_hashes or correct_hash not in deployment_hashes:
            raise ValueError(f"Foundry hash-misassociation references an unknown transaction: {label}")
        pair = (recorded_hash, correct_hash)
        if pair in seen_pairs:
            raise ValueError(f"duplicate Foundry hash-misassociation entry: {label}")
        seen_pairs.add(pair)


def validate_manifest(path: Path) -> None:
    manifest = load_json(path)
    if require_int(manifest["schemaVersion"], "manifest schema version", 1) != 1:
        raise ValueError(f"unsupported manifest schema: {path}")
    chain_id = require_int(manifest["network"]["chainId"], "manifest chain ID", 1)
    require_int(manifest["vault"]["decimals"], "vault decimals")
    wrapper = manifest["contracts"]["wrapperProxy"]["address"]
    require_address(wrapper, "wrapper proxy")
    if path.parent.parent.name != str(chain_id):
        raise ValueError(f"manifest directory chain mismatch: {path}")
    if path.parent.name.lower() != wrapper.lower():
        raise ValueError(f"manifest directory wrapper mismatch: {path}")
    source_commit = manifest["source"]["commit"]
    if type(source_commit) is not str or not COMMIT.fullmatch(source_commit):
        raise ValueError(f"source commit must be a full SHA-1: {path}")

    require_address(manifest["configuration"]["deployer"], "deployer")
    require_address(manifest["configuration"]["owner"], "owner")
    require_address(manifest["configuration"]["smartAccount"], "smart account")
    privileged = manifest["privilegedAccounts"]
    require_int(privileged["snapshotBlock"], "privileged-account snapshot block", 1)
    for role in ("owner", "smartAccount"):
        require_address(privileged[role]["address"], f"privileged account {role}")
        require_int(privileged[role]["nonce"], f"privileged account {role} nonce")
        balance_wei = privileged[role]["balanceWei"]
        if type(balance_wei) is not str or not DECIMAL.fullmatch(balance_wei):
            raise ValueError(f"invalid balance for privileged account {role}")
    if privileged["owner"]["address"].lower() != manifest["configuration"]["owner"].lower():
        raise ValueError(f"privileged owner mismatch: {path}")
    if privileged["smartAccount"]["address"].lower() != manifest["configuration"]["smartAccount"].lower():
        raise ValueError(f"privileged smart-account mismatch: {path}")
    require_hash(privileged["owner"]["runtimeBytecodeKeccak256"], "owner runtime hash")
    require_hash(privileged["smartAccount"]["delegationCodeKeccak256"], "smart-account delegation hash")
    delegation_target = privileged["smartAccount"]["delegationTarget"]
    require_address(delegation_target["address"], "smart-account delegation target")
    require_int(delegation_target["runtimeBytes"], "delegation-target runtime byte length", 1)
    require_hash(delegation_target["runtimeBytecodeKeccak256"], "delegation-target runtime hash")
    post_smoke_target = manifest["verification"]["postSmokeState"]["smartAccountDelegationTarget"]
    if delegation_target["address"].lower() != post_smoke_target.lower():
        raise ValueError(f"smart-account delegation-target mismatch: {path}")
    for name, contract in manifest["contracts"].items():
        require_address(contract["address"], f"contract {name}")
    for name, entry in manifest["verification"]["runtimeBytecode"].items():
        require_int(entry["bytes"], f"runtime byte length {name}", 1)
        require_hash(entry["keccak256"], f"runtime hash {name}")
    for name, entry in manifest["verification"]["proxySlots"].items():
        require_hash(entry["slot"], f"proxy slot {name}")
        require_hash(entry["value"], f"proxy slot value {name}")

    validate_transactions(manifest["deployment"]["transactions"], str(path))

    broadcast = manifest["source"]["foundryBroadcast"]
    broadcast_path = resolve_local_path(
        ROOT,
        broadcast["fileName"],
        ROOT / "broadcast",
        "Foundry broadcast path",
    )
    if not broadcast_path.is_file():
        raise ValueError(f"missing Foundry broadcast artifact: {broadcast_path}")
    actual_sha256 = hashlib.sha256(broadcast_path.read_bytes()).hexdigest()
    require_sha256(broadcast["sha256"], "Foundry broadcast SHA-256")
    if actual_sha256 != broadcast["sha256"]:
        raise ValueError(f"Foundry broadcast SHA-256 mismatch: {broadcast_path}")
    deployment_hashes = {transaction["hash"] for transaction in manifest["deployment"]["transactions"]}
    validate_broadcast_integrity(broadcast, deployment_hashes, str(path))

    documentation = manifest["documentation"]
    report_path = resolve_local_path(
        path.parent,
        documentation["humanVerificationReport"],
        path.parent,
        "human verification report",
    )
    smoke_path = resolve_local_path(
        path.parent,
        documentation["smokeTestEvidence"],
        path.parent,
        "smoke-test evidence",
    )
    registry_path = resolve_local_path(
        DEPLOYMENTS,
        documentation["registryIndex"],
        DEPLOYMENTS,
        "deployment registry index",
    )
    for target in (report_path, smoke_path, registry_path):
        if not target.is_file():
            raise ValueError(f"missing documentation target: {target}")
    manifest_smoke = manifest["verification"]["mainnetSmokeTest"]
    if manifest_smoke["evidenceFile"] != documentation["smokeTestEvidence"]:
        raise ValueError(f"smoke-test evidence filename mismatch: {path}")
    smoke_sha256 = hashlib.sha256(smoke_path.read_bytes()).hexdigest()
    require_sha256(manifest_smoke["evidenceSha256"], "smoke-test evidence SHA-256")
    if smoke_sha256 != manifest_smoke["evidenceSha256"]:
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
