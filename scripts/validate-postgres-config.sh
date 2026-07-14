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
        return path.read_text(encoding="utf-8")
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
    "runtrace": {
        "role": "keycloak_runtrace_app",
        "database": "keycloak_runtrace",
        "password_variable": "keycloak_runtrace_app_password",
        "environment_variable": "KEYCLOAK_RUNTRACE_DB_PASSWORD",
    },
}

repo_root = Path(os.environ["REPO_ROOT"])
sql = read_required_text(repo_root / "bootstrap/keycloak-new-instances.sql", "SQL bootstrap")
runtrace_sql = read_required_text(repo_root / "bootstrap/runtrace-app.sql", "Runtrace app SQL bootstrap")
fashion_sql = read_required_text(repo_root / "bootstrap/fashion-app.sql", "Fashion app SQL bootstrap")
readme = read_required_text(repo_root / "README.md", "README")
base_compose = read_required_text(repo_root / "compose.yml", "base Compose file")
canary_compose = read_required_text(repo_root / "envs/canary/compose.yml", "canary Compose override")
production_compose = read_required_text(repo_root / "envs/production/compose.yml", "production Compose override")
manual_deploy = read_required_text(repo_root / ".github/workflows/manual-deploy.yml", "manual deploy workflow")
normalized_readme = re.sub(r"\s+", " ", readme)

require("docker network create" not in sql, "SQL bootstrap must not manage Docker networks.")
require("${POSTGRES_ADMIN_URL:?" in readme, "README bootstrap command must fail fast for POSTGRES_ADMIN_URL.")
require("PostgreSQL superuser connection URI" in normalized_readme, "README must define POSTGRES_ADMIN_URL as a PostgreSQL superuser connection URI.")
require(
    re.search(r"creates\s+roles.*sets\s+passwords.*creates\s+databases.*assigns\s+database\s+ownership", normalized_readme, re.IGNORECASE),
    "README must document that the bootstrap requires superuser-level role and database ownership privileges.",
)
require("PostgreSQL superuser connection" in sql, "SQL bootstrap must document its superuser connection requirement.")
require("pg_advisory_lock" in sql, "SQL bootstrap must serialize concurrent runs with an advisory lock.")
require("pg_advisory_unlock" in sql, "SQL bootstrap must release its advisory lock after provisioning.")
password_check_index = sql.find("keycloak_runtrace_app_password_is_nonempty")
lock_index = sql.find("pg_advisory_lock")
role_block_index = sql.find("DO $$")
require(password_check_index != -1, "SQL bootstrap must include the Vestiaire password non-empty check marker.")
require(lock_index != -1, "SQL bootstrap must include the advisory lock marker.")
require(role_block_index != -1, "SQL bootstrap must include the first role provisioning DO block marker.")
require(
    password_check_index < lock_index < role_block_index,
    "SQL bootstrap must validate required password variables before waiting on the advisory lock.",
)
require("<db-vm-host>" in normalized_readme, "README must document the standalone DB VM host connection path.")
require("`makepad-postgres`" in normalized_readme, "README must document the exact shared overlay service alias connection path.")
require(
    re.search(r"standalone\s+DB\s+VM\s+deployment.*expos(?:e|ing).*PostgreSQL.*VM\s+host", normalized_readme, re.IGNORECASE),
    "README must explain that host-based connections depend on the standalone DB VM deployment exposing PostgreSQL.",
)
require("MAKEPAD_POSTGRES_DB_NETWORK" in normalized_readme, "README must document the Compose network variable.")
require("MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK" in normalized_readme, "README must document the Le Petit Coin Compose network variable.")
require("MAKEPAD_POSTGRES_VIF_DB_NETWORK" in normalized_readme, "README must document the production VIF Compose network variable.")
require("MAKEPAD_POSTGRES_FASHION_DB_NETWORK" in normalized_readme, "README must document the production Fashion Compose network variable.")
require(
    "`${MAKEPAD_POSTGRES_DB_NETWORK}` <- `DEPLOY_CATWLK_DB_NETWORK`" in normalized_readme,
    "README must document that DEPLOY_CATWLK_DB_NETWORK feeds MAKEPAD_POSTGRES_DB_NETWORK during deploy.",
)
require(
    "`${MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK}` <- `DEPLOY_LE_PETIT_COIN_DB_NETWORK`" in normalized_readme,
    "README must document that DEPLOY_LE_PETIT_COIN_DB_NETWORK feeds MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK during deploy.",
)
require(
    "`${MAKEPAD_POSTGRES_VIF_DB_NETWORK}` <- `DEPLOY_VIF_DB_NETWORK`" in normalized_readme,
    "README must document that DEPLOY_VIF_DB_NETWORK feeds MAKEPAD_POSTGRES_VIF_DB_NETWORK during production deploy.",
)
require(
    "`${MAKEPAD_POSTGRES_FASHION_DB_NETWORK}` <- `DEPLOY_FASHION_DB_NETWORK`" in normalized_readme,
    "README must document that DEPLOY_FASHION_DB_NETWORK feeds MAKEPAD_POSTGRES_FASHION_DB_NETWORK during production deploy.",
)
require("makepad-postgres-le-petit-coin" in normalized_readme, "README must document the Le Petit Coin database network alias.")
require("makepad-postgres-vif" in normalized_readme, "README must document the VIF database network alias.")
require("makepad-postgres-fashion" in normalized_readme, "README must document the Fashion database network alias.")
require("Canary does not attach the VIF or Fashion networks" in readme, "README must document that VIF and Fashion network attachment is production-only.")
require("DEPLOY_VIF_DB_PASSWORD" in normalized_readme, "README must document the production VIF database password secret.")
require("DEPLOY_VIF_DB_NAME" in normalized_readme, "README must document the optional production VIF database name override.")
require("DEPLOY_VIF_DB_USER" in normalized_readme, "README must document the optional production VIF database user override.")
require("DEPLOY_FASHION_DB_PASSWORD" in normalized_readme, "README must document the production Fashion database password secret.")
require("DEPLOY_FASHION_DB_NAME" in normalized_readme, "README must document the optional production Fashion database name override.")
require("DEPLOY_FASHION_DB_USER" in normalized_readme, "README must document the optional production Fashion database user override.")
require("DEPLOY_SSH_USER=root" in normalized_readme, "README must document that the deploy workflow rejects root SSH users.")
require("makepad-postgres-vif" not in base_compose, "Base Compose file must not attach VIF; VIF is production-only.")
require("makepad-postgres-fashion" not in base_compose, "Base Compose file must not attach Fashion; Fashion is production-only.")
require("MAKEPAD_POSTGRES_VIF_DB_NETWORK" not in canary_compose, "Canary Compose override must not require the VIF network variable.")
require("MAKEPAD_POSTGRES_FASHION_DB_NETWORK" not in canary_compose, "Canary Compose override must not require the Fashion network variable.")
require("makepad-postgres-vif" in production_compose, "Production Compose override must expose the VIF database alias.")
require("makepad-postgres-fashion" in production_compose, "Production Compose override must expose the Fashion database alias.")
require("name: ${MAKEPAD_POSTGRES_VIF_DB_NETWORK}" in production_compose, "Production Compose override must map the VIF network variable.")
require("name: ${MAKEPAD_POSTGRES_FASHION_DB_NETWORK}" in production_compose, "Production Compose override must map the Fashion network variable.")
require("DEPLOY_SSH_USER must not be root" in manual_deploy, "Manual deploy workflow must reject root SSH users.")
require("DEPLOY_VIF_DB_NETWORK production environment secret" in manual_deploy, "Manual deploy workflow must require VIF network secret only for production.")
require("DEPLOY_FASHION_DB_NETWORK production environment secret" in manual_deploy, "Manual deploy workflow must require Fashion network secret only for production.")
require('if [[ "${deploy_env}" == "production" ]]; then' in manual_deploy, "Manual deploy workflow must gate VIF setup to production.")
require('if [[ "${vif_enabled}" != "1" ]]; then' in manual_deploy, "Manual deploy workflow must skip VIF provisioning outside production.")
require("postgres_ready=0" in manual_deploy, "Manual deploy workflow must track Postgres readiness.")
require("Postgres did not become reachable via makepad-postgres-vif" in manual_deploy, "Manual deploy workflow must fail clearly when VIF readiness times out.")
require("Postgres did not become reachable via makepad-postgres-fashion" in manual_deploy, "Manual deploy workflow must fail clearly when Fashion readiness times out.")
require(
    not re.search(r"\S\\gexec", manual_deploy),
    "Manual deploy workflow must separate every VIF provisioning \\gexec command from SQL text by whitespace.",
)
require("ALTER ROLE %I LOGIN PASSWORD %L" in manual_deploy, "Manual deploy workflow must always refresh the VIF role password.")
require("ALTER DATABASE %I OWNER TO %I" in manual_deploy, "Manual deploy workflow must repair VIF database ownership drift.")
require(
    sql.count("DO $$") == len(expected_instances),
    "SQL bootstrap must use one DO block for each expected role.",
)
require(
    sql.count("END;\n$$;") == len(expected_instances),
    "Each SQL bootstrap DO block must terminate the PL/pgSQL block with END; before $$.",
)
require(
    sql.count(r"\gexec") == 2 * len(expected_instances),
    "SQL bootstrap must use psql gexec commands for conditional database creation and ownership repair.",
)
require(
    not re.search(r"\S\\gexec", sql),
    "Each SQL bootstrap \\gexec command must be separated from SQL text by whitespace.",
)

for slug, expected in expected_instances.items():
    for field in ("role", "database", "password_variable"):
        require(expected[field] in sql, f"SQL bootstrap is missing {expected[field]} for {slug}.")
    require(f"CREATE ROLE {expected['role']} LOGIN" in sql, f"SQL bootstrap must create {slug} role idempotently.")
    require(f"CREATE DATABASE {expected['database']} OWNER {expected['role']}" in sql, f"SQL bootstrap must create {slug} database.")
    require(f"ALTER ROLE {expected['role']} LOGIN PASSWORD :'{expected['password_variable']}'" in sql, f"SQL bootstrap must set {slug} role password from a psql variable.")
    require(f"ALTER DATABASE {expected['database']} OWNER TO {expected['role']}" in sql, f"SQL bootstrap must be able to repair {slug} database ownership.")
    require(f"WHERE d.datname = '{expected['database']}'" in sql, f"SQL bootstrap must check current {slug} database ownership before altering it.")
    require(f"r.rolname <> '{expected['role']}'" in sql, f"SQL bootstrap must avoid altering {slug} database ownership when it is already correct.")
    require(f"{expected['password_variable']}_is_nonempty" in sql, f"SQL bootstrap must reject empty {slug} passwords.")
    require(f"NULLIF(btrim(:'{expected['password_variable']}'), '')" in sql, f"SQL bootstrap must trim-check {slug} password emptiness.")
    require(expected["database"] in normalized_readme, f"README is missing {expected['database']}.")
    require(expected["role"] in normalized_readme, f"README is missing {expected['role']}.")
    require(f"${{{expected['environment_variable']}:?" in readme, f"README bootstrap command must fail fast for {expected['environment_variable']}.")

for literal in ("change-me", "password123"):
    require(literal not in sql, f"SQL bootstrap must not contain literal {literal}.")

for expected in ("runtrace_app", "runtrace", "runtrace_app_password"):
    require(expected in runtrace_sql, f"Runtrace app SQL bootstrap is missing {expected}.")
require("PostgreSQL superuser connection" in runtrace_sql, "Runtrace app SQL bootstrap must document its superuser connection requirement.")
require("pg_advisory_lock" in runtrace_sql, "Runtrace app SQL bootstrap must serialize concurrent runs with an advisory lock.")
require("pg_advisory_unlock" in runtrace_sql, "Runtrace app SQL bootstrap must release its advisory lock after provisioning.")
require("ALTER ROLE runtrace_app LOGIN PASSWORD :'runtrace_app_password'" in runtrace_sql, "Runtrace app SQL bootstrap must set the role password from a psql variable.")
require("CREATE DATABASE runtrace OWNER runtrace_app" in runtrace_sql, "Runtrace app SQL bootstrap must create the Runtrace database.")
require("ALTER DATABASE runtrace OWNER TO runtrace_app" in runtrace_sql, "Runtrace app SQL bootstrap must repair Runtrace database ownership drift.")
require("NULLIF(btrim(:'runtrace_app_password'), '')" in runtrace_sql, "Runtrace app SQL bootstrap must reject empty passwords.")
require("runtrace_app" in normalized_readme, "README must document the Runtrace app role.")
require("keycloak_runtrace_app" in normalized_readme, "README must document the Runtrace Keycloak role.")
require("${RUNTRACE_DB_PASSWORD:?" in readme, "README bootstrap command must fail fast for RUNTRACE_DB_PASSWORD.")
require("${KEYCLOAK_RUNTRACE_DB_PASSWORD:?" in readme, "README bootstrap command must fail fast for KEYCLOAK_RUNTRACE_DB_PASSWORD.")

for expected in ("fashion_crawler", "fashion", "fashion_crawler_password"):
    require(expected in fashion_sql, f"Fashion app SQL bootstrap is missing {expected}.")
require("PostgreSQL superuser connection" in fashion_sql, "Fashion app SQL bootstrap must document its superuser connection requirement.")
require("pg_advisory_lock" in fashion_sql, "Fashion app SQL bootstrap must serialize concurrent runs with an advisory lock.")
require("pg_advisory_unlock" in fashion_sql, "Fashion app SQL bootstrap must release its advisory lock after provisioning.")
require("ALTER ROLE fashion_crawler LOGIN PASSWORD :'fashion_crawler_password'" in fashion_sql, "Fashion app SQL bootstrap must set the role password from a psql variable.")
require("CREATE DATABASE fashion OWNER fashion_crawler" in fashion_sql, "Fashion app SQL bootstrap must create the Fashion database.")
require("ALTER DATABASE fashion OWNER TO fashion_crawler" in fashion_sql, "Fashion app SQL bootstrap must repair Fashion database ownership drift.")
require("NULLIF(btrim(:'fashion_crawler_password'), '')" in fashion_sql, "Fashion app SQL bootstrap must reject empty passwords.")
require("fashion_crawler" in normalized_readme, "README must document the Fashion app role.")
require("${FASHION_DB_PASSWORD:?" in readme, "README bootstrap command must fail fast for FASHION_DB_PASSWORD.")
PY
