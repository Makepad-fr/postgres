#!/usr/bin/env python3
"""Exercise the actual per-database fingerprint snapshot cleanup block."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RESTORE = ROOT / "scripts/restore-keycloak-cohort-backups.sh"


def cleanup_block():
    source = RESTORE.read_text(encoding="utf-8")
    start = source.index('  rm -f "${secret_file}"', source.index('fingerprint_configuration after'))
    end = source.index('  unset before after', start) + len('  unset before after')
    return source[start:end]


class SnapshotCleanupTest(unittest.TestCase):
    def run_fixture(self, unexpected=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / ".runtime"
            runtime.mkdir()
            for table in ("realm", "client"):
                for phase in ("before", "after"):
                    (runtime / f"catwlk-{phase}-{table}.jsonl").write_text("raw-secret-configuration\n")
            for phase in ("before", "after"):
                (runtime / f"catwlk-{phase}-schema.json").write_text("raw-private-schema\n")
                (runtime / f"catwlk-{phase}-org_domain.jsonl").write_text("raw-org-routing\n")
            (runtime / "catwlk-after-org_identity_provider.jsonl").write_text("raw-org-link\n")
            (runtime / "catwlk-password").write_text("raw-secret-password\n")
            if unexpected:
                (runtime / "unexpected.jsonl").write_text("must-remain\n")
            script = """set -euo pipefail
result_dir=$TEST_ROOT
slug=catwlk
secret_file=$result_dir/.runtime/catwlk-password
declare -A category_tables=([realm]='realm' [clients]='client')
declare -A before=() after=()
""" + cleanup_block() + "\nrmdir \"$result_dir/.runtime\"\n"
            proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                                  env={**os.environ, "TEST_ROOT": str(root)})
            remaining = sorted(path.name for path in runtime.iterdir()) if runtime.exists() else []
            return proc, remaining

    def test_expected_snapshots_and_secret_are_deleted_before_success(self):
        proc, remaining = self.run_fixture()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(remaining, [])
        self.assertNotIn("raw-secret", proc.stdout + proc.stderr)

    def test_unexpected_file_blocks_success_without_deleting_it(self):
        proc, remaining = self.run_fixture(unexpected=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(remaining, ["unexpected.jsonl"])


if __name__ == "__main__":
    unittest.main()
