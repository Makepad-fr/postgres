#!/usr/bin/env python3
"""A middle-table SQL failure must stop attestation before evidence exists."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


RESTORE = Path(__file__).resolve().parents[1] / "restore-keycloak-cohort-backups.sh"


class FingerprintQueryFailureTest(unittest.TestCase):
    def test_mid_category_query_failure_cannot_be_masked(self):
        source = RESTORE.read_text(encoding="utf-8")
        start = source.index("fingerprint_configuration() {")
        end = source.index("\ncapture_schema_inventory()", start)
        function = source[start:end]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".runtime").mkdir()
            script = """#!/usr/bin/env bash
set -euo pipefail
result_dir=$TEST_ROOT
slug=catwlk
declare -A category_tables=([realm]='realm realm_attribute realm_events_listeners')
db_query() {
  if [[ "$1" == *"to_regclass"* ]]; then printf '1\\n'; return 0; fi
  if [[ "$1" == *"FROM realm_attribute"* ]]; then return 17; fi
  printf '{"setting":"synthetic"}\\n'
}
""" + function + """
declare -A before=()
fingerprint_configuration before
printf 'should-not-exist\\n' > "$result_dir/instances.json"
"""
            proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                                  env={**os.environ, "TEST_ROOT": str(root)})
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse((root / "instances.json").exists())
            self.assertTrue((root / ".runtime/catwlk-before-realm.jsonl").exists())
            self.assertFalse((root / ".runtime/catwlk-before-realm_events_listeners.jsonl").exists())
            self.assertNotIn("synthetic", proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
