#!/usr/bin/env python3
"""Regression tests for the deployment registry validator."""

from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from deployments.validate import (
    resolve_local_path,
    validate_broadcast_integrity,
    validate_transactions,
)

TEST_ACCOUNT = "0x1111111111111111111111111111111111111111"
SMART_ACCOUNT = "0x2222222222222222222222222222222222222222"
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

    def test_unknown_method_is_rejected(self) -> None:
        self.assert_invalid("method", "unknown()")

    def test_argument_schema_and_types_are_strict(self) -> None:
        missing = smoke_transaction()
        del missing["arguments"]["owner"]  # type: ignore[index]
        with self.assertRaises(ValueError):
            validate_transactions([missing], "test", self.actors)

        invalid_type = smoke_transaction()
        invalid_type["arguments"]["assets"] = True  # type: ignore[index]
        with self.assertRaises(ValueError):
            validate_transactions([invalid_type], "test", self.actors)


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
