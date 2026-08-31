#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "Missing required binary for postgres validation: python3" >&2
  exit 1
fi

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
keycloak_runtrace_sql = read_required_text(repo_root / "bootstrap/keycloak-runtrace-app.sql", "targeted Runtrace Keycloak SQL bootstrap")
openpanel_sql = read_required_text(repo_root / "bootstrap/openpanel-app.sql", "OpenPanel app SQL bootstrap")
readme = read_required_text(repo_root / "README.md", "README")
base_compose = read_required_text(repo_root / "compose.yml", "base Compose file")
host_compose = read_required_text(repo_root / "compose.host.yml", "host Compose file")
runtrace_hba = read_required_text(repo_root / "config/runtrace-pg_hba.conf", "Runtrace HBA policy")
runtrace_backup = read_required_text(repo_root / "scripts/run-runtrace-backup.sh", "Runtrace backup script")
runtrace_backup_loop = read_required_text(repo_root / "scripts/run-runtrace-backup-loop.sh", "Runtrace backup loop")
runtrace_restore = read_required_text(repo_root / "scripts/verify-runtrace-restore.sh", "Runtrace restore verifier")
runtrace_backup_test = read_required_text(repo_root / "scripts/test-runtrace-backup.sh", "Runtrace backup contract test")
canary_compose = read_required_text(repo_root / "envs/canary/compose.yml", "canary Compose override")
production_compose = read_required_text(repo_root / "envs/production/compose.yml", "production Compose override")
canary_env = read_required_text(repo_root / "envs/canary/.env.db", "canary database environment")
production_env = read_required_text(repo_root / "envs/production/.env.db", "production database environment")
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
    re.search(r"production\s+override\s+publishes\s+PostgreSQL\s+port\s+5432\s+in\s+host\s+mode", normalized_readme, re.IGNORECASE),
    "README must explain how production exposes PostgreSQL to DB VM clients.",
)
require("MAKEPAD_POSTGRES_DB_NETWORK" in normalized_readme, "README must document the Compose network variable.")
require("MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK" in normalized_readme, "README must document the Le Petit Coin Compose network variable.")
require("MAKEPAD_POSTGRES_VIF_DB_NETWORK" in normalized_readme, "README must document the production VIF Compose network variable.")
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
require("makepad-postgres-le-petit-coin" in normalized_readme, "README must document the Le Petit Coin database network alias.")
require("makepad-postgres-vif" in normalized_readme, "README must document the VIF database network alias.")
require("Canary does not attach the VIF network" in readme, "README must document that VIF network attachment is production-only.")
require("DEPLOY_VIF_DB_PASSWORD" in normalized_readme, "README must document the production VIF database password secret.")
require("DEPLOY_VIF_DB_NAME" in normalized_readme, "README must document the optional production VIF database name override.")
require("DEPLOY_VIF_DB_USER" in normalized_readme, "README must document the optional production VIF database user override.")
require("DEPLOY_SSH_USER=root" in normalized_readme, "README must document that the deploy workflow rejects root SSH users.")
require("makepad-postgres-vif" not in base_compose, "Base Compose file must not attach VIF; VIF is production-only.")
require("MAKEPAD_POSTGRES_VIF_DB_NETWORK" not in canary_compose, "Canary Compose override must not require the VIF network variable.")
require("makepad-postgres-vif" in production_compose, "Production Compose override must expose the VIF database alias.")
require("name: ${MAKEPAD_POSTGRES_VIF_DB_NETWORK}" in production_compose, "Production Compose override must map the VIF network variable.")
for required in ("target: 5432", "published: 5432", "protocol: tcp", "mode: host"):
    require(required in production_compose, f"Production Compose must publish PostgreSQL for DB VM clients: {required}")
require("DEPLOY_SSH_USER must not be root" in manual_deploy, "Manual deploy workflow must reject root SSH users.")
require("postgres:18-alpine@sha256:" in base_compose, "Base Compose must pin PostgreSQL 18 to an immutable digest.")
require("PGDATA: /var/lib/postgresql/data" in base_compose, "Base Compose must explicitly retain the mounted PGDATA path under PostgreSQL 18.")
require("pg_isready" in base_compose, "Base Compose must define a PostgreSQL healthcheck.")
for required in (
    "network_mode: host",
    "ssl=on",
    "ssl_cert_file=/etc/postgresql/tls/server.crt",
    "ssl_key_file=/etc/postgresql/tls/server.key",
    "hba_file=/etc/postgresql/runtrace-pg_hba.conf",
    "POSTGRES_PASSWORD_FILE: /run/secrets/postgres_superuser_password",
    "/run/secrets/postgres_superuser_password:ro",
    "runtrace_backup:",
    "PGSSLMODE: verify-full",
    "PGHOST: 127.0.0.1",
    "PGUSER: makepad_backup",
    "POSTGRES_BACKUP_PASSWORD_FILE: /run/secrets/postgres_backup_password",
):
    require(required in host_compose, f"Host Compose is missing production control: {required}")
for required in (
    "ssl=on",
    "ssl_cert_file=/etc/postgresql/tls/server.crt",
    "ssl_key_file=/run/secrets/postgres_server.key",
    "hba_file=/etc/postgresql/runtrace-pg_hba.conf",
    "MAKEPAD_POSTGRES_TLS_CERT_CONFIG",
    "MAKEPAD_POSTGRES_TLS_KEY_SECRET",
):
    require(required in base_compose, f"Base Compose is missing PostgreSQL TLS setting: {required}")
for database in ("runtrace", "keycloak_runtrace"):
    require(re.search(rf"^hostnossl\s+{database}\s+all\s+all\s+reject$", runtrace_hba, re.MULTILINE), f"HBA must reject plaintext access to {database}.")
    require(re.search(rf"^hostssl\s+{database}\s+all\s+all\s+scram-sha-256$", runtrace_hba, re.MULTILINE), f"HBA must require TLS and SCRAM for {database}.")
for label, content in (("canary", canary_env), ("production", production_env)):
    require("POSTGRES_PASSWORD=" not in content, f"{label} database environment must not contain POSTGRES_PASSWORD.")
    require("POSTGRES_IMAGE=postgres:18-alpine@sha256:" in content, f"{label} database environment must pin PostgreSQL 18.")
    require("MAKEPAD_POSTGRES_EXPECTED_DATA_MAJOR=18" in content, f"{label} database environment must gate the data directory at PostgreSQL 18.")
    require("MAKEPAD_POSTGRES_SUPERUSER_PASSWORD_FILE_HOST_PATH=" in content, f"{label} database environment must define the host password-file path.")
    require("MAKEPAD_POSTGRES_TLS_CERT_CONFIG=" in content, f"{label} database environment must name the TLS certificate config.")
    require("MAKEPAD_POSTGRES_TLS_KEY_SECRET=" in content, f"{label} database environment must name the TLS private-key secret.")
    require("MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG=" in content, f"{label} database environment must name the versioned Runtrace HBA config.")
for label, content in (("canary", canary_compose), ("production", production_compose)):
    require("POSTGRES_PASSWORD_FILE: /run/secrets/postgres_superuser_password" in content, f"{label} Compose must use POSTGRES_PASSWORD_FILE.")
    require("/run/secrets/postgres_superuser_password:ro" in content, f"{label} Compose must mount the superuser password file read-only.")
    require("resources:" in content and "limits:" in content and "reservations:" in content, f"{label} Compose must set resource limits and reservations.")
require("ensure_encrypted_overlay_network" in manual_deploy, "Manual deploy must validate encrypted database overlay networks.")
require("--opt encrypted" in manual_deploy, "Manual deploy must create database overlay networks with encryption.")
require("postgres_root_password_file" in manual_deploy, "Manual deploy must load the PostgreSQL superuser password from the host file.")
require("preflight-postgres-major.sh" in manual_deploy, "Manual deploy must reject a PostgreSQL data-major mismatch before stack deployment.")
require('docker config inspect "${postgres_tls_cert_config}"' in manual_deploy, "Manual deploy must validate the PostgreSQL TLS certificate config.")
require('docker secret inspect "${postgres_tls_key_secret}"' in manual_deploy, "Manual deploy must validate the PostgreSQL TLS private-key secret.")
require('docker config create --label "content-sha256=${hba_sha256}"' in manual_deploy, "Manual deploy must create a content-labelled Runtrace HBA config.")
require('deployed_hba_sha256' in manual_deploy, "Manual deploy must reject Runtrace HBA content drift.")
require("config/runtrace-pg_hba.conf" in manual_deploy, "Manual deploy must include the Runtrace HBA policy.")
require("-e PGPASSWORD=" not in manual_deploy, "Manual deploy must not expose the PostgreSQL superuser password as a container environment argument.")
require("POSTGRES_PASSWORD_FILE" in normalized_readme, "README must document file-based PostgreSQL bootstrap credentials.")
require("--opt encrypted" in normalized_readme, "README must document encrypted database overlays.")
require("sslmode=verify-full" in normalized_readme, "README must document certificate-verified Runtrace database connections.")
require("docker secret create makepad_postgres_tls_key_v1" in normalized_readme, "README must document private-key secret provisioning.")
require("bash scripts/test-runtrace-tls-policy.sh" in normalized_readme, "README must document the container-level Runtrace TLS policy test.")
require("bash scripts/test-runtrace-backup.sh" in normalized_readme, "README must document the Runtrace backup contract test.")
require(not re.search(r"postgres://(?:keycloak_runtrace_app|runtrace_app):[^\n]*sslmode=disable", readme), "README must not document plaintext-capable Runtrace database URLs.")
for required in (
    "runtrace_backup:",
    "PGSSLMODE: verify-full",
    "PGSSLROOTCERT: /etc/postgresql/ca.crt",
    "PGUSER: makepad_backup",
    "POSTGRES_BACKUP_PASSWORD_FILE: /run/secrets/postgres_backup_password",
    "RUNTRACE_BACKUP_INTERVAL_SECONDS",
    "RUNTRACE_BACKUP_RETENTION_DAYS",
    "runtrace_backup_script",
    "runtrace_backup_loop_script",
    "no-new-privileges:true",
    "cap_drop:",
    "healthcheck:",
):
    require(required in production_compose, f"Production Compose is missing Runtrace backup control: {required}")
for required in (
    "MAKEPAD_POSTGRES_CA_CERT_HOST_PATH=",
    "MAKEPAD_POSTGRES_STORAGEBOX_MOUNT=/mnt/makepad-storagebox",
    "MAKEPAD_POSTGRES_RUNTRACE_BACKUP_PATH=",
    "MAKEPAD_POSTGRES_RUNTRACE_BACKUP_PASSWORD_FILE_HOST_PATH=",
    "MAKEPAD_POSTGRES_RUNTRACE_BACKUP_INTERVAL_SECONDS=21600",
    "MAKEPAD_POSTGRES_RUNTRACE_BACKUP_RETENTION_DAYS=35",
):
    require(required in production_env, f"Production environment is missing Runtrace backup setting: {required}")
for required in (
    "databases='runtrace keycloak_runtrace amiary amiary_canary keycloak_amiary'",
    'PGSSLMODE="${PGSSLMODE:-verify-full}"',
    "pg_restore --list",
    "--role=makepad_backup_reader",
    "sha256sum runtrace.dump keycloak_runtrace.dump amiary.dump amiary_canary.dump keycloak_amiary.dump",
    "last-success.json",
):
    require(required in runtrace_backup, f"Runtrace backup script is missing: {required}")
require("POSTGRES_SUPERUSER_PASSWORD_FILE" not in runtrace_backup, "Backup script must not consume the PostgreSQL superuser credential.")
require("healthcheck" in runtrace_backup_loop and "interval_seconds * 2" in runtrace_backup_loop, "Runtrace backup health check must enforce freshness.")
for required in (
    "replace-nonproduction-restore-targets",
    "--single-transaction",
    "runtrace_state",
    "public.realm",
    "amiary.persons",
    "amiary_security_definer",
    "relforcerowsecurity",
    "AMIARY_RESTORE_SERVICE",
    "AMIARY_CANARY_RESTORE_SERVICE",
    "KEYCLOAK_AMIARY_RESTORE_SERVICE",
    "sha256sum -c",
):
    require(required in runtrace_restore, f"Runtrace restore verifier is missing: {required}")
require("--no-owner" not in runtrace_backup and "--no-acl" not in runtrace_backup, "Backups must preserve ownership and ACL metadata.")
require("--no-owner" not in runtrace_restore and "--no-acl" not in runtrace_restore, "Restore drills must apply preserved ownership and ACL metadata.")
require("run-runtrace-backup.sh" in runtrace_backup_test, "Runtrace backup contract test must execute the real backup script.")
for required in (
    'cp scripts/run-runtrace-backup.sh',
    'cp scripts/run-runtrace-backup-loop.sh',
    "backup_directory_mode",
    "backup_password_mode",
    "postgres_ca_mode",
    "mountpoint --quiet",
    "canonical_storagebox",
):
    require(required in manual_deploy, f"Manual deploy is missing backup preflight control: {required}")
require("same physical data disk is not a disaster-recovery backup" in normalized_readme, "README must require off-host Runtrace backup replication.")
require("DEPLOY_STORAGEBOX_TRANSPORT_ENCRYPTION_CONFIRMED" in manual_deploy, "Production deploy must require encrypted Storage Box transport confirmation.")
require("DEPLOY_STORAGEBOX_AT_REST_ENCRYPTION_CONFIRMED" in manual_deploy, "Production deploy must require Storage Box encryption-at-rest confirmation.")
require("scripts/verify-runtrace-restore.sh" in normalized_readme, "README must document destructive non-production restore verification.")
require("DEPLOY_VIF_DB_NETWORK production environment secret" in manual_deploy, "Manual deploy workflow must require VIF network secret only for production.")
require('if [[ "${deploy_env}" == "production" ]]; then' in manual_deploy, "Manual deploy workflow must gate VIF setup to production.")
require('if [[ "${vif_enabled}" != "1" ]]; then' in manual_deploy, "Manual deploy workflow must skip VIF provisioning outside production.")
require("postgres_ready=0" in manual_deploy, "Manual deploy workflow must track Postgres readiness.")
require("Postgres did not become reachable via makepad-postgres-vif" in manual_deploy, "Manual deploy workflow must fail clearly when VIF readiness times out.")
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
for expected in (
    "keycloak_runtrace_app",
    "keycloak_runtrace",
    "keycloak_runtrace_app_password",
    "pg_advisory_lock",
    "pg_advisory_unlock",
    "CREATE DATABASE keycloak_runtrace OWNER keycloak_runtrace_app",
    "ALTER DATABASE keycloak_runtrace OWNER TO keycloak_runtrace_app",
):
    require(expected in keycloak_runtrace_sql, f"Targeted Runtrace Keycloak bootstrap is missing {expected}.")
require("bootstrap/keycloak-runtrace-app.sql" in readme, "README must document the targeted Runtrace Keycloak bootstrap.")

for expected in ("openpanel_app", "openpanel", "openpanel_app_password"):
    require(expected in openpanel_sql, f"OpenPanel app SQL bootstrap is missing {expected}.")
require("PostgreSQL superuser connection" in openpanel_sql, "OpenPanel app SQL bootstrap must document its superuser connection requirement.")
require("pg_advisory_lock" in openpanel_sql, "OpenPanel app SQL bootstrap must serialize concurrent runs with an advisory lock.")
require("pg_advisory_unlock" in openpanel_sql, "OpenPanel app SQL bootstrap must release its advisory lock after provisioning.")
require("ALTER ROLE openpanel_app LOGIN PASSWORD :'openpanel_app_password'" in openpanel_sql, "OpenPanel app SQL bootstrap must set the role password from a psql variable.")
require("CREATE DATABASE openpanel OWNER openpanel_app" in openpanel_sql, "OpenPanel app SQL bootstrap must create the OpenPanel database.")
require("ALTER DATABASE openpanel OWNER TO openpanel_app" in openpanel_sql, "OpenPanel app SQL bootstrap must repair OpenPanel database ownership drift.")
require("NULLIF(btrim(:'openpanel_app_password'), '')" in openpanel_sql, "OpenPanel app SQL bootstrap must reject empty passwords.")
require("openpanel_app" in normalized_readme, "README must document the OpenPanel app role.")
require("postgres://openpanel_app:<secret>@<db-vm-host>:5432/openpanel?schema=public&sslmode=disable" in readme, "README must document the OpenPanel DB VM host connection URI.")
require("${OPENPANEL_DB_PASSWORD:?" in readme, "README bootstrap command must fail fast for OPENPANEL_DB_PASSWORD.")
PY

bash "${script_dir}/validate-amiary-config.sh"
