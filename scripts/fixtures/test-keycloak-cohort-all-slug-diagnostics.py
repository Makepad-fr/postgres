#!/usr/bin/env python3
"""Exercise the real restore epilogue with five disposable, synthetic slugs."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RESTORE = ROOT / "scripts/restore-keycloak-cohort-backups.sh"
SLUGS = ("catwlk", "makepad", "runtrace", "vestiaire", "vif")


def restore_epilogue():
    source = RESTORE.read_text(encoding="utf-8")
    start = source.index("  if ((configuration_regression == 0)); then", source.index("fingerprint_configuration after"))
    end = source.index("\ndone\n\n", start)
    assert "declare -a mismatched_slugs=()" in source[:start]
    assert "if ((status != 0))" in source and 'find "${result_dir}" -depth -delete' in source
    return source[start:end], source[end + len("\ndone\n\n"):]


class AllSlugDiagnosticsTest(unittest.TestCase):
    def run_fixture(self, failed_slugs=(), fail_cleanup_slug=""):
        epilogue, tail = restore_epilogue()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = """#!/usr/bin/env bash
set -euo pipefail
result_dir=$TEST_ROOT
records=$result_dir/.instances.jsonl
trace=$result_dir/docker-trace
catwlk_image_id=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
mkdir -p "$result_dir/.runtime"
: > "$records"
: > "$trace"
declare -a mismatched_slugs=()
declare -A category_tables=([realm]='realm realm_attribute' [clients]='client')
docker() {
  printf '%s|%s\\n' "$slug" "$*" >> "$trace"
  if [[ "${DOCKER_FAIL_SLUG:-}" == "$slug" && "$1" == network ]]; then return 1; fi
}
for slug in catwlk makepad runtrace vestiaire vif; do
  database=keycloak_$slug
  backup_sha=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
  runtime_kind=keycloak-base
  runtime_evidence_image=dhi.io/keycloak:test
  fingerprints=(realm=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
  configuration_regression=0
  if [[ " $FAIL_SLUGS " == *" $slug "* ]]; then configuration_regression=1; fi
  active_keycloak_container=app-$slug
  active_database_container=db-$slug
  active_network=net-$slug
  secret_file=$result_dir/.runtime/$slug-password
  printf 'never-log-this-password\\n' > "$secret_file"
  for category in realm clients; do
    for table in ${category_tables[$category]}; do
      printf 'never-log-this-raw-configuration\\n' > "$result_dir/.runtime/$slug-before-$table.jsonl"
      printf 'never-log-this-raw-configuration\\n' > "$result_dir/.runtime/$slug-after-$table.jsonl"
    done
  done
  declare -A before=() after=()
""" + epilogue + "\ndone\n\n" + tail
            env = dict(os.environ, TEST_ROOT=str(root), FAIL_SLUGS=" ".join(failed_slugs),
                       DOCKER_FAIL_SLUG=fail_cleanup_slug)
            proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
            trace = (root / "docker-trace").read_text().splitlines()
            instance_file = root / "instances.json"
            instances = json.loads(instance_file.read_text())["instances"] if instance_file.exists() else None
            secrets_left = list((root / ".runtime").glob("*-password")) if (root / ".runtime").exists() else []
            snapshots_left = list((root / ".runtime").glob("*.jsonl")) if (root / ".runtime").exists() else []
            records = (root / ".instances.jsonl").read_text().splitlines() if (root / ".instances.jsonl").exists() else []
            return proc, trace, instances, secrets_left, snapshots_left, records

    def test_all_five_pass_and_write_five_instance_records(self):
        proc, trace, instances, secrets_left, snapshots_left, records = self.run_fixture()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual([row["slug"] for row in instances], list(SLUGS))
        self.assertEqual(len(trace), 10)
        self.assertEqual(secrets_left, [])
        self.assertEqual(snapshots_left, [])
        self.assertEqual(records, [])

    def test_early_and_late_mismatches_still_check_every_slug_and_publish_nothing(self):
        proc, trace, instances, secrets_left, snapshots_left, records = self.run_fixture(("catwlk", "vestiaire"))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("catwlk vestiaire", proc.stderr)
        self.assertEqual([line.split("|", 1)[0] for line in trace[::2]], list(SLUGS))
        self.assertEqual(len(trace), 10)
        self.assertIsNone(instances)
        self.assertEqual(secrets_left, [])
        self.assertEqual(snapshots_left, [])
        self.assertEqual(len(records), 3)
        self.assertNotIn("never-log-this-password", proc.stdout + proc.stderr)
        self.assertNotIn("never-log-this-raw-configuration", proc.stdout + proc.stderr)

    def test_cleanup_failure_stops_before_later_slug_and_publishes_nothing(self):
        proc, trace, instances, _, _, _ = self.run_fixture(fail_cleanup_slug="runtrace")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual([line.split("|", 1)[0] for line in trace[::2]], list(SLUGS[:3]))
        self.assertIsNone(instances)


if __name__ == "__main__":
    unittest.main()
