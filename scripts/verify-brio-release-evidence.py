#!/usr/bin/env python3
"""Fail-closed validation for the two-phase Brio database release contract."""

from __future__ import annotations

import datetime as dt
import json
import re
import stat
import sys
import zipfile
from pathlib import Path


POSTGRES_REPOSITORY = "Makepad-fr/postgres"
POSTGRES_WORKFLOW = ".github/workflows/deploy-brio-identity-db.yml"
KEYCLOAK_REPOSITORY = "Makepad-fr/keycloak"
KEYCLOAK_WORKFLOW = ".github/workflows/verify-brio-database.yml"
SHA = re.compile(r"[0-9a-f]{40}")
POSITIVE = re.compile(r"[1-9][0-9]*")


def fail(message: str) -> None:
    raise SystemExit(message)


def load(path: str) -> object:
    with Path(path).open(encoding="utf-8") as source:
        return json.load(source)


def positive(value: str, label: str) -> int:
    if not POSITIVE.fullmatch(value):
        fail(f"{label} must be a positive integer")
    return int(value)


def full_sha(value: str, label: str) -> str:
    if not SHA.fullmatch(value):
        fail(f"{label} must be a lowercase full commit SHA")
    return value


def exact_object(value: object, expected: dict[str, object], label: str) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != set(expected):
        fail(f"{label} must have exactly the canonical fields")
    for key, expected_value in expected.items():
        if value.get(key) != expected_value:
            fail(f"{label} {key} mismatch")
    return value


def complete_listing(value: object, collection: str, label: str) -> list[object]:
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    rows = value.get(collection)
    total = value.get("total_count")
    if (
        not isinstance(rows, list)
        or isinstance(total, bool)
        or not isinstance(total, int)
        or total < 0
        or total != len(rows)
    ):
        fail(f"{label} is truncated or has an invalid total_count")
    identifiers = [row.get("id") for row in rows if isinstance(row, dict)]
    if len(identifiers) != len(rows) or any(isinstance(identifier, bool) or not isinstance(identifier, int) or identifier <= 0 for identifier in identifiers) or len(set(identifiers)) != len(identifiers):
        fail(f"{label} has missing or duplicate IDs")
    return rows


def safe_single_json(archive_path: str, expected_name: str) -> object:
    path = Path(archive_path)
    if not path.is_file() or path.is_symlink() or not 1 <= path.stat().st_size <= 131072:
        fail("Evidence archive is missing, symlinked, empty, or oversized")
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) != 1 or entries[0].filename != expected_name:
                fail("Evidence archive must contain exactly its canonical JSON file")
            entry = entries[0]
            if stat.S_ISLNK(entry.external_attr >> 16) or not 1 <= entry.file_size <= 65536:
                fail("Evidence archive entry is symlinked, empty, or oversized")
            if entry.compress_size > 131072:
                fail("Evidence archive entry has an unsafe compressed size")
            return json.loads(archive.read(entry))
    except (zipfile.BadZipFile, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"Evidence archive is invalid: {error}")


def postgres_run(arguments: list[str]) -> None:
    if len(arguments) != 5:
        fail("postgres-run expects run, workflow, artifacts, run ID, and attempt")
    run = load(arguments[0])
    workflow = load(arguments[1])
    artifacts = load(arguments[2])
    run_id = positive(arguments[3], "PostgreSQL run ID")
    attempt = positive(arguments[4], "PostgreSQL run attempt")
    if not isinstance(run, dict) or not isinstance(workflow, dict) or not isinstance(artifacts, dict):
        fail("GitHub metadata must be JSON objects")
    head_sha = full_sha(str(run.get("head_sha", "")), "PostgreSQL head SHA")
    expected = {
        "id": run_id,
        "run_attempt": attempt,
        "name": "Deploy Brio Identity Database",
        "path": POSTGRES_WORKFLOW,
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": head_sha,
        "status": "completed",
        "conclusion": "success",
    }
    for key, expected_value in expected.items():
        if run.get(key) != expected_value:
            fail(f"PostgreSQL deployment run {key} mismatch")
    if run.get("repository", {}).get("full_name") != POSTGRES_REPOSITORY:
        fail("PostgreSQL deployment repository mismatch")
    if (workflow.get("name"), workflow.get("path"), workflow.get("state")) != (
        "Deploy Brio Identity Database",
        POSTGRES_WORKFLOW,
        "active",
    ):
        fail("PostgreSQL deployment workflow identity mismatch")
    expected_name = f"brio-db-deployment-evidence-{run_id}-{attempt}"
    artifact_rows = complete_listing(artifacts, "artifacts", "PostgreSQL artifact listing")
    matches = [
        artifact
        for artifact in artifact_rows
        if artifact.get("name") == expected_name and not artifact.get("expired")
    ]
    if len(matches) != 1:
        fail("Expected exactly one unexpired PostgreSQL deployment evidence artifact")
    artifact = matches[0]
    artifact_id = artifact.get("id")
    size = artifact.get("size_in_bytes")
    if not isinstance(artifact_id, int) or artifact_id <= 0:
        fail("Invalid PostgreSQL deployment artifact ID")
    if not isinstance(size, int) or not 1 <= size <= 131072:
        fail("Unsafe PostgreSQL deployment artifact size")
    print(f"{artifact_id} {head_sha}")


def postgres_evidence(arguments: list[str]) -> None:
    if len(arguments) != 4:
        fail("postgres-evidence expects archive, run ID, attempt, and head SHA")
    run_id = positive(arguments[1], "PostgreSQL run ID")
    attempt = positive(arguments[2], "PostgreSQL run attempt")
    head_sha = full_sha(arguments[3], "PostgreSQL head SHA")
    evidence = safe_single_json(arguments[0], "brio-db-deployment-evidence.json")
    exact_object(
        evidence,
        {
            "schema": "makepad.brio-db-deployment-evidence.v1",
            "postgres_repository": POSTGRES_REPOSITORY,
            "postgres_workflow": POSTGRES_WORKFLOW,
            "postgres_run_id": run_id,
            "postgres_run_attempt": attempt,
            "postgres_head_sha": head_sha,
            "postgres_ref": "refs/heads/main",
            "deployment": "brio-db-host-ready",
            "database": "keycloak_brio_staging",
            "role": "keycloak_brio_staging_app",
            "tls_host": "65.21.134.125",
            "keycloak_source_cidr": "88.99.209.165/32",
        },
        "PostgreSQL deployment evidence",
    )


def keycloak_main(arguments: list[str]) -> None:
    if len(arguments) != 1:
        fail("keycloak-main expects the ref response")
    payload = load(arguments[0])
    if not isinstance(payload, dict):
        fail("Keycloak ref response must be an object")
    print(full_sha(str(payload.get("object", {}).get("sha", "")), "Keycloak main SHA"))


def verifier_run_select(arguments: list[str]) -> None:
    if len(arguments) != 5:
        fail("verifier-run-select expects runs, PostgreSQL run/attempt, Keycloak SHA, and dispatch time")
    payload = load(arguments[0])
    run_id = positive(arguments[1], "PostgreSQL run ID")
    attempt = positive(arguments[2], "PostgreSQL run attempt")
    keycloak_sha = full_sha(arguments[3], "Keycloak release SHA")
    try:
        started = dt.datetime.fromisoformat(arguments[4].replace("Z", "+00:00"))
    except ValueError as error:
        fail(f"Invalid dispatch timestamp: {error}")
    expected_title = f"Verify Brio DB path for PostgreSQL run {run_id}/{attempt} at Keycloak {keycloak_sha}"
    matches: list[int] = []
    if not isinstance(payload, dict):
        fail("Verifier run listing must be an object")
    for run in complete_listing(payload, "workflow_runs", "Keycloak verifier run listing"):
        try:
            created = dt.datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
        except (KeyError, ValueError):
            continue
        if (
            run.get("display_title") == expected_title
            and run.get("name") == "Verify Brio Identity Database Path"
            and run.get("path") == KEYCLOAK_WORKFLOW
            and run.get("repository", {}).get("full_name") == KEYCLOAK_REPOSITORY
            and run.get("head_branch") == "main"
            and run.get("head_sha") == keycloak_sha
            and run.get("event") == "workflow_dispatch"
            and created >= started - dt.timedelta(minutes=2)
        ):
            matches.append(run.get("id"))
    if len(matches) > 1:
        fail("Ambiguous Keycloak verifier runs")
    if len(matches) == 1:
        if not isinstance(matches[0], int) or matches[0] <= 0:
            fail("Invalid Keycloak verifier run ID")
        print(matches[0])


def verifier_run(arguments: list[str]) -> None:
    if len(arguments) != 5:
        fail("verifier-run expects run, PostgreSQL run/attempt, Keycloak SHA, and verifier run ID")
    run = load(arguments[0])
    postgres_run_id = positive(arguments[1], "PostgreSQL run ID")
    postgres_attempt = positive(arguments[2], "PostgreSQL run attempt")
    keycloak_sha = full_sha(arguments[3], "Keycloak release SHA")
    verifier_id = positive(arguments[4], "Keycloak verifier run ID")
    expected = {
        "id": verifier_id,
        "run_attempt": 1,
        "name": "Verify Brio Identity Database Path",
        "display_title": f"Verify Brio DB path for PostgreSQL run {postgres_run_id}/{postgres_attempt} at Keycloak {keycloak_sha}",
        "path": KEYCLOAK_WORKFLOW,
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": keycloak_sha,
        "status": "completed",
        "conclusion": "success",
    }
    if not isinstance(run, dict):
        fail("Keycloak verifier run must be an object")
    for key, expected_value in expected.items():
        if run.get(key) != expected_value:
            fail(f"Keycloak verifier run {key} mismatch")
    if run.get("repository", {}).get("full_name") != KEYCLOAK_REPOSITORY:
        fail("Keycloak verifier repository mismatch")


def attestation_artifact(arguments: list[str]) -> None:
    if len(arguments) != 3:
        fail("attestation-artifact expects artifacts, verifier run ID, and attempt")
    payload = load(arguments[0])
    run_id = positive(arguments[1], "Keycloak verifier run ID")
    attempt = positive(arguments[2], "Keycloak verifier run attempt")
    expected_name = f"brio-db-path-attestation-{run_id}-{attempt}"
    artifacts = complete_listing(payload, "artifacts", "Keycloak attestation artifact listing")
    matches = [
        artifact
        for artifact in artifacts
        if artifact.get("name") == expected_name and not artifact.get("expired")
    ]
    if len(matches) != 1:
        fail("Expected exactly one unexpired Keycloak path attestation artifact")
    artifact = matches[0]
    artifact_id, size = artifact.get("id"), artifact.get("size_in_bytes")
    if not isinstance(artifact_id, int) or artifact_id <= 0:
        fail("Invalid Keycloak attestation artifact ID")
    if not isinstance(size, int) or not 1 <= size <= 131072:
        fail("Unsafe Keycloak attestation artifact size")
    print(artifact_id)


def attestation(arguments: list[str]) -> None:
    if len(arguments) != 7:
        fail("attestation expects archive, PostgreSQL run/attempt/SHA, Keycloak run/attempt/SHA")
    postgres_run = positive(arguments[1], "PostgreSQL run ID")
    postgres_attempt = positive(arguments[2], "PostgreSQL run attempt")
    postgres_sha = full_sha(arguments[3], "PostgreSQL head SHA")
    keycloak_run = positive(arguments[4], "Keycloak verifier run ID")
    keycloak_attempt = positive(arguments[5], "Keycloak verifier run attempt")
    keycloak_sha = full_sha(arguments[6], "Keycloak release SHA")
    evidence = safe_single_json(arguments[0], "brio-db-path-attestation.json")
    exact_object(
        evidence,
        {
            "schema": "makepad.brio-db-path-attestation.v1",
            "postgres_repository": POSTGRES_REPOSITORY,
            "postgres_workflow": POSTGRES_WORKFLOW,
            "postgres_run_id": postgres_run,
            "postgres_run_attempt": postgres_attempt,
            "postgres_head_sha": postgres_sha,
            "keycloak_repository": KEYCLOAK_REPOSITORY,
            "keycloak_workflow": KEYCLOAK_WORKFLOW,
            "keycloak_verifier_run_id": keycloak_run,
            "keycloak_verifier_run_attempt": keycloak_attempt,
            "keycloak_release_sha": keycloak_sha,
            "probe": "brio-db-path-ok",
            "database": "keycloak_brio_staging",
            "role": "keycloak_brio_staging_app",
            "tls_host": "65.21.134.125",
            "keycloak_source_cidr": "88.99.209.165/32",
        },
        "Keycloak database-path attestation",
    )


COMMANDS = {
    "postgres-run": postgres_run,
    "postgres-evidence": postgres_evidence,
    "keycloak-main": keycloak_main,
    "verifier-run-select": verifier_run_select,
    "verifier-run": verifier_run,
    "attestation-artifact": attestation_artifact,
    "attestation": attestation,
}

if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
    fail("Usage: verify-brio-release-evidence.py <command> [arguments ...]")
COMMANDS[sys.argv[1]](sys.argv[2:])
