#!/usr/bin/env bash
set -euo pipefail

for binary in python3; do
  if ! command -v "${binary}" >/dev/null 2>&1; then
    echo "Missing required binary for postgres validation: ${binary}" >&2
    exit 1
  fi
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)

REPO_ROOT="${repo_root}" python3 - <<'PY'
import os
import re
from pathlib import Path


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def read_required_text(path, label):
    require(path.is_file(), f"{label} is missing or is not a file: {path}")
    try:
        return path.read_text()
    except OSError as error:
        raise SystemExit(f"Unable to read {label} at {path}: {error}") from error


expected_instances = {
    "vif": {
        "role": "keycloak_vif_app",
        "database": "keycloak_vif",
        "password_variable": "keycloak_vif_app_password",
        "environment_variable": "KEYCLOAK_VIF_DB_PASSWORD",
    },
    "makepad": {
        "role": "keycloak_makepad_app",
        "database": "keycloak_makepad",
        "password_variable": "keycloak_makepad_app_password",
        "environment_variable": "KEYCLOAK_MAKEPAD_DB_PASSWORD",
    },
    "vestiaire": {
        "role": "keycloak_vestiaire_app",
        "database": "keycloak_vestiaire",
        "password_variable": "keycloak_vestiaire_app_password",
        "environment_variable": "KEYCLOAK_VESTIAIRE_DB_PASSWORD",
    },
}

repo_root = Path(os.environ["REPO_ROOT"])
sql = read_required_text(repo_root / "bootstrap/keycloak-new-instances.sql", "SQL bootstrap")
readme = read_required_text(repo_root / "README.md", "README")
normalized_readme = re.sub(r"\s+", " ", readme)

require("docker network create" not in sql, "SQL bootstrap must not manage Docker networks.")
require("${POSTGRES_ADMIN_URL:?" in readme, "README bootstrap command must fail fast for POSTGRES_ADMIN_URL.")
require("admin PostgreSQL connection URI" in normalized_readme, "README must define POSTGRES_ADMIN_URL as an admin PostgreSQL connection URI.")
require(
    re.search(r"role\s+that\s+can\s+create\s+roles\s+and\s+databases", normalized_readme, re.IGNORECASE),
    "README must document that POSTGRES_ADMIN_URL needs role/database creation privileges.",
)
require("<db-vm-host>" in normalized_readme, "README must document the standalone DB VM host connection path.")
require("makepad-postgres" in normalized_readme, "README must document the shared overlay service alias connection path.")
require(
    re.search(r"standalone\s+DB\s+VM\s+deployment.*expos(?:e|ing).*PostgreSQL.*VM\s+host", normalized_readme, re.IGNORECASE),
    "README must explain that host-based connections depend on the standalone DB VM deployment exposing PostgreSQL.",
)

for slug, expected in expected_instances.items():
    for field in ("role", "database", "password_variable"):
        require(expected[field] in sql, f"SQL bootstrap is missing {expected[field]} for {slug}.")
    require(f"CREATE ROLE {expected['role']} LOGIN" in sql, f"SQL bootstrap must create {slug} role idempotently.")
    require(f"CREATE DATABASE {expected['database']} OWNER {expected['role']}" in sql, f"SQL bootstrap must create {slug} database.")
    require(f"ALTER ROLE {expected['role']} LOGIN PASSWORD :'{expected['password_variable']}'" in sql, f"SQL bootstrap must set {slug} role password from a psql variable.")
    require(f"{expected['password_variable']}_is_nonempty" in sql, f"SQL bootstrap must reject empty {slug} passwords.")
    require(f"NULLIF(btrim(:'{expected['password_variable']}'), '')" in sql, f"SQL bootstrap must trim-check {slug} password emptiness.")
    require(expected["database"] in normalized_readme, f"README is missing {expected['database']}.")
    require(expected["role"] in normalized_readme, f"README is missing {expected['role']}.")
    require(f"${{{expected['environment_variable']}:?" in readme, f"README bootstrap command must fail fast for {expected['environment_variable']}.")

for literal in ("change-me", "password123"):
    require(literal not in sql, f"SQL bootstrap must not contain literal {literal}.")
PY
