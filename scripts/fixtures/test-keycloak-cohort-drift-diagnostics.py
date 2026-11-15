#!/usr/bin/env python3
"""Keep drift diagnostics complete and free of configuration values."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
DIAGNOSTIC = ROOT / "scripts/diagnose-keycloak-cohort-drift.py"
RESTORE = ROOT / "scripts/restore-keycloak-cohort-backups.sh"
SECRET = "never-print-this-synthetic-client-secret"


def write_rows(root, phase, table, rows):
    (root / f"catwlk-{phase}-{table}.jsonl").write_text(
        "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
    )


class DriftDiagnosticTest(unittest.TestCase):
    def test_all_changed_tables_report_counts_without_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_rows(root, "before", "client_scope", [{"id": "one", "name": SECRET, "realm_id": "r"}])
            write_rows(root, "after", "client_scope", [
                {"id": "one", "name": "changed", "realm_id": "r"},
                {"id": "two", "name": "new-scope", "realm_id": "r"},
            ])
            write_rows(root, "before", "client_scope_attributes", [SECRET])
            write_rows(root, "after", "client_scope_attributes", ["changed-secret"])
            write_rows(root, "before", "protocol_mapper", [{"id": "unchanged", "value": SECRET}])
            write_rows(root, "after", "protocol_mapper", [{"id": "unchanged", "value": SECRET}])
            proc = subprocess.run(
                [sys.executable, str(DIAGNOSTIC), str(root), "catwlk", "clients",
                 "client_scope client_scope_attributes protocol_mapper"],
                capture_output=True, text=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertNotIn(SECRET, proc.stdout + proc.stderr)
            rows = [json.loads(line) for line in proc.stderr.splitlines()]
            self.assertEqual([row["table"] for row in rows], ["client_scope", "client_scope_attributes"])
            self.assertEqual(rows[0]["added_rows"], 1)
            self.assertEqual(rows[0]["removed_rows"], 0)
            self.assertEqual(rows[0]["changed_columns"], ["name"])
            self.assertEqual(rows[1]["diagnostic"], "row-shape-or-read-error")

    def test_missing_or_non_object_rows_cannot_abort_other_tables(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_rows(root, "before", "client", [{"id": "one", "name": "before"}])
            write_rows(root, "after", "client", [{"id": "one", "name": "after"}])
            proc = subprocess.run(
                [sys.executable, str(DIAGNOSTIC), str(root), "catwlk", "clients",
                 "missing_table client"], capture_output=True, text=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            rows = [json.loads(line) for line in proc.stderr.splitlines()]
            self.assertEqual(rows[0]["table"], "missing_table")
            self.assertEqual(rows[0]["diagnostic"], "row-shape-or-read-error")
            self.assertEqual(rows[1]["table"], "client")
            self.assertEqual(rows[1]["changed_columns"], ["name"])

    def test_restore_keeps_unreviewed_migration_blocking_even_if_detail_fails(self):
        source = RESTORE.read_text(encoding="utf-8")
        start = source.index("  configuration_regression=0", source.index("fingerprint_configuration after"))
        end = source.index("  if ((configuration_regression == 0)); then", start)
        block = source[start:end]
        self.assertIn('if ! python3 "$(dirname "$0")/verify_keycloak_cohort_migration.py"', block)
        self.assertIn("configuration_regression=1", block)
        self.assertIn('if ! python3 "$(dirname "$0")/diagnose-keycloak-cohort-drift.py"', block)
        self.assertIn("fingerprint mismatch remains blocking", block)
        self.assertIn("if ((configuration_regression == 0)); then", source)
        self.assertIn("if ((${#mismatched_slugs[@]} > 0)); then", source)


if __name__ == "__main__":
    unittest.main()
