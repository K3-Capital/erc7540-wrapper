#!/usr/bin/env python3
"""Regression tests for the deployment registry validator."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from deployments.validate import (
    SMOKE_METHODS,
    resolve_local_path,
    validate_broadcast_integrity,
    validate_smoke_test,
    validate_transactions,
)

TEST_ACCOUNT = "0x1111111111111111111111111111111111111111"
SMART_ACCOUNT = "0x2222222222222222222222222222222222222222"
WRAPPER = "0x3333333333333333333333333333333333333333"
HASH_1 = "0x" + "11" * 32
HASH_2 = "0x" + "22" * 32


def smoke_transaction() -> dict[str, object]:
    return {
        "sequence": 1,
        "hash": HASH_1,
        "block": 1,
        "transactionIndex": 0,
        "timestamp": "2026-08-04T09:11:47Z",
        "status": 1,
        "sender": TEST_ACCOUNT,
        "method": "requestDeposit(uint256,address,address)",
        "arguments": {
            "assets": "1",
            "controller": TEST_ACCOUNT,
            "owner": TEST_ACCOUNT,
        },
        "gasUsed": 1,
    }


def smoke_document() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "evidenceType": "mainnet-smoke-test",
        "network": {"name": "Test Network", "chainId": 1},
        "wrapper": WRAPPER,
        "actors": {"testAccount": TEST_ACCOUNT, "smartAccount": SMART_ACCOUNT},
        "units": {
            "assets": "asset base units",
            "shares": "share base units",
            "navSnapshot": "asset base units",
            "decimals": 8,
        },
        "status": "passed",
        "firstBlock": 1,
        "lastBlock": 1,
        "transactions": [smoke_transaction()],
    }


def smoke_manifest() -> dict[str, object]:
    return {
        "network": {"name": "Test Network", "chainId": 1},
        "vault": {"decimals": 8},
        "contracts": {"wrapperProxy": {"address": WRAPPER}},
        "verification": {
            "mainnetSmokeTest": {
                "status": "passed",
                "transactionCount": 1,
                "firstBlock": 1,
                "lastBlock": 1,
                "evidenceFile": "smoke-test.json",
                "evidenceSha256": "11" * 32,
                "operations": {"requestDeposit": 1},
                "transactionList": "https://example.invalid/transactions",
            }
        },
    }


class TransactionValidationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.actors = {
            "testAccount": TEST_ACCOUNT,
            "smartAccount": SMART_ACCOUNT,
        }

    def assert_invalid(self, field: str, value: object) -> None:
        transaction = smoke_transaction()
        transaction[field] = value
        with self.assertRaises(ValueError):
            validate_transactions([transaction], "test", self.actors)

    def test_valid_smoke_transaction(self) -> None:
        validate_transactions([smoke_transaction()], "test", self.actors)

    def test_boolean_integer_fields_are_rejected(self) -> None:
        for field in ("sequence", "block", "transactionIndex", "status", "gasUsed"):
            with self.subTest(field=field):
                self.assert_invalid(field, True)

    def test_invalid_sender_is_rejected(self) -> None:
        self.assert_invalid("sender", "not-an-address")

    def test_wrong_actor_is_rejected(self) -> None:
        self.assert_invalid("sender", SMART_ACCOUNT)

    def test_invalid_timestamp_is_rejected(self) -> None:
        self.assert_invalid("timestamp", "2026-08-04")

    def test_noncanonical_but_parseable_timestamp_is_rejected(self) -> None:
        self.assert_invalid("timestamp", "2026-8-4T9:1:7Z")

    def test_unknown_method_is_rejected(self) -> None:
        self.assert_invalid("method", "unknown()")

    def test_argument_schema_and_types_are_strict(self) -> None:
        missing = smoke_transaction()
        del missing["arguments"]["owner"]  # type: ignore[index]
        with self.assertRaises(ValueError):
            validate_transactions([missing], "test", self.actors)

        extra = smoke_transaction()
        extra["arguments"]["unexpected"] = "1"  # type: ignore[index]
        with self.assertRaises(ValueError):
            validate_transactions([extra], "test", self.actors)

        invalid_type = smoke_transaction()
        invalid_type["arguments"]["assets"] = True  # type: ignore[index]
        with self.assertRaises(ValueError):
            validate_transactions([invalid_type], "test", self.actors)

        invalid_address = smoke_transaction()
        invalid_address["arguments"]["owner"] = "not-an-address"  # type: ignore[index]
        with self.assertRaises(ValueError):
            validate_transactions([invalid_address], "test", self.actors)

        overflowing_uint = smoke_transaction()
        overflowing_uint["arguments"]["assets"] = str(1 << 256)  # type: ignore[index]
        with self.assertRaises(ValueError):
            validate_transactions([overflowing_uint], "test", self.actors)

        overflowing_uint40 = smoke_transaction()
        overflowing_uint40["method"] = "settleEpoch(uint40,uint256)"
        overflowing_uint40["sender"] = SMART_ACCOUNT
        overflowing_uint40["arguments"] = {
            "epochId": str(1 << 40),
            "navSnapshot": "1",
        }
        with self.assertRaises(ValueError):
            validate_transactions([overflowing_uint40], "test", self.actors)

    def test_extra_transaction_field_is_rejected(self) -> None:
        transaction = smoke_transaction()
        transaction["unexpected"] = "field"
        with self.assertRaises(ValueError):
            validate_transactions([transaction], "test", self.actors)

    def test_nonpositive_gas_is_rejected(self) -> None:
        for gas_used in (0, -1):
            with self.subTest(gas_used=gas_used):
                self.assert_invalid("gasUsed", gas_used)

    def test_every_supported_method_and_sender_role_is_accepted(self) -> None:
        for method, (role, argument_schema) in SMOKE_METHODS.items():
            with self.subTest(method=method):
                transaction = smoke_transaction()
                transaction["method"] = method
                transaction["sender"] = self.actors[role]
                transaction["arguments"] = {
                    name: TEST_ACCOUNT if kind == "address" else "1"
                    for name, kind in argument_schema.items()
                }
                validate_transactions([transaction], "test", self.actors)

    def test_duplicate_position_and_reverse_timestamp_are_rejected(self) -> None:
        first = smoke_transaction()
        second = copy.deepcopy(first)
        second["sequence"] = 2
        second["hash"] = HASH_2
        with self.assertRaises(ValueError):
            validate_transactions([first, second], "test", self.actors)

        second["block"] = 2
        second["timestamp"] = "2026-08-04T09:11:46Z"
        with self.assertRaises(ValueError):
            validate_transactions([first, second], "test", self.actors)


class SmokeDocumentValidationTest(unittest.TestCase):
    def validate_document(
        self,
        document: dict[str, object] | None = None,
        manifest: dict[str, object] | None = None,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "smoke-test.json"
            path.write_text(json.dumps(document or smoke_document()), encoding="utf-8")
            validate_smoke_test(path, manifest or smoke_manifest())

    def test_valid_document(self) -> None:
        self.validate_document()

    def test_extra_envelope_and_network_fields_are_rejected(self) -> None:
        document = smoke_document()
        document["unexpected"] = "field"
        with self.assertRaises(ValueError):
            self.validate_document(document)

        document = smoke_document()
        document["network"]["unexpected"] = "field"  # type: ignore[index]
        with self.assertRaises(ValueError):
            self.validate_document(document)

    def test_extra_manifest_smoke_field_is_rejected(self) -> None:
        manifest = smoke_manifest()
        record = manifest["verification"]["mainnetSmokeTest"]  # type: ignore[index]
        record["unexpected"] = "field"  # type: ignore[index]
        with self.assertRaises(ValueError):
            self.validate_document(manifest=manifest)

    def test_status_chain_decimals_and_block_range_are_strict(self) -> None:
        document = smoke_document()
        document["status"] = "failed"
        with self.assertRaises(ValueError):
            self.validate_document(document)

        document = smoke_document()
        document["network"]["chainId"] = True  # type: ignore[index]
        with self.assertRaises(ValueError):
            self.validate_document(document)

        document = smoke_document()
        document["units"]["decimals"] = 18  # type: ignore[index]
        with self.assertRaises(ValueError):
            self.validate_document(document)

        document = smoke_document()
        document["lastBlock"] = 2
        with self.assertRaises(ValueError):
            self.validate_document(document)

    def test_manifest_counts_and_status_are_strict(self) -> None:
        manifest = smoke_manifest()
        record = manifest["verification"]["mainnetSmokeTest"]  # type: ignore[index]
        record["status"] = False  # type: ignore[index]
        with self.assertRaises(ValueError):
            self.validate_document(manifest=manifest)

        manifest = smoke_manifest()
        record = manifest["verification"]["mainnetSmokeTest"]  # type: ignore[index]
        record["transactionCount"] = 2  # type: ignore[index]
        with self.assertRaises(ValueError):
            self.validate_document(manifest=manifest)

        manifest = smoke_manifest()
        record = manifest["verification"]["mainnetSmokeTest"]  # type: ignore[index]
        record["operations"] = {"requestDeposit": 2}  # type: ignore[index]
        with self.assertRaises(ValueError):
            self.validate_document(manifest=manifest)


class BroadcastIntegrityTest(unittest.TestCase):
    def test_clean_future_artifact_is_accepted(self) -> None:
        validate_broadcast_integrity({"integrityStatus": "valid"}, {HASH_1}, "test")

    def test_known_anomaly_accepts_arbitrary_nonempty_mapping_list(self) -> None:
        broadcast = {
            "integrityStatus": "known-hash-to-payload-misassociations",
            "knownHashMisassociations": [
                {
                    "payload": "test payload",
                    "recordedHash": HASH_1,
                    "correctHash": HASH_2,
                }
            ],
        }
        validate_broadcast_integrity(broadcast, {HASH_1, HASH_2}, "test")

    def test_clean_artifact_cannot_declare_anomalies(self) -> None:
        broadcast = {
            "integrityStatus": "valid",
            "knownHashMisassociations": [copy.deepcopy({"payload": "invalid"})],
        }
        with self.assertRaises(ValueError):
            validate_broadcast_integrity(broadcast, {HASH_1}, "test")


class LocalPathValidationTest(unittest.TestCase):
    def test_valid_relative_path_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(resolve_local_path(root, "evidence.json", root, "evidence"), root / "evidence.json")

    def test_parent_traversal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                resolve_local_path(root, "../evidence.json", root, "evidence")

    def test_absolute_path_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                resolve_local_path(root, "/tmp/evidence.json", root, "evidence")

    def test_symlink_escape_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as root_directory:
            with tempfile.TemporaryDirectory() as outside_directory:
                root = Path(root_directory)
                (root / "outside").symlink_to(outside_directory, target_is_directory=True)
                with self.assertRaises(ValueError):
                    resolve_local_path(root, "outside/evidence.json", root, "evidence")


if __name__ == "__main__":
    unittest.main()
