#!/usr/bin/env python3
"""Exercise the runner and secret boundary using disposable repository copies."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class RunnerPolicyTests(unittest.TestCase):
    def check(self, old, new, expected):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory) / "repo"
            shutil.copytree(ROOT, root, ignore=shutil.ignore_patterns(".git"))
            workflow = root / ".github/workflows/fashion-bootstrap.yml"
            text = workflow.read_text()
            self.assertIn(old, text)
            workflow.write_text(text.replace(old, new))
            result = subprocess.run(["bash", "scripts/validate-postgres-config.sh"], cwd=root, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, expected, result.stdout + result.stderr)

    def test_reviewed_hosted_runner_passes(self):
        self.check("ubuntu-26.04", "ubuntu-26.04", True)

    def test_unreviewed_runner_is_rejected(self):
        self.check("ubuntu-26.04", "ubuntu-latest", False)

    def test_self_hosted_runner_is_rejected(self):
        self.check("ubuntu-26.04", "[self-hosted, linux, x64, makepad]", False)

    def test_production_secret_is_rejected(self):
        self.check("ubuntu-26.04", "ubuntu-26.04\n    env: { TOKEN: '${{ secrets.PRODUCTION_TOKEN }}' }", False)

if __name__ == "__main__":
    unittest.main()
