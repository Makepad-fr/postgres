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
brio_sql = read_required_text(repo_root / "bootstrap/brio-staging-app.sql", "Brio staging app SQL bootstrap")
keycloak_brio_sql = read_required_text(repo_root / "bootstrap/keycloak-brio-staging.sql", "targeted Brio Keycloak SQL bootstrap")
readme = read_required_text(repo_root / "README.md", "README")
base_compose = read_required_text(repo_root / "compose.yml", "base Compose file")
host_compose = read_required_text(repo_root / "compose.host.yml", "host Compose file")
runtrace_hba = read_required_text(repo_root / "config/runtrace-pg_hba.conf", "Runtrace HBA policy")
runtrace_backup = read_required_text(repo_root / "scripts/run-runtrace-backup.sh", "Runtrace backup script")
runtrace_backup_loop = read_required_text(repo_root / "scripts/run-runtrace-backup-loop.sh", "Runtrace backup loop")
runtrace_restore = read_required_text(repo_root / "scripts/verify-runtrace-restore.sh", "Runtrace restore verifier")
runtrace_backup_test = read_required_text(repo_root / "scripts/test-runtrace-backup.sh", "Runtrace backup contract test")
brio_backup_path = repo_root / "scripts/run-brio-encrypted-backup.sh"
brio_backup_loop_path = repo_root / "scripts/run-brio-encrypted-backup-loop.sh"
brio_restore_path = repo_root / "scripts/verify-brio-encrypted-restore.sh"
brio_backup_test_path = repo_root / "scripts/test-brio-encrypted-backup.sh"
brio_restore_test_path = repo_root / "scripts/test-brio-encrypted-restore.sh"
brio_backup = read_required_text(brio_backup_path, "Brio encrypted backup script")
brio_backup_loop = read_required_text(brio_backup_loop_path, "Brio encrypted backup loop")
brio_restore = read_required_text(brio_restore_path, "Brio encrypted restore verifier")
brio_backup_test = read_required_text(brio_backup_test_path, "Brio encrypted backup contract test")
brio_restore_test = read_required_text(brio_restore_test_path, "Brio encrypted restore contract test")
canary_compose = read_required_text(repo_root / "envs/canary/compose.yml", "canary Compose override")
production_compose = read_required_text(repo_root / "envs/production/compose.yml", "production Compose override")
canary_env = read_required_text(repo_root / "envs/canary/.env.db", "canary database environment")
production_env = read_required_text(repo_root / "envs/production/.env.db", "production database environment")
manual_deploy_workflow = read_required_text(repo_root / ".github/workflows/manual-deploy.yml", "manual deploy workflow")
remote_deploy_path = repo_root / "scripts/deploy-postgres-stack.sh"
remote_deploy = read_required_text(remote_deploy_path, "remote deploy script")
manual_deploy = manual_deploy_workflow + "\n" + remote_deploy
ci_workflow = read_required_text(repo_root / ".github/workflows/ci.yml", "CI workflow")
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
require(remote_deploy_path.stat().st_mode & 0o111, "Remote deploy script must be executable.")
for required in (
    'cp scripts/deploy-postgres-stack.sh "${bundle_root}/scripts/deploy-postgres-stack.sh"',
    'scp "${scp_opts[@]}" "${bundle_root}/scripts/deploy-postgres-stack.sh"',
    'printf -v remote_script_q %q "${REMOTE_DIR}/scripts/deploy-postgres-stack.sh"',
):
    require(required in manual_deploy_workflow, f"Manual deploy workflow must bundle and invoke the remote deploy script: {required}")
require("<<'EOF'" not in manual_deploy_workflow, "Manual deploy workflow must not embed the oversized remote deployment heredoc.")
require("DEPLOY_BRIO_STAGING_DB_NETWORK must be makepad_brio_staging_db" in manual_deploy, "Manual deploy must reject a non-canonical Brio database network secret.")
require("Brio deployment bundle must use makepad_brio_staging_db" in manual_deploy, "Remote deploy must revalidate the canonical Brio database network.")
require("postgres:16-alpine@sha256:" in base_compose, "Base Compose must pin PostgreSQL to an immutable digest.")
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
hba_records = [
    tuple(line.split())
    for line in runtrace_hba.splitlines()
    if line.strip() and not line.lstrip().startswith("#")
]
fresko_betacrew_records = [
    record
    for record in hba_records
    if len(record) >= 2 and record[1] in {"fresko_production", "betacrew", "keycloak_betacrew"}
]
require(
    fresko_betacrew_records
    == [
        ("hostnossl", "fresko_production", "all", "all", "reject"),
        ("hostssl", "fresko_production", "fresko_runtime", "10.80.0.1/32", "scram-sha-256"),
        ("hostssl", "fresko_production", "fresko_schema_owner", "10.80.0.1/32", "scram-sha-256"),
        ("hostssl", "fresko_production", "fresko_importer", "10.80.0.1/32", "scram-sha-256"),
        ("hostssl", "fresko_production", "all", "all", "reject"),
        ("hostnossl", "betacrew", "all", "all", "reject"),
        ("hostnossl", "keycloak_betacrew", "all", "all", "reject"),
        ("hostssl", "betacrew", "betacrew_app", "10.80.0.1/32", "scram-sha-256"),
        ("hostssl", "keycloak_betacrew", "keycloak_betacrew_app", "88.99.209.165/32", "scram-sha-256"),
        ("hostssl", "betacrew", "postgres", "127.0.0.1/32", "scram-sha-256"),
        ("hostssl", "keycloak_betacrew", "postgres", "127.0.0.1/32", "scram-sha-256"),
        ("hostssl", "betacrew", "all", "all", "reject"),
        ("hostssl", "keycloak_betacrew", "all", "all", "reject"),
    ],
    "HBA must preserve the exact live Fresko and BetaCrew TLS, source, role, and rejection policy.",
)
for required in (
    "`fresko_production`",
    "`betacrew`",
    "`keycloak_betacrew`",
    "`10.80.0.1/32`",
    "`88.99.209.165/32`",
    "`127.0.0.1/32`",
):
    require(required in readme, f"README must document the preserved Fresko/BetaCrew HBA policy: {required}")
shared_fallback = ("host", "all", "all", "all", "scram-sha-256")
require(shared_fallback in hba_records, "HBA must retain the shared SCRAM fallback.")
require(
    max(hba_records.index(record) for record in fresko_betacrew_records) < hba_records.index(shared_fallback),
    "Every Fresko and BetaCrew restriction must precede the shared HBA fallback.",
)
for database, roles in (
    ("brio_staging", ("brio_staging_app", "brio_staging_backup")),
    ("keycloak_brio_staging", ("keycloak_brio_staging_app", "keycloak_brio_staging_backup")),
):
    require(re.search(rf"^hostnossl\s+{database}\s+all\s+all\s+reject$", runtrace_hba, re.MULTILINE), f"HBA must reject plaintext access to {database}.")
    for role in roles:
        require(re.search(rf"^hostssl\s+{database}\s+{role}\s+all\s+scram-sha-256$", runtrace_hba, re.MULTILINE), f"HBA must allow TLS access to {database} for {role}.")
        require(re.search(rf"^host\s+all\s+{role}\s+all\s+reject$", runtrace_hba, re.MULTILINE), f"HBA must reject {role} from every non-target database.")
require("makepad-postgres-brio-staging" in canary_compose, "Canary Compose must expose Brio's certificate-matching database alias.")
require("MAKEPAD_POSTGRES_BRIO_STAGING_DB_NETWORK" in canary_compose, "Canary Compose must attach Brio's isolated database network.")
require("ensure_internal_encrypted_overlay_network" in manual_deploy, "Manual deploy must validate Brio's internal encrypted database network.")
for content, role, database in (
    (brio_sql, "brio_staging_app", "brio_staging"),
    (keycloak_brio_sql, "keycloak_brio_staging_app", "keycloak_brio_staging"),
):
    require("NOBYPASSRLS" in content, f"{role} bootstrap must strip elevated role capabilities.")
    require(f"REVOKE ALL ON DATABASE {database} FROM PUBLIC" in content, f"{database} must revoke default public database access.")

for content, app_role, backup_role, database, password_variable in (
    (brio_sql, "brio_staging_app", "brio_staging_backup", "brio_staging", "brio_staging_backup_password"),
    (keycloak_brio_sql, "keycloak_brio_staging_app", "keycloak_brio_staging_backup", "keycloak_brio_staging", "keycloak_brio_staging_backup_password"),
):
    for required in (
        f"CREATE ROLE {backup_role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION",
        f"ALTER ROLE {backup_role} LOGIN PASSWORD :'{password_variable}'",
        f"ALTER ROLE {backup_role} NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2",
        f"GRANT CONNECT ON DATABASE {database} TO {backup_role}",
        f"ALTER ROLE {backup_role} IN DATABASE {database} SET default_transaction_read_only TO on",
        f"GRANT USAGE ON SCHEMA public TO {backup_role}",
        f"GRANT SELECT ON ALL TABLES IN SCHEMA public TO {backup_role}",
        f"GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO {backup_role}",
        f"ALTER DEFAULT PRIVILEGES FOR ROLE {app_role} IN SCHEMA public GRANT SELECT ON TABLES TO {backup_role}",
        f"ALTER DEFAULT PRIVILEGES FOR ROLE {app_role} IN SCHEMA public GRANT SELECT ON SEQUENCES TO {backup_role}",
    ):
        require(required in content, f"{database} backup bootstrap is missing: {required}")
    require(f"NULLIF(btrim(:'{password_variable}'), '')" in content, f"{database} backup bootstrap must reject empty passwords.")
    require("inet_client_addr() IS NULL" in content, f"{database} bootstrap must allow a local Unix-domain socket.")
    require("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()" in content, f"{database} bootstrap must reject remote plaintext administrator sessions.")
    require(r"\quit 1" not in content and "SELECT 1 / 0;" in content, f"{database} bootstrap failure branches must terminate psql with a non-zero status.")
for label, content in (("canary", canary_env), ("production", production_env)):
    require("POSTGRES_PASSWORD=" not in content, f"{label} database environment must not contain POSTGRES_PASSWORD.")
    require("POSTGRES_IMAGE=postgres:16-alpine@sha256:" in content, f"{label} database environment must pin POSTGRES_IMAGE.")
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
    "MAKEPAD_POSTGRES_RUNTRACE_BACKUP_PATH=",
    "MAKEPAD_POSTGRES_RUNTRACE_BACKUP_PASSWORD_FILE_HOST_PATH=",
    "MAKEPAD_POSTGRES_RUNTRACE_BACKUP_INTERVAL_SECONDS=21600",
    "MAKEPAD_POSTGRES_RUNTRACE_BACKUP_RETENTION_DAYS=35",
):
    require(required in production_env, f"Production environment is missing Runtrace backup setting: {required}")
for required in (
    "for database in runtrace keycloak_runtrace",
    'PGSSLMODE="${PGSSLMODE:-verify-full}"',
    "pg_restore --list",
    "sha256sum runtrace.dump keycloak_runtrace.dump",
    "last-success.json",
):
    require(required in runtrace_backup, f"Runtrace backup script is missing: {required}")
require("healthcheck" in runtrace_backup_loop and "interval_seconds * 2" in runtrace_backup_loop, "Runtrace backup health check must enforce freshness.")
for required in (
    "replace-nonproduction-restore-targets",
    "--single-transaction",
    "runtrace_state",
    "public.realm",
    "sha256sum --check",
):
    require(required in runtrace_restore, f"Runtrace restore verifier is missing: {required}")
require("run-runtrace-backup.sh" in runtrace_backup_test, "Runtrace backup contract test must execute the real backup script.")
for required in (
    'cp scripts/run-runtrace-backup.sh',
    'cp scripts/run-runtrace-backup-loop.sh',
    "backup_directory_mode",
    "backup_password_mode",
    "postgres_ca_mode",
):
    require(required in manual_deploy, f"Manual deploy is missing backup preflight control: {required}")
require("same physical data disk is not a disaster-recovery backup" in normalized_readme, "README must require off-host Runtrace backup replication.")
require("scripts/verify-runtrace-restore.sh" in normalized_readme, "README must document destructive non-production restore verification.")
require("DEPLOY_VIF_DB_NETWORK production environment secret" in manual_deploy, "Manual deploy workflow must require VIF network secret only for production.")
require('if [[ "${deploy_env}" == "production" ]]; then' in manual_deploy, "Manual deploy workflow must gate VIF setup to production.")
require('if [[ "${vif_enabled}" != "1" ]]; then' in manual_deploy, "Manual deploy workflow must skip VIF provisioning outside production.")
require("postgres_ready=0" in manual_deploy, "Manual deploy workflow must track Postgres readiness.")
require("wait_for_service_convergence" in manual_deploy, "Manual deploy must wait for exact-image Swarm task convergence.")
require("docker service ps --no-trunc --filter desired-state=running" in manual_deploy, "Manual deploy must inspect running task images rather than stale replica counts.")
require('wait_for_service_convergence "${stack_name}_postgres" "${postgres_image}"' in manual_deploy, "Manual deploy must converge PostgreSQL before probing it.")
require('wait_for_service_convergence "${stack_name}_brio_staging_backup" "${brio_backup_image}"' in manual_deploy, "Canary deploy must converge the Brio application backup task.")
require('wait_for_service_convergence "${stack_name}_keycloak_brio_staging_backup" "${brio_backup_image}"' in manual_deploy, "Production deploy must converge the Brio identity backup task.")
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

for expected in (
    "brio_staging_app",
    "brio_staging",
    "brio_staging_app_password",
    "pg_advisory_lock",
    "pg_advisory_unlock",
    "CREATE DATABASE brio_staging OWNER brio_staging_app",
    "ALTER DATABASE brio_staging OWNER TO brio_staging_app",
):
    require(expected in brio_sql, f"Brio staging bootstrap is missing {expected}.")
require("PostgreSQL superuser connection" in brio_sql, "Brio staging bootstrap must document its superuser requirement.")
require("NULLIF(btrim(:'brio_staging_app_password'), '')" in brio_sql, "Brio staging bootstrap must reject empty passwords.")
require("NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION" in brio_sql, "Brio staging role must be least privilege.")
require("brio_staging_app" in normalized_readme, "README must document the Brio staging app role.")
require("keycloak_brio_staging_app" in normalized_readme, "README must document the Brio staging Keycloak role.")
require("${BRIO_STAGING_DB_PASSWORD:?" in readme, "README must fail fast for BRIO_STAGING_DB_PASSWORD.")
require("${KEYCLOAK_BRIO_STAGING_DB_PASSWORD:?" in readme, "README must fail fast for KEYCLOAK_BRIO_STAGING_DB_PASSWORD.")
require("${BRIO_STAGING_BACKUP_DB_PASSWORD:?" in readme, "README must fail fast for BRIO_STAGING_BACKUP_DB_PASSWORD.")
require("${KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD:?" in readme, "README must fail fast for KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD.")
require("refuse a remote plaintext administrator session" in normalized_readme, "README must document the Brio bootstrap transport guard.")
require("bootstrap/keycloak-brio-staging.sql" in readme, "README must document the targeted Brio Keycloak bootstrap.")
require("keycloak_brio_staging_app_password" not in sql, "The shared Keycloak bootstrap must not rotate the Brio staging credential.")
require("MAKEPAD_POSTGRES_BRIO_STAGING_DB_NETWORK" in canary_compose, "Canary Compose must attach the isolated Brio staging DB network.")
require("makepad-postgres-brio-staging" in canary_compose, "Canary Compose must expose the certificate-matching Brio DB alias.")
backup_image = "postgres:16-bookworm@sha256:bb3e1a57e5407e0a5280b4211980a5e537f4abd234a87014ac979849a78dd825"
require(f"BRIO_BACKUP_IMAGE={backup_image}" in canary_env, "Canary must pin the exact Brio backup image.")
require(f"BRIO_BACKUP_IMAGE={backup_image}" in production_env, "Production must pin the exact Brio backup image.")
for config_name in ("brio_encrypted_backup_script", "brio_encrypted_backup_loop_script"):
    require(config_name in base_compose, f"Base Compose is missing Brio backup config {config_name}.")

require("  brio_staging_backup:" in canary_compose, "Canary Compose must run the Brio application backup service.")
canary_backup_service = canary_compose.split("  brio_staging_backup:", 1)[1].split("\nnetworks:", 1)[0]
for required in (
    "BRIO_BACKUP_DATABASE: brio_staging",
    "PGHOST: makepad-postgres-brio-staging",
    "PGUSER: brio_staging_backup",
    "PGSSLMODE: verify-full",
    "BRIO_BACKUP_RETENTION_DAYS",
    "BRIO_BACKUP_RECIPIENT_CERT",
    "user: \"999:999\"",
    "read_only: true",
    "no-new-privileges:true",
    "- brio_staging",
):
    require(required in canary_backup_service, f"Canary Brio backup service is missing: {required}")
require("- db" not in canary_backup_service, "Canary Brio backup must attach only to Brio's isolated database network.")

require("  keycloak_brio_staging_backup:" in production_compose, "Production Compose must run the Brio identity backup service.")
production_backup_service = production_compose.split("  keycloak_brio_staging_backup:", 1)[1].split("\nnetworks:", 1)[0]
for required in (
    "BRIO_BACKUP_DATABASE: keycloak_brio_staging",
    "PGHOST: makepad-postgres",
    "PGUSER: keycloak_brio_staging_backup",
    "PGSSLMODE: verify-full",
    "BRIO_BACKUP_RETENTION_DAYS",
    "BRIO_BACKUP_RECIPIENT_CERT",
    "user: \"999:999\"",
    "read_only: true",
    "no-new-privileges:true",
    "- db",
):
    require(required in production_backup_service, f"Production Brio identity backup service is missing: {required}")
require("BRIO_RESTORE_RECIPIENT_KEY" not in canary_compose + production_compose + host_compose, "Backup services must never mount the Brio recovery private key.")
for required in (
    "keycloak_brio_staging_backup:",
    "BRIO_BACKUP_DATABASE: keycloak_brio_staging",
    "MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_DB_HOST",
    "PGUSER: keycloak_brio_staging_backup",
    "PGSSLMODE: verify-full",
):
    require(required in host_compose, f"Standalone DB-VM Compose is missing Brio identity backup control: {required}")

for path in (brio_backup_path, brio_backup_loop_path, brio_restore_path, brio_backup_test_path, brio_restore_test_path):
    require(os.access(path, os.X_OK), f"Brio backup/restore script must be executable: {path}")
for required in (
    "brio_staging) expected_pg_user=brio_staging_backup",
    "keycloak_brio_staging) expected_pg_user=keycloak_brio_staging_backup",
    "BRIO_BACKUP_RETENTION_DAYS:-35",
    "Brio backup retention must remain exactly 35 days",
    "retention_find_days=$((retention_days - 1))",
    "mkfifo",
    "pg_dump",
    "openssl cms",
    "-aes-256-gcm",
    ".dump.cms",
    "PGSSLMODE=verify-full",
    "PGUSER must identify the database-specific Brio backup role",
    "mv \"${partial_dir}\" \"${final_dir}\"",
    "sha256sum \"${encrypted_name}\" metadata.json",
):
    require(required in brio_backup, f"Brio encrypted backup script is missing: {required}")
require("--file=" not in brio_backup, "Brio backup must stream pg_dump instead of writing a plaintext dump file.")
require("BRIO_RESTORE_RECIPIENT_KEY" not in brio_backup, "Brio backup service must not receive the recovery private key.")
require("PGUSER=postgres" not in canary_backup_service + production_backup_service, "Brio backup services must never run as the PostgreSQL superuser.")
require("healthcheck" in brio_backup_loop and "interval_seconds * 2" in brio_backup_loop, "Brio backup health check must enforce freshness.")
for required in (
    "replace-nonproduction-brio-restore-targets",
    "BRIO_APP_RESTORE_SERVICE",
    "BRIO_KEYCLOAK_RESTORE_SERVICE",
    "BRIO_RESTORE_RECIPIENT_CERT",
    "BRIO_RESTORE_RECIPIENT_KEY",
    "BRIO_RESTORE_TEMP_ROOT",
    "*_restore_test",
    "SELECT current_database();",
    "openssl cms",
    "-decrypt",
    "--single-transaction",
    "--exit-on-error",
    "public.schema_migrations",
    "public.communities",
    "public.realm",
):
    require(required in brio_restore, f"Brio encrypted restore verifier is missing: {required}")
require("run-brio-encrypted-backup.sh" in brio_backup_test, "Brio backup contract test must execute the real backup script.")
require("verify-brio-encrypted-restore.sh" in brio_restore_test, "Brio restore contract test must execute the real restore verifier.")
for required in ("test-brio-bootstrap.sh", "test-brio-encrypted-backup.sh", "test-brio-encrypted-restore.sh"):
    require(required in ci_workflow, f"CI must run the Brio PostgreSQL contract: {required}")
for required in (
    "independently administered off-host storage",
    "successful recorded restore of both databases remain external release gates",
    "private key must never be copied to a database host",
    "scripts/test-brio-encrypted-backup.sh",
    "scripts/test-brio-encrypted-restore.sh",
):
    require(required in normalized_readme, f"README is missing Brio backup/restore guidance: {required}")

for required in (
    "-checkhost makepad-postgres-brio-staging",
    "-checkend 604800",
    "openssl verify -purpose sslserver",
    "PGSSLMODE=verify-full",
    "-h makepad-postgres-brio-staging",
    "cp scripts/run-brio-encrypted-backup.sh",
    "cp scripts/run-brio-encrypted-backup-loop.sh",
    "brio_backup_directory_mode",
    "brio_backup_password_mode",
    "brio_backup_recipient_mode",
    "uid 999 with mode 0700",
    "uid 999 with mode 0400",
    "openssl cms -encrypt",
):
    require(required in manual_deploy, f"Manual deploy is missing Brio certificate/connection preflight marker: {required}")
for required in (
    "postgres-deploy-ssh-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}",
    "postgres-deploy-bundle-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}",
    'UserKnownHostsFile=${known_hosts_file}',
    "-F /dev/null",
    "GlobalKnownHostsFile=/dev/null",
    "IdentitiesOnly=yes",
    "Remove job-scoped deployment material",
    "if: always()",
):
    require(required in manual_deploy_workflow, f"Self-hosted deploy workflow is missing job-scoped cleanup control: {required}")
for forbidden in ('${HOME}/.ssh', "$HOME/.ssh", "~/.ssh", "add-ssh-host-key-action"):
    require(forbidden not in manual_deploy_workflow, f"Self-hosted deploy workflow must not persist SSH state via {forbidden}.")
for workflow_name, workflow_text in (
    ("CI", ci_workflow),
    ("manual deploy", manual_deploy_workflow),
):
    checkout_count = workflow_text.count("uses: actions/checkout@v5")
    require(checkout_count > 0, f"{workflow_name} workflow must check out the repository.")
    require(
        workflow_text.count("persist-credentials: false") == checkout_count,
        f"Every self-hosted checkout in the {workflow_name} workflow must disable persisted Git credentials.",
    )
for policy in (
    "hostnossl brio_staging",
    "hostnossl keycloak_brio_staging",
    "hostssl brio_staging",
    "hostssl keycloak_brio_staging",
):
    require(policy in runtrace_hba, f"PostgreSQL HBA policy is missing {policy}.")
PY
