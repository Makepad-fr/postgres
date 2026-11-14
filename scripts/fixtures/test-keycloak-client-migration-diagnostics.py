#!/usr/bin/env python3
"""Synthetic, secret-bearing fixture for bounded restore failure diagnostics."""

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
DIAGNOSTIC = ROOT / "scripts/diagnose-keycloak-client-migration.py"
RESTORE = ROOT / "scripts/restore-keycloak-cohort-backups.sh"
SECRET = "super-secret-client-credential-should-never-be-logged"


class ClientMigrationDiagnosticsTest(unittest.TestCase):
    def write(self, root, phase, table, rows):
        (root / f"catwlk-{phase}-{table}.jsonl").write_text(
            "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8"
        )

    def fixture(self, root):
        realms = [{"id": "realm-1", "name": "catwlk", "smtp_config": SECRET},
                  {"id": "realm-2", "name": "master"}]
        clients = [{"id": "client-1", "realm_id": "realm-1", "client_id": "catwlk-web", "secret": SECRET}]
        old_scopes = [{"id": "scope-1", "realm_id": "realm-1", "name": "profile", "protocol": "openid-connect"}]
        new_scopes = old_scopes + [
            {"id": "scope-2", "realm_id": "realm-1", "name": "new-scope", "protocol": "openid-connect", "description": SECRET},
            {"id": "scope-3", "realm_id": "realm-2", "name": "new-scope", "protocol": "openid-connect", "description": SECRET},
        ]
        old_defaults = [{"realm_id": "realm-1", "scope_id": "scope-1", "default_scope": True}]
        new_defaults = old_defaults + [
            {"realm_id": "realm-1", "scope_id": "scope-2", "default_scope": False},
            {"realm_id": "realm-2", "scope_id": "scope-3", "default_scope": False},
        ]
        old_mappers = [{"id": "mapper-1", "client_scope_id": "scope-1", "name": "old", "protocol": "openid-connect",
                        "protocol_mapper_name": "oidc-usermodel-attribute-mapper"}]
        new_mappers = old_mappers + [
            {"id": "mapper-2", "client_scope_id": "scope-2", "name": "new-claim", "protocol": "openid-connect",
             "protocol_mapper_name": "oidc-hardcoded-claim-mapper", "config": SECRET},
            {"id": "mapper-3", "client_scope_id": "scope-3", "name": "new-claim", "protocol": "openid-connect",
             "protocol_mapper_name": "oidc-hardcoded-claim-mapper", "config": SECRET},
        ]
        for table, before, after in (
            ("realm", realms, realms), ("client", clients, clients),
            ("client_scope", old_scopes, new_scopes),
            ("default_client_scope", old_defaults, new_defaults),
            ("protocol_mapper", old_mappers, new_mappers),
        ):
            self.write(root, "before", table, before)
            self.write(root, "after", table, after)

    def test_only_added_scope_and_mapper_identifiers_are_logged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            proc = subprocess.run([sys.executable, str(DIAGNOSTIC), str(root), "catwlk"],
                                  capture_output=True, text=True, check=True)
            result = json.loads(proc.stderr)
            self.assertEqual(proc.stdout, "")
            self.assertEqual(result["database"], "catwlk")
            self.assertEqual(result["added_client_scopes_count"], 2)
            self.assertEqual(result["added_default_client_scopes_count"], 2)
            self.assertEqual(result["added_protocol_mappers_count"], 2)
            self.assertEqual([row["realm"] for row in result["added_client_scopes"]], ["catwlk", "master"])
            self.assertEqual([row["scope"] for row in result["added_default_client_scopes"]],
                             ["new-scope", "new-scope"])
            self.assertEqual([row["mapper_type"] for row in result["added_protocol_mappers"]],
                             ["oidc-hardcoded-claim-mapper", "oidc-hardcoded-claim-mapper"])
            self.assertNotIn(SECRET, proc.stderr)
            self.assertNotIn("description", proc.stderr)
            self.assertNotIn("smtp_config", proc.stderr)
            self.assertNotIn("secret", proc.stderr)

    def test_malformed_rows_fail_without_printing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            (root / "catwlk-after-protocol_mapper.jsonl").write_text("{\"secret\": \"" + SECRET + "\"}\n")
            proc = subprocess.run([sys.executable, str(DIAGNOSTIC), str(root), "catwlk"],
                                  capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)
            self.assertNotIn(SECRET, proc.stderr)

    def test_sensitive_and_control_character_names_are_redacted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            path = root / "catwlk-after-client_scope.jsonl"
            scopes = [json.loads(line) for line in path.read_text().splitlines()]
            scopes[1]["name"] = "secret-token-123"
            scopes[2]["name"] = "unsafe\nname"
            self.write(root, "after", "client_scope", scopes)
            proc = subprocess.run([sys.executable, str(DIAGNOSTIC), str(root), "catwlk"],
                                  capture_output=True, text=True, check=True)
            self.assertEqual([row["name"] for row in json.loads(proc.stderr)["added_client_scopes"]],
                             ["<redacted>", "<redacted>"])
            self.assertNotIn("secret-token-123", proc.stderr)
            self.assertNotIn("unsafe", proc.stderr)

    def test_output_is_bounded_without_hiding_addition_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            path = root / "catwlk-after-client_scope.jsonl"
            scopes = [json.loads(line) for line in path.read_text().splitlines()]
            scopes.extend({"id": f"scope-extra-{n}", "realm_id": "realm-1",
                           "name": f"new-extra-{n}", "protocol": "openid-connect"} for n in range(25))
            self.write(root, "after", "client_scope", scopes)
            proc = subprocess.run([sys.executable, str(DIAGNOSTIC), str(root), "catwlk"],
                                  capture_output=True, text=True, check=True)
            result = json.loads(proc.stderr)
            self.assertEqual(result["added_client_scopes_count"], 27)
            self.assertEqual(len(result["added_client_scopes"]), 20)

    def test_diagnostic_does_not_bypass_fingerprint_failure(self):
        script = RESTORE.read_text(encoding="utf-8")
        call = script.index('diagnose-keycloak-client-migration.py')
        failure = script.index('echo "Keycloak ${category} configuration regression detected', call)
        self.assertIn("exit 1", script[failure:failure + 120])


if __name__ == "__main__":
    unittest.main()
