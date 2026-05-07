#!/usr/bin/env bash
set -euo pipefail

for binary in docker python3; do
  if ! command -v "${binary}" >/dev/null 2>&1; then
    echo "Missing required binary for postgres validation: ${binary}" >&2
    exit 1
  fi
done

if ! docker compose version >/dev/null 2>&1; then
  echo "Missing required Docker Compose plugin for postgres validation." >&2
  exit 1
fi

export MAKEPAD_POSTGRES_CATWLK_DB_NETWORK=makepad_keycloak_catwlk_db
export MAKEPAD_POSTGRES_VIF_DB_NETWORK=makepad_keycloak_vif_db
export MAKEPAD_POSTGRES_MAKEPAD_DB_NETWORK=makepad_keycloak_makepad_db
export MAKEPAD_POSTGRES_VESTIAIRE_DB_NETWORK=makepad_keycloak_vestiaire_db

for deploy_env in canary production; do
  docker compose \
    --env-file "envs/${deploy_env}/.env.db" \
    -f compose.yml \
    -f "envs/${deploy_env}/compose.yml" \
    config >/tmp/makepad-postgres-${deploy_env}-compose.yml
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
        "network_secret": "DEPLOY_VIF_DB_NETWORK",
        "network_env": "MAKEPAD_POSTGRES_VIF_DB_NETWORK",
        "network_name": "makepad_keycloak_vif_db",
    },
    "makepad": {
        "role": "keycloak_makepad_app",
        "database": "keycloak_makepad",
        "password_variable": "keycloak_makepad_app_password",
        "network_secret": "DEPLOY_MAKEPAD_DB_NETWORK",
        "network_env": "MAKEPAD_POSTGRES_MAKEPAD_DB_NETWORK",
        "network_name": "makepad_keycloak_makepad_db",
    },
    "vestiaire": {
        "role": "keycloak_vestiaire_app",
        "database": "keycloak_vestiaire",
        "password_variable": "keycloak_vestiaire_app_password",
        "network_secret": "DEPLOY_VESTIAIRE_DB_NETWORK",
        "network_env": "MAKEPAD_POSTGRES_VESTIAIRE_DB_NETWORK",
        "network_name": "makepad_keycloak_vestiaire_db",
    },
}

sql = Path("bootstrap/keycloak-new-instances.sql").read_text()
workflow = Path(".github/workflows/manual-deploy.yml").read_text()
readme = Path("README.md").read_text()
compose = Path("compose.yml").read_text()

require("makepad-postgres" in compose, "compose.yml must keep the stable makepad-postgres alias.")
require("DEPLOY_CATWLK_DB_NETWORK" in workflow, "workflow must still configure the Catwlk DB network.")
require("--driver overlay --attachable" in workflow, "workflow must create attachable overlay DB networks.")

for slug, expected in expected_instances.items():
    for field in ("role", "database", "password_variable"):
        require(expected[field] in sql, f"SQL bootstrap is missing {expected[field]} for {slug}.")
    require(f"CREATE ROLE {expected['role']} LOGIN" in sql, f"SQL bootstrap must create {slug} role idempotently.")
    require(f"CREATE DATABASE {expected['database']} OWNER {expected['role']}" in sql, f"SQL bootstrap must create {slug} database.")
    require(f"ALTER ROLE {expected['role']} LOGIN PASSWORD :'{expected['password_variable']}'" in sql, f"SQL bootstrap must set {slug} role password from a psql variable.")
    require(expected["network_secret"] in workflow, f"workflow is missing {expected['network_secret']}.")
    require(expected["network_env"] in workflow, f"workflow is missing {expected['network_env']}.")
    require(expected["network_name"] in workflow, f"workflow is missing default {expected['network_name']}.")
    require(expected["network_secret"] in readme, f"README is missing {expected['network_secret']}.")
    require(expected["database"] in readme, f"README is missing {expected['database']}.")

for literal in ("change-me", "password123"):
    require(literal not in sql, f"SQL bootstrap must not contain literal {literal}.")
PY
