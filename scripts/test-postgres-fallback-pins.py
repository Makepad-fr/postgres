#!/usr/bin/env python3
"""Exercise the repository validator against safe and unsafe image policies."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

class FallbackPins(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name) / 'repo'
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns('.git', '__pycache__'))

    def validate(self):
        return subprocess.run(['bash', str(self.root / 'scripts/validate-postgres-config.sh')], text=True, capture_output=True)

    def test_reviewed_configuration_passes(self):
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_host_fallback_digest_drift_is_rejected(self):
        path = self.root / 'compose.host.yml'
        text = path.read_text()
        import re
        text, count = re.subn(r'postgres:18-alpine@sha256:[0-9a-f]{64}', 'postgres:18-alpine@sha256:' + '0' * 64, text, count=1)
        self.assertEqual(count, 1)
        path.write_text(text)
        result = self.validate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('fallback image digests must match', result.stdout + result.stderr)

    def test_production_major_override_change_is_rejected(self):
        path = self.root / 'envs/production/.env.db'
        path.write_text(path.read_text().replace('POSTGRES_IMAGE=postgres:16-alpine@', 'POSTGRES_IMAGE=postgres:18-alpine@'))
        result = self.validate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must pin POSTGRES_IMAGE', result.stdout + result.stderr)

if __name__ == '__main__':
    unittest.main()
