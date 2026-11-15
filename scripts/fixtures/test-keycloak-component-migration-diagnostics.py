#!/usr/bin/env python3
"""Synthetic component-policy fixture with secret-bearing configuration values."""

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
DIAGNOSTIC = ROOT / "scripts/diagnose-keycloak-component-migration.py"
RESTORE = ROOT / "scripts/restore-keycloak-cohort-backups.sh"
SECRET = "production-policy-secret-must-not-appear"


class ComponentMigrationDiagnosticsTest(unittest.TestCase):
    def write(self, root, phase, table, rows):
        (root / f"catwlk-{phase}-{table}.jsonl").write_text(
            "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8"
        )

    def fixture(self, root):
        realms = [{"id": "realm-1", "name": "catwlk", "smtp_config": SECRET}]
        old_components = [{"id": "component-1", "realm_id": "realm-1", "name": "Full Scope Disabled",
                           "provider_id": "scope", "provider_type": "org.keycloak.ClientRegistrationPolicy"}]
        new_components = [
            {**old_components[0], "provider_id": "scope-updated"},
            {"id": "component-2", "realm_id": "realm-1", "name": "Default Roles Disabled",
             "provider_id": "default-roles-disabled", "provider_type": "org.keycloak.ClientRegistrationPolicy",
             "description": SECRET},
        ]
        old_config = [{"id": "config-1", "component_id": "component-1", "name": "mode", "value": SECRET}]
        new_config = [
            {**old_config[0], "value": SECRET + "-changed"},
            {"id": "config-2", "component_id": "component-2", "name": "enabled", "value": SECRET},
        ]
        for table, before, after in (("realm", realms, realms),
                                     ("component", old_components, new_components),
                                     ("component_config", old_config, new_config)):
            self.write(root, "before", table, before)
            self.write(root, "after", table, after)

    def test_policy_addition_and_changed_columns_are_bounded_to_safe_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            proc = subprocess.run([sys.executable, str(DIAGNOSTIC), str(root), "catwlk"],
                                  capture_output=True, text=True, check=True)
            result = json.loads(proc.stderr)
            self.assertEqual(proc.stdout, "")
            self.assertEqual(result["added_components_count"], 1)
            self.assertEqual(result["added_components"][0]["name"], "Default Roles Disabled")
            self.assertEqual(result["changed_components_count"], 1)
            self.assertEqual(result["changed_components"][0]["changed_columns"], ["provider_id"])
            self.assertEqual(result["added_component_config_keys"][0]["name"], "enabled")
            self.assertEqual(result["changed_component_config_keys"][0]["changed_columns"], ["value"])
            self.assertNotIn(SECRET, proc.stderr)
            self.assertNotIn("description", proc.stderr)

    def test_malformed_rows_fail_without_printing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            (root / "catwlk-after-component_config.jsonl").write_text("{\"value\": \"" + SECRET + "\"}\n")
            proc = subprocess.run([sys.executable, str(DIAGNOSTIC), str(root), "catwlk"],
                                  capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)
            self.assertNotIn(SECRET, proc.stderr)

    def test_output_is_bounded_without_hiding_policy_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            path = root / "catwlk-after-component.jsonl"
            components = [json.loads(line) for line in path.read_text().splitlines()]
            components.extend({"id": f"component-extra-{n}", "realm_id": "realm-1",
                               "name": f"policy-{n}", "provider_id": "policy",
                               "provider_type": "org.keycloak.ClientRegistrationPolicy"} for n in range(25))
            self.write(root, "after", "component", components)
            proc = subprocess.run([sys.executable, str(DIAGNOSTIC), str(root), "catwlk"],
                                  capture_output=True, text=True, check=True)
            result = json.loads(proc.stderr)
            self.assertEqual(result["added_components_count"], 26)
            self.assertEqual(len(result["added_components"]), 20)

    def test_all_categories_are_checked_before_fail_closed(self):
        script = RESTORE.read_text(encoding="utf-8")
        predicate = script.index('verify_keycloak_cohort_migration.py', script.index('fingerprint_configuration after'))
        loop = script.index('for category in $(printf', script.index('fingerprint_configuration after'))
        component = script.index('diagnose-keycloak-component-migration.py', loop)
        last_fingerprint = script.index('fingerprints+=("${category}=${after[$category]}")', component)
        mismatch_record = script.index('mismatched_slugs+=("${slug}")', last_fingerprint)
        fail = script.index('if ((${#mismatched_slugs[@]} > 0)); then', mismatch_record)
        evidence = script.index('"${result_dir}/instances.json"', fail)
        self.assertIn('configuration_regression=1', script[predicate:component])
        self.assertIn('exit 1', script[fail:evidence])


if __name__ == "__main__":
    unittest.main()
