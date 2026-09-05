#!/usr/bin/env python3
"""Validate the complete reviewed PostgreSQL Proton-to-GitHub mapping."""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any, NoReturn


REPOSITORY = "Makepad-fr/postgres"
VAULT = "Makepad"
REQUIRED = "required"


def github(item: str, **destinations: str) -> set[tuple[str, str, str, str]]:
    return {
        ("secret", destination, item, field)
        for destination, field in destinations.items()
    }


EXPECTED_GITHUB_ENTRIES = {
    "canary": (
        github(
            "Hetzner App Server makepad",
            DEPLOY_SSH_HOST="host",
            DEPLOY_SSH_PORT="port",
            DEPLOY_SSH_USER="user",
            DEPLOY_SSH_PRIVATE_KEY="private_key",
            DEPLOY_SSH_KNOWN_HOSTS="known_hosts",
        )
        | github(
            "PostgreSQL · shared Swarm deployment",
            DEPLOY_REMOTE_DIR="DEPLOY_REMOTE_DIR",
            DEPLOY_STACK_NAME="DEPLOY_STACK_NAME",
            DEPLOY_CATWLK_DB_NETWORK="DEPLOY_CATWLK_DB_NETWORK",
            DEPLOY_LE_PETIT_COIN_DB_NETWORK="DEPLOY_LE_PETIT_COIN_DB_NETWORK",
            DEPLOY_BRIO_STAGING_DB_NETWORK="DEPLOY_BRIO_STAGING_DB_NETWORK",
        )
        | github(
            "Brio Staging - PostgreSQL",
            POSTGRES_CANARY_SUPERUSER_PASSWORD="POSTGRES_CANARY_SUPERUSER_PASSWORD",
            BRIO_STAGING_DB_PASSWORD="BRIO_STAGING_DB_PASSWORD",
            BRIO_STAGING_BACKUP_DB_PASSWORD="BRIO_STAGING_BACKUP_DB_PASSWORD",
        )
        | github(
            "Brio Staging - PKI and Backup Keys",
            POSTGRES_CA_PEM="POSTGRES_CA_PEM",
            POSTGRES_SERVER_CERT_PEM="POSTGRES_SERVER_CERT_PEM",
            POSTGRES_SERVER_KEY_PEM="POSTGRES_SERVER_KEY_PEM",
            BRIO_BACKUP_RECIPIENT_CERT_PEM="BRIO_BACKUP_RECIPIENT_CERT_PEM",
        )
    ),
    "production": (
        github(
            "Hetzner App Server makepad",
            DEPLOY_SSH_HOST="host",
            DEPLOY_SSH_PORT="port",
            DEPLOY_SSH_USER="user",
            DEPLOY_SSH_PRIVATE_KEY="private_key",
            DEPLOY_SSH_KNOWN_HOSTS="known_hosts",
        )
        | github(
            "PostgreSQL · shared Swarm deployment",
            DEPLOY_REMOTE_DIR="DEPLOY_REMOTE_DIR",
            DEPLOY_STACK_NAME="DEPLOY_STACK_NAME",
            DEPLOY_CATWLK_DB_NETWORK="DEPLOY_CATWLK_DB_NETWORK",
            DEPLOY_LE_PETIT_COIN_DB_NETWORK="DEPLOY_LE_PETIT_COIN_DB_NETWORK",
            DEPLOY_VIF_DB_NETWORK="DEPLOY_VIF_DB_NETWORK",
            DEPLOY_VIF_DB_NAME="DEPLOY_VIF_DB_NAME",
            DEPLOY_VIF_DB_USER="DEPLOY_VIF_DB_USER",
            DEPLOY_VIF_DB_PASSWORD="DEPLOY_VIF_DB_PASSWORD",
        )
    ),
    "staging-brio-identity-db": (
        github(
            "Hetzner Database Server makepad",
            BRIO_IDENTITY_DB_DEPLOY_SSH_HOST="host",
            BRIO_IDENTITY_DB_DEPLOY_SSH_PORT="port",
            BRIO_IDENTITY_DB_DEPLOY_SSH_USER="user",
            BRIO_IDENTITY_DB_DEPLOY_SSH_PRIVATE_KEY="private_key",
            BRIO_IDENTITY_DB_DEPLOY_SSH_KNOWN_HOSTS="known_hosts",
        )
        | github(
            "Brio Staging - PostgreSQL",
            KEYCLOAK_BRIO_STAGING_DB_PASSWORD="KEYCLOAK_BRIO_STAGING_DB_PASSWORD",
            KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD="KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD",
        )
        | github(
            "Brio Staging - PKI and Backup Keys",
            BRIO_BACKUP_RECIPIENT_CERT_PEM="BRIO_BACKUP_RECIPIENT_CERT_PEM",
        )
        | {
            (
                "variable",
                "BRIO_IDENTITY_DB_HOSTNAME",
                "Brio Staging - PKI and Backup Keys",
                "BRIO_IDENTITY_DB_HOSTNAME",
            ),
            (
                "variable",
                "BRIO_KEYCLOAK_DB_SOURCE_CIDR",
                "Brio Staging - PKI and Backup Keys",
                "BRIO_KEYCLOAK_DB_SOURCE_CIDR",
            ),
        }
    ),
    "release-brio-identity-db": github(
        "PostgreSQL · Brio identity release orchestrator",
        KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN="KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN",
    ),
    "keycloak-cohort-restore": (
        github(
            "PostgreSQL · Keycloak cohort source reader",
            KEYCLOAK_COHORT_SOURCE_TOKEN="KEYCLOAK_COHORT_SOURCE_TOKEN",
        )
        | github(
            "Hetzner Database Server makepad",
            KEYCLOAK_COHORT_DB_SSH_HOST="host",
            KEYCLOAK_COHORT_DB_SSH_PORT="port",
            KEYCLOAK_COHORT_DB_SSH_USER="user",
            KEYCLOAK_COHORT_DB_SSH_PRIVATE_KEY="private_key",
            KEYCLOAK_COHORT_DB_SSH_KNOWN_HOSTS="known_hosts",
        )
        | github(
            "Makepad Docker Hardened Images",
            DHI_REGISTRY_USERNAME="DOCKERHUB_USERNAME",
            DHI_REGISTRY_PASSWORD="DOCKERHUB_PRO_PAT",
        )
    ),
    "postgres-ci-attestation": github(
        "PostgreSQL · PR Checks App",
        POSTGRES_PR_CHECK_APP_PRIVATE_KEY="private_key",
    ),
}

EXPECTED_REPOSITORY_VARIABLES = {
    (
        "POSTGRES_CI_LAUNCHER_APP_SENDER_ID",
        "PostgreSQL · JIT Launcher App",
        "bot_user_id",
    ),
    (
        "POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256",
        "PostgreSQL · JIT hypervisor attestation",
        "qcow2_sha256",
    ),
    (
        "POSTGRES_CI_ATTESTATION_PUBLIC_KEY",
        "PostgreSQL · JIT hypervisor attestation",
        "ed25519_public_key",
    ),
    (
        "POSTGRES_PR_CHECK_APP_ID",
        "PostgreSQL · PR Checks App",
        "app_id",
    ),
}

EXPECTED_NON_GITHUB_ENTRIES = {
    ("operator-verification", "PostgreSQL Checks App private-key fingerprint", "PostgreSQL · PR Checks App", "private_key_fingerprint"),
    ("host-root-setting", "/etc/makepad/postgres-ci/controller.env:POSTGRES_CI_LAUNCHER_APP_ID", "PostgreSQL · JIT Launcher App", "app_id"),
    ("host-root-setting", "/etc/makepad/postgres-ci/controller.env:POSTGRES_CI_LAUNCHER_APP_INSTALLATION_ID", "PostgreSQL · JIT Launcher App", "installation_id"),
    ("host-root-file", "/etc/makepad/postgres-ci/launcher-app-private-key.pem", "PostgreSQL · JIT Launcher App", "private_key"),
    ("operator-verification", "PostgreSQL Launcher App private-key fingerprint", "PostgreSQL · JIT Launcher App", "private_key_fingerprint"),
    ("host-root-setting", "/etc/makepad/postgres-ci/controller.env:POSTGRES_CI_REPOSITORY_ID", "PostgreSQL · JIT Launcher App", "repository_id"),
    ("host-root-file", "/etc/makepad/postgres-ci/attestation-private-key.pem", "PostgreSQL · JIT hypervisor attestation", "ed25519_private_key"),
    ("operator-verification", "PostgreSQL Ed25519 public-key fingerprint", "PostgreSQL · JIT hypervisor attestation", "public_key_fingerprint"),
    ("host-root-setting", "/etc/makepad/postgres-ci/controller.env:POSTGRES_CI_BASE_IMAGE_SHA256", "PostgreSQL · JIT hypervisor attestation", "qcow2_sha256"),
    ("operator-stdin", "scripts/configure-postgres-ci-runner-group.sh standard input", "PostgreSQL · runner-group controller", "organization_runner_admin_token"),
    ("host-root-file", "POSTGRES_HOST_ALERT_URL_FILE", "PostgreSQL · CI hypervisor alert", "url"),
}


def fail(message: str) -> NoReturn:
    raise SystemExit(f"credential inventory contract violation: {message}")


def exact_entries(entries: Any, keys: set[str], label: str) -> list[dict[str, str]]:
    if not isinstance(entries, list) or not entries:
        fail(f"{label} must be a non-empty list")
    for offset, entry in enumerate(entries):
        if not isinstance(entry, dict) or set(entry) != keys:
            fail(f"{label} entry {offset} has unexpected keys")
        if not all(isinstance(value, str) and value for value in entry.values()):
            fail(f"{label} entry {offset} contains invalid text")
        if entry.get("requirement") != REQUIRED:
            fail(f"{label} entry {offset} is not required")
    return entries


def validate_inventory(payload: Any) -> None:
    if not isinstance(payload, dict) or set(payload) != {
        "schemaVersion",
        "repository",
        "vault",
        "githubEntries",
        "repositoryVariables",
        "nonGitHubEntries",
    }:
        fail("top-level shape differs from the reviewed contract")
    if payload["schemaVersion"] != 1 or payload["repository"] != REPOSITORY or payload["vault"] != VAULT:
        fail("schema, repository, or vault identity differs from the reviewed contract")

    github_entries = exact_entries(
        payload["githubEntries"],
        {"environment", "kind", "requirement", "destination", "item", "field"},
        "GitHub environment",
    )
    actual_by_environment: dict[str, set[tuple[str, str, str, str]]] = {}
    for entry in github_entries:
        environment = entry["environment"]
        identity = (entry["kind"], entry["destination"], entry["item"], entry["field"])
        bucket = actual_by_environment.setdefault(environment, set())
        if identity in bucket:
            fail(f"duplicate GitHub mapping in {environment}")
        bucket.add(identity)
    if actual_by_environment != EXPECTED_GITHUB_ENTRIES:
        fail("per-environment kind/destination/item/field matrix differs from review")

    repository_entries = exact_entries(
        payload["repositoryVariables"],
        {"requirement", "destination", "item", "field"},
        "repository variable",
    )
    actual_repository = {
        (entry["destination"], entry["item"], entry["field"])
        for entry in repository_entries
    }
    if len(actual_repository) != len(repository_entries) or actual_repository != EXPECTED_REPOSITORY_VARIABLES:
        fail("repository-variable destination/item/field matrix differs from review")

    non_github_entries = exact_entries(
        payload["nonGitHubEntries"],
        {"boundary", "requirement", "destination", "item", "field"},
        "non-GitHub boundary",
    )
    actual_non_github = {
        (entry["boundary"], entry["destination"], entry["item"], entry["field"])
        for entry in non_github_entries
    }
    if len(actual_non_github) != len(non_github_entries) or actual_non_github != EXPECTED_NON_GITHUB_ENTRIES:
        fail("non-GitHub boundary/destination/item/field matrix differs from review")


def main() -> int:
    if len(sys.argv) != 2:
        fail("expected exactly one inventory path")
    path = pathlib.Path(sys.argv[1])
    if not path.is_file() or path.is_symlink():
        fail("inventory path is missing, non-regular, or symbolic")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"inventory cannot be parsed: {type(error).__name__}")
    validate_inventory(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
