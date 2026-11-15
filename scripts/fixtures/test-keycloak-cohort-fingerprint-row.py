#!/usr/bin/env python3
"""Exercise the cohort's actual fingerprint SQL against a value-column table."""

import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid
import unittest


ROOT = Path(__file__).resolve().parents[2]
RESTORE = ROOT / "scripts/restore-keycloak-cohort-backups.sh"


def run(*args, check=True):
    result = subprocess.run(args, check=False, capture_output=True, text=True)
    if check and result.returncode:
        raise AssertionError(f"disposable PostgreSQL command failed: {result.stderr.strip()}")
    return result


def fingerprint_sql():
    line = next(
        line.strip() for line in RESTORE.read_text(encoding="utf-8").splitlines()
        if 'db_query "SELECT to_jsonb(' in line
    )
    sql = line.split('db_query "', 1)[1].split('" >', 1)[0]
    assert sql.count("${table}") == 1
    return sql.replace("${table}", "fingerprint_value_probe")


class FingerprintRowTest(unittest.TestCase):
    def test_value_column_does_not_hide_other_columns(self):
        image = next(
            line.split("=", 1)[1] for line in
            (ROOT / "envs/production/.env.db").read_text(encoding="utf-8").splitlines()
            if line.startswith("POSTGRES_IMAGE=")
        )
        name = "kc-fingerprint-" + uuid.uuid4().hex[:16]
        run(
            "docker", "run", "-d", "--rm", "--name", name, "--network", "none",
            "--tmpfs", "/var/lib/postgresql/data:rw,nosuid,size=256m",
            "-e", "POSTGRES_HOST_AUTH_METHOD=trust", image,
        )
        try:
            for _ in range(60):
                logs = run("docker", "logs", name, check=False)
                initialized = "PostgreSQL init process complete; ready for start up." in (logs.stdout + logs.stderr)
                ready = run("docker", "exec", name, "pg_isready", "-U", "postgres", "-d", "postgres", check=False).returncode == 0
                if initialized and ready:
                    break
                time.sleep(0.2)
            else:
                self.fail("disposable PostgreSQL did not become ready")
            run(
                "docker", "exec", name, "psql", "-X", "-v", "ON_ERROR_STOP=1",
                "-U", "postgres", "-d", "postgres", "-c",
                "CREATE TABLE fingerprint_value_probe (id text PRIMARY KEY, value text, setting text); "
                "INSERT INTO fingerprint_value_probe VALUES ('one', 'synthetic-value', 'before');",
            )
            sql = fingerprint_sql()
            before = run("docker", "exec", name, "psql", "-X", "-At", "-U", "postgres", "-d", "postgres", "-c", sql).stdout
            rows = [json.loads(line) for line in before.splitlines()]
            self.assertEqual(len(rows), 1)
            self.assertIsInstance(rows[0], dict, "fingerprint must serialize the whole row")
            self.assertEqual(set(rows[0]), {"id", "value", "setting"})
            run(
                "docker", "exec", name, "psql", "-X", "-v", "ON_ERROR_STOP=1",
                "-U", "postgres", "-d", "postgres", "-c",
                "UPDATE fingerprint_value_probe SET setting = 'after' WHERE id = 'one';",
            )
            after = run("docker", "exec", name, "psql", "-X", "-At", "-U", "postgres", "-d", "postgres", "-c", sql).stdout
            self.assertNotEqual(hashlib.sha256(before.encode()).digest(), hashlib.sha256(after.encode()).digest())
        finally:
            run("docker", "rm", "-f", name, check=False)


if __name__ == "__main__":
    unittest.main()
