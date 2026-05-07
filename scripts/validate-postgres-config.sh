#!/usr/bin/env bash
set -euo pipefail

for binary in python3; do
  if ! command -v "${binary}" >/dev/null 2>&1; then
    echo "Missing required binary for postgres validation: ${binary}" >&2
    exit 1
  fi
done

python3 - <<'PY'
from pathlib import Path


def require(condition, message):
    if not condition:
        raise SystemExit(message)


expected_instances = {
    "vif": {
        "role": "keycloak_vif_app",
        "database": "keycloak_vif",
        "password_variable": "keycloak_vif_app_password",
    },
    "makepad": {
        "role": "keycloak_makepad_app",
        "database": "keycloak_makepad",
        "password_variable": "keycloak_makepad_app_password",
    },
    "vestiaire": {
        "role": "keycloak_vestiaire_app",
        "database": "keycloak_vestiaire",
        "password_variable": "keycloak_vestiaire_app_password",
    },
}

sql = Path("bootstrap/keycloak-new-instances.sql").read_text()
readme = Path("README.md").read_text()

require("docker network create" not in sql, "SQL bootstrap must not manage Docker networks.")

for slug, expected in expected_instances.items():
    for field in ("role", "database", "password_variable"):
        require(expected[field] in sql, f"SQL bootstrap is missing {expected[field]} for {slug}.")
    require(f"CREATE ROLE {expected['role']} LOGIN" in sql, f"SQL bootstrap must create {slug} role idempotently.")
    require(f"CREATE DATABASE {expected['database']} OWNER {expected['role']}" in sql, f"SQL bootstrap must create {slug} database.")
    require(f"ALTER ROLE {expected['role']} LOGIN PASSWORD :'{expected['password_variable']}'" in sql, f"SQL bootstrap must set {slug} role password from a psql variable.")
    require(expected["database"] in readme, f"README is missing {expected['database']}.")
    require(expected["role"] in readme, f"README is missing {expected['role']}.")

for literal in ("change-me", "password123"):
    require(literal not in sql, f"SQL bootstrap must not contain literal {literal}.")
PY
