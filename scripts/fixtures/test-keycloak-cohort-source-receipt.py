#!/usr/bin/env python3
"""Adversarial envelope tests for the published source-variant receipt."""

from __future__ import annotations

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify-keycloak-cohort-source-receipt.py"
SLUGS = ("catwlk", "makepad", "runtrace", "vestiaire", "vif")
PREDECESSORS = ("legacy-26.5.7", "legacy-26.5.7", "legacy-26.5.7",
                "legacy-26.5.7", "vif-26.7.3")


def payloads(current: bool) -> tuple[list[dict], dict]:
    sources = [
        {"slug": slug,
         "source_variant": f"{slug}-26.8.2" if current else predecessor,
         "backup_sha256": format(index + 1, "064x")}
        for index, (slug, predecessor) in enumerate(zip(SLUGS, PREDECESSORS))
    ]
    evidence = {
        "schema": "makepad.keycloak-cohort-restore-evidence.v2",
        "result": "restored-databases-compatible",
        "postgres_run_id": 123,
        "postgres_run_attempt": 1,
        "postgres_head_sha": "a" * 40,
        "keycloak_release_sha": "b" * 40,
        "instances": [
            {"slug": source["slug"], "backup_sha256": source["backup_sha256"],
             "restore": "passed", "keycloak_startup": "passed",
             "configuration_regression": "passed"}
            for source in sources
        ],
    }
    return sources, evidence


class SourceReceiptTests(unittest.TestCase):
    def run_case(self, sources: list[dict], evidence: dict) -> tuple[subprocess.CompletedProcess, dict | None]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, evidence_path, output_path = (
                root / "sources.json", root / "evidence.json", root / "receipt.json")
            source_path.write_text(json.dumps(sources), encoding="utf-8")
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            proc = subprocess.run(["python3", str(SCRIPT), str(source_path),
                                   str(evidence_path), str(output_path)],
                                  capture_output=True, text=True)
            output = json.loads(output_path.read_text()) if output_path.exists() else None
            return proc, output

    def test_both_reviewed_predecessors_and_all_current_sources(self) -> None:
        for current in (False, True):
            with self.subTest(current=current):
                sources, evidence = payloads(current)
                proc, receipt = self.run_case(sources, evidence)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(receipt["schema"], "makepad.keycloak-cohort-source-variants.v1")
                self.assertEqual(receipt["instances"], sources)
                self.assertEqual(receipt["keycloak_release_sha"], evidence["keycloak_release_sha"])

    def test_cross_slug_variant_missing_instance_and_digest_drift_fail_closed(self) -> None:
        sources, evidence = payloads(True)
        cases = []
        wrong = copy.deepcopy(sources)
        wrong[1]["source_variant"] = "runtrace-26.8.2"
        cases.append((wrong, evidence))
        wrong = copy.deepcopy(evidence)
        wrong["instances"].pop(1)
        cases.append((sources, wrong))
        wrong = copy.deepcopy(evidence)
        wrong["instances"][2]["backup_sha256"] = "f" * 64
        cases.append((sources, wrong))
        wrong = copy.deepcopy(evidence)
        wrong["instances"][0]["configuration_regression"] = "failed"
        cases.append((sources, wrong))
        wrong = copy.deepcopy(sources)
        wrong[4]["backup_sha256"] = "not-a-sha256"
        cases.append((wrong, evidence))
        wrong = copy.deepcopy(sources)
        wrong[3]["unexpected"] = True
        cases.append((wrong, evidence))
        for index, (case_sources, case_evidence) in enumerate(cases):
            with self.subTest(case=index):
                proc, receipt = self.run_case(case_sources, case_evidence)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIsNone(receipt)


if __name__ == "__main__":
    unittest.main()
