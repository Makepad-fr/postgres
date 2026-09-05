#!/usr/bin/env python3
from __future__ import annotations

import os
import pathlib
import re
import unittest


ROOT = pathlib.Path(
    os.environ.get("BRIO_LEASE_CANDIDATE_ROOT", pathlib.Path(__file__).parents[1])
).resolve()


class PostgreSQLOperationLeaseWiringTests(unittest.TestCase):
    def test_postgres_mutations_are_bounded_by_cross_host_lease(self) -> None:
        workflows = [
            (ROOT / ".github/workflows/manual-deploy.yml").read_text(encoding="utf-8"),
            (ROOT / ".github/workflows/deploy-brio-identity-db.yml").read_text(encoding="utf-8"),
        ]
        for workflow in workflows:
            with self.subTest(workflow=workflow[:40]):
                timeout = re.search(r"timeout-minutes:\s*([0-9]+)", workflow)
                self.assertIsNotNone(timeout)
                self.assertLessEqual(int(timeout.group(1)), 210)
                acquire = workflow.index("brio-operation-lease-remote.sh acquire")
                first_remote_mutation = min(
                    position
                    for marker in (
                        "install -d -m 0755 ${remote_parent_q}",
                        "install -d -m 0700 ${remote_bundle_q}",
                    )
                    if (position := workflow.find(marker)) >= 0
                )
                release = workflow.index("brio-operation-lease-remote.sh release")
                cleanup_names = (
                    "Remove job-scoped deployment material",
                    "Remove local job-scoped deployment material",
                )
                local_cleanup = min(
                    workflow.index(name) for name in cleanup_names if name in workflow
                )
                self.assertLess(acquire, first_remote_mutation)
                self.assertIn(
                    "brio-operation-lease status ${lease_owner_q} deployment",
                    workflow[: first_remote_mutation + 200],
                )
                self.assertLess(release, local_cleanup)

        for relative in (
            "scripts/deploy-postgres-stack.sh",
            "scripts/deploy-brio-canary-postgres.sh",
            "scripts/deploy-brio-identity-db-host.sh",
        ):
            script = (ROOT / relative).read_text(encoding="utf-8")
            self.assertIn("require_brio_deployment_lease", script)
            self.assertIn("/usr/local/libexec/makepad/brio-operation-lease", script)
            self.assertIn('status "${BRIO_OPERATION_LEASE_OWNER}" deployment', script)

    def test_remote_client_uses_only_the_bounded_coordinator_command(self) -> None:
        client = (ROOT / "scripts/brio-operation-lease-remote.sh").read_text(encoding="utf-8")
        self.assertIn('[[ "${action}" =~ ^(acquire|status|release)$ ]]', client)
        self.assertIn('[[ "${owner}" =~ ^[0-9a-f]{64}$ ]]', client)
        self.assertIn("brio-operation-lease-coordinator ${action} ${owner} deployment", client)
        for forbidden in ("eval ", "bash -c", "sh -c", "docker "):
            self.assertNotIn(forbidden, client)


if __name__ == "__main__":
    unittest.main()
