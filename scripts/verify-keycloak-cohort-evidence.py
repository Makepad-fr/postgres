#!/usr/bin/env python3
"""Validate the immutable six-database Keycloak restore evidence contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

SCHEMA = "makepad.keycloak-cohort-restore-evidence.v2"
WORKFLOW = ".github/workflows/verify-keycloak-cohort-restores.yml"
BASE_IMAGE = "dhi.io/keycloak:26-debian13@sha256:fab1484b1762fd1269e63a40f068ec73ea75b498eaaa5d02f62f022a5d00ff0f"
CATEGORIES = {
    "realm",
    "authentication",
    "roles",
    "clients",
    "identity_providers",
    "components",
    "required_actions",
}
DATABASES = {
    "betacrew": "keycloak_betacrew",
    "catwlk": "keycloak_catwlk",
    "makepad": "keycloak_makepad",
    "runtrace": "keycloak_runtrace",
    "vestiaire": "keycloak_vestiaire",
    "vif": "keycloak_vif",
}
TOP_KEYS = {
    "schema",
    "postgres_repository",
    "postgres_workflow",
    "postgres_run_id",
    "postgres_run_attempt",
    "postgres_head_sha",
    "postgres_ref",
    "keycloak_release_sha",
    "keycloak_base_image",
    "catwlk_runtime_image_id",
    "fingerprint_schema",
    "keycloak_upstream_version",
    "result",
    "instances",
}
INSTANCE_KEYS = {
    "slug",
    "database",
    "backup_sha256",
    "runtime",
    "runtime_image",
    "configuration_fingerprint",
    "configuration_fingerprints",
    "restore",
    "keycloak_startup",
    "configuration_regression",
}


def positive_integer(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{label} must be a positive integer")
    return value


def exact_keys(value: object, expected: set[str], label: str) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError(f"{label} has unexpected fields")
    return value


def validate(
    path: Path,
    *,
    expected_run_id: int | None = None,
    expected_run_attempt: int | None = None,
    expected_head_sha: str | None = None,
    expected_keycloak_release_sha: str | None = None,
) -> dict[str, object]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024:
        raise ValueError("evidence must be a regular file no larger than 64 KiB")
    raw = path.read_bytes()
    if b"\x00" in raw:
        raise ValueError("evidence contains a NUL byte")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("evidence is not valid UTF-8 JSON") from error
    top = exact_keys(payload, TOP_KEYS, "evidence")
    run_id = positive_integer(top["postgres_run_id"], "postgres_run_id")
    attempt = positive_integer(top["postgres_run_attempt"], "postgres_run_attempt")
    if top["schema"] != SCHEMA:
        raise ValueError("unexpected evidence schema")
    if top["postgres_repository"] != "Makepad-fr/postgres" or top["postgres_workflow"] != WORKFLOW:
        raise ValueError("unexpected PostgreSQL producer identity")
    if top["postgres_ref"] != "refs/heads/main":
        raise ValueError("evidence did not originate from protected main")
    for label in ("postgres_head_sha", "keycloak_release_sha"):
        if not isinstance(top[label], str) or not re.fullmatch(r"[a-f0-9]{40}", top[label]):
            raise ValueError(f"{label} is not a lowercase commit SHA")
    if top["keycloak_base_image"] != BASE_IMAGE or top["keycloak_upstream_version"] != "26.7.3":
        raise ValueError("evidence is not bound to the reviewed Keycloak runtime")
    if not isinstance(top["catwlk_runtime_image_id"], str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", top["catwlk_runtime_image_id"]):
        raise ValueError("Catwlk runtime image ID is not immutable")
    if top["fingerprint_schema"] != "makepad.keycloak-config-fingerprint.v2":
        raise ValueError("unexpected configuration fingerprint schema")
    if top["result"] != "restored-databases-compatible":
        raise ValueError("cohort compatibility did not pass")
    instances = top["instances"]
    if not isinstance(instances, list) or len(instances) != len(DATABASES):
        raise ValueError("instances must contain the exact six-database cohort")
    expected_slugs = sorted(DATABASES)
    actual_slugs: list[str] = []
    for index, raw_instance in enumerate(instances):
        instance = exact_keys(raw_instance, INSTANCE_KEYS, f"instances[{index}]")
        slug = instance["slug"]
        if not isinstance(slug, str):
            raise ValueError("instance slug must be a string")
        actual_slugs.append(slug)
        if slug not in DATABASES or instance["database"] != DATABASES[slug]:
            raise ValueError("instance slug/database mapping is invalid")
        if not isinstance(instance["backup_sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", instance["backup_sha256"]):
            raise ValueError("backup_sha256 must be a lowercase SHA-256 digest")
        expected_runtime = "catwlk-custom-provider" if slug == "catwlk" else "keycloak-base"
        expected_image = top["catwlk_runtime_image_id"] if slug == "catwlk" else BASE_IMAGE
        if instance["runtime"] != expected_runtime or instance["runtime_image"] != expected_image:
            raise ValueError(f"{slug} runtime does not match its reviewed exact image")
        fingerprints = exact_keys(instance["configuration_fingerprints"], CATEGORIES, f"{slug} configuration fingerprints")
        for category, digest in fingerprints.items():
            if not isinstance(digest, str) or not re.fullmatch(r"[a-f0-9]{64}", digest):
                raise ValueError(f"{slug} {category} fingerprint is invalid")
        canonical_fingerprints = "".join(f"{category}={fingerprints[category]}\n" for category in sorted(CATEGORIES)).encode()
        combined = hashlib.sha256(canonical_fingerprints).hexdigest()
        if instance["configuration_fingerprint"] != combined:
            raise ValueError(f"{slug} combined configuration fingerprint is invalid")
        for status in ("restore", "keycloak_startup", "configuration_regression"):
            if instance[status] != "passed":
                raise ValueError(f"{slug} {status} did not pass")
    if actual_slugs != expected_slugs:
        raise ValueError("instances are duplicated, missing, or not sorted by slug")
    expected_values = (
        (expected_run_id, run_id, "run ID"),
        (expected_run_attempt, attempt, "run attempt"),
        (expected_head_sha, top["postgres_head_sha"], "PostgreSQL head SHA"),
        (expected_keycloak_release_sha, top["keycloak_release_sha"], "Keycloak release SHA"),
    )
    for expected, actual, label in expected_values:
        if expected is not None and expected != actual:
            raise ValueError(f"evidence {label} mismatch")
    canonical = json.dumps(top, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    if raw not in (canonical, canonical + b"\n"):
        raise ValueError("evidence JSON is not canonical")
    return top


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--run-attempt", type=int)
    parser.add_argument("--head-sha")
    parser.add_argument("--keycloak-release-sha")
    arguments = parser.parse_args()
    validate(
        arguments.path,
        expected_run_id=arguments.run_id,
        expected_run_attempt=arguments.run_attempt,
        expected_head_sha=arguments.head_sha,
        expected_keycloak_release_sha=arguments.keycloak_release_sha,
    )


if __name__ == "__main__":
    main()
