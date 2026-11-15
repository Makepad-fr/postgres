#!/usr/bin/env python3
"""Bind the source-variant receipt to exact five-database restore evidence."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys


ALLOWED = {
    "catwlk": {"legacy-26.5.7", "catwlk-26.8.2"},
    "makepad": {"legacy-26.5.7", "makepad-26.8.2"},
    "runtrace": {"legacy-26.5.7", "runtrace-26.8.2"},
    "vestiaire": {"legacy-26.5.7", "vestiaire-26.8.2"},
    "vif": {"vif-26.7.3", "vif-26.8.2"},
}
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


def require(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key in source receipt input")
        result[key] = value
    return result


def read_json(path: Path) -> object:
    require(path.is_file() and not path.is_symlink(), "source receipt input is not a regular file")
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)


def build_receipt(sources: object, evidence: object) -> dict:
    slugs = sorted(ALLOWED)
    require(isinstance(evidence, dict)
            and evidence.get("schema") == "makepad.keycloak-cohort-restore-evidence.v2"
            and evidence.get("result") == "restored-databases-compatible",
            "compatibility evidence envelope differs")
    instances = evidence.get("instances")
    require(isinstance(instances, list) and len(instances) == len(slugs)
            and all(isinstance(item, dict) for item in instances)
            and [item.get("slug") for item in instances] == slugs,
            "compatibility evidence does not cover the exact ordered cohort")
    require(isinstance(sources, list) and len(sources) == len(slugs)
            and all(isinstance(item, dict) for item in sources)
            and [item.get("slug") for item in sources] == slugs,
            "source receipt does not cover the exact ordered cohort")
    for source, instance in zip(sources, instances):
        digest = source.get("backup_sha256")
        require(set(source) == {"slug", "source_variant", "backup_sha256"}
                and source["source_variant"] in ALLOWED[source["slug"]]
                and isinstance(digest, str) and SHA256.fullmatch(digest) is not None
                and digest == instance.get("backup_sha256")
                and all(instance.get(name) == "passed" for name in
                        ("restore", "keycloak_startup", "configuration_regression")),
                f"{source['slug']} source differs from compatible restored database")
    for name in ("postgres_run_id", "postgres_run_attempt"):
        require(type(evidence.get(name)) is int and evidence[name] > 0,
                "compatibility evidence run identity differs")
    for name in ("postgres_head_sha", "keycloak_release_sha"):
        value = evidence.get(name)
        require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value),
                "compatibility evidence source identity differs")
    return {
        "schema": "makepad.keycloak-cohort-source-variants.v1",
        "postgres_run_id": evidence["postgres_run_id"],
        "postgres_run_attempt": evidence["postgres_run_attempt"],
        "postgres_head_sha": evidence["postgres_head_sha"],
        "keycloak_release_sha": evidence["keycloak_release_sha"],
        "instances": sources,
    }


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: verify-keycloak-cohort-source-receipt.py <sources> <evidence> <new-output>")
    source_path, evidence_path, output_path = map(Path, sys.argv[1:])
    receipt = build_receipt(read_json(source_path), read_json(evidence_path))
    require(output_path.parent.is_dir() and not output_path.parent.is_symlink(),
            "source receipt output parent is unsafe")
    with output_path.open("x", encoding="utf-8") as output:
        json.dump(receipt, output, sort_keys=True, separators=(",", ":"))
        output.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc))
