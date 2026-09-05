#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "Missing required binary for postgres validation: python3" >&2
  exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)

REPO_ROOT="${repo_root}" python3 - <<'PY'
import json
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
vif_sql = read_required_text(repo_root / "bootstrap/vif-app.sql", "VIF application SQL bootstrap")
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
canary_deploy_path = repo_root / "scripts/deploy-brio-canary-postgres.sh"
canary_deploy = read_required_text(canary_deploy_path, "Brio canary deploy script")
identity_deploy_path = repo_root / "scripts/deploy-brio-identity-db-host.sh"
identity_deploy = read_required_text(identity_deploy_path, "Brio identity DB-VM deploy script")
identity_workflow = read_required_text(repo_root / ".github/workflows/deploy-brio-identity-db.yml", "Brio identity DB-VM workflow")
release_workflow = read_required_text(repo_root / ".github/workflows/release-brio-identity-db.yml", "Brio identity database release orchestrator")
cohort_workflow = read_required_text(repo_root / ".github/workflows/verify-keycloak-cohort-restores.yml", "Keycloak cohort restore workflow")
pr_finalizer_workflow = read_required_text(repo_root / ".github/workflows/pr-ci-result.yml", "PR CI finalizer")
pr_check_publisher = read_required_text(repo_root / "scripts/publish-pr-ci-check.mjs", "PR CI check publisher")
pr_queue_controller = read_required_text(repo_root / "scripts/postgres-ci-queue-controller.mjs", "PR JIT queue controller")
pr_jit_launcher = read_required_text(repo_root / "scripts/run-postgres-ci-jit-vm.sh", "PR JIT VM launcher")
pr_jit_result_validator_path = repo_root / "scripts/verify-postgres-ci-jit-result.py"
pr_jit_result_validator = read_required_text(pr_jit_result_validator_path, "PR JIT authoritative-result validator")
pr_runner_policy = read_required_text(repo_root / "scripts/configure-postgres-ci-runner-group.sh", "runner-group policy reconciler")
environment_policy_reconciler = read_required_text(repo_root / "scripts/reconcile-github-environment-main-policy.py", "GitHub environment policy reconciler")
environment_policy_test = read_required_text(repo_root / "scripts/test-github-environment-main-policy.py", "GitHub environment policy test")
credential_sync = read_required_text(repo_root / "scripts/sync-github-environments.sh", "credential sync helper")
credential_sync_test = read_required_text(repo_root / "scripts/test-sync-github-environments.sh", "credential sync behavioral test")
repository_anchor_validator = read_required_text(repo_root / "scripts/validate-repository-trust-anchor.py", "repository trust-anchor validator")
release_evidence_validator = read_required_text(repo_root / "scripts/verify-brio-release-evidence.py", "Brio release evidence validator")
cohort_evidence_validator = read_required_text(repo_root / "scripts/verify-keycloak-cohort-evidence.py", "Keycloak cohort evidence validator")
cohort_capture = read_required_text(repo_root / "scripts/capture-keycloak-cohort-backups.sh", "Keycloak cohort backup capture")
cohort_restore = read_required_text(repo_root / "scripts/restore-keycloak-cohort-backups.sh", "Keycloak cohort restore verifier")
cohort_dispatch_path = repo_root / "scripts/keycloak-cohort-capture-dispatch.sh"
cohort_dispatch = read_required_text(cohort_dispatch_path, "Keycloak cohort forced-command dispatcher")
cohort_host_installer_path = repo_root / "scripts/install-keycloak-cohort-capture-host.sh"
cohort_host_installer = read_required_text(cohort_host_installer_path, "Keycloak cohort capture-host installer")
cohort_cleaner_path = repo_root / "scripts/clean-keycloak-cohort-resources.sh"
cohort_cleaner = read_required_text(cohort_cleaner_path, "Keycloak cohort Docker-resource cleaner")
cohort_cleaner_installer_path = repo_root / "scripts/install-keycloak-cohort-cleaner.sh"
cohort_cleaner_installer = read_required_text(cohort_cleaner_installer_path, "Keycloak cohort cleaner installer")
tmp_cleaner_path = repo_root / "scripts/ensure-brio-tmp-cleaner.sh"
tmp_cleaner = read_required_text(tmp_cleaner_path, "Brio abandoned-material cleaner")
deploy_guard_test = read_required_text(repo_root / "scripts/test-brio-deploy-guards.sh", "Brio deployment guard test")
deployment_failure_test_path = repo_root / "scripts/test-brio-deployment-failures.sh"
deployment_failure_fixture_path = repo_root / "scripts/fixtures/brio-deployment-failure-fixture.sh"
deployment_failure_test = read_required_text(deployment_failure_test_path, "Brio deployment failure-injection test")
deployment_failure_fixture = read_required_text(deployment_failure_fixture_path, "Brio deployment failure-injection fixture")
manual_deploy = manual_deploy_workflow + "\n" + remote_deploy + "\n" + canary_deploy
ci_workflow = read_required_text(repo_root / ".github/workflows/ci.yml", "CI workflow")
ci_runner = read_required_text(repo_root / "scripts/run-ci.sh", "CI suite runner")
normalized_readme = re.sub(r"\s+", " ", readme)

for environment in (
    "canary",
    "production",
    "staging-brio-identity-db",
    "release-brio-identity-db",
    "keycloak-cohort-restore",
    "postgres-ci-attestation",
):
    require(f'"{environment}"' in environment_policy_reconciler, f"Environment policy reconciler must include {environment}.")
for required in (
    '"protected_branches": False',
    '"custom_branch_policies": True',
    '{"name": "main", "type": "branch"}',
    "MAX_POLICY_PAGES = 1000",
    'REVIEWER_LOGIN = "idilsaglam"',
    "REVIEWER_ID = 39597780",
    "HUMAN_REVIEW_ENVIRONMENTS",
    "WAIT_TIMERS",
    "ATTESTATION_EXCEPTION",
    "reviewer_snapshot",
    "protection_snapshot",
    "build_expected_update",
    "audit_protection",
    "audit_environment(client, environment)",
    "protected-policy-v1",
):
    require(required in environment_policy_reconciler, f"Environment policy reconciler is missing: {required}")
require('assert "production" in REQUIRED_ENVIRONMENTS' in environment_policy_test, "Environment policy test must cover production explicitly.")
for required in (
    "HUMAN_REVIEW_ENVIRONMENTS == set(REQUIRED_ENVIRONMENTS)",
    "expected_attestation_update",
    "enabled self review",
    "unexpected wait timer",
    "stale reviewer snapshot",
    "failed policy read-back",
):
    require(required in environment_policy_test, f"Environment policy test is missing adversarial coverage: {required}")
require("python3 scripts/test-github-environment-main-policy.py" in ci_runner, "CI must run the environment policy behavioral test.")
require(
    "exactly one custom branch deployment policy whose type is `branch` and whose name is exactly `main`" in normalized_readme,
    "README must require exact-main custom deployment policies.",
)

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
    'remote_bundle="${REMOTE_DIR}/.deploy/postgres-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"',
    'remote_script="${remote_bundle}/scripts/deploy-postgres-stack.sh"',
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
        address = "127.0.0.1/32" if role == "keycloak_brio_staging_backup" else "all"
        require(re.search(rf"^hostssl\s+{database}\s+{role}\s+{re.escape(address)}\s+scram-sha-256$", runtrace_hba, re.MULTILINE), f"HBA must allow TLS access to {database} for {role} from {address}.")
        require(re.search(rf"^host\s+all\s+{role}\s+all\s+reject$", runtrace_hba, re.MULTILINE), f"HBA must reject {role} from every non-target database.")
for allow_record, reject_record in (
    (("hostssl", "keycloak_brio_staging", "keycloak_brio_staging_app", "all", "scram-sha-256"), ("host", "all", "keycloak_brio_staging_app", "all", "reject")),
    (("hostssl", "keycloak_brio_staging", "keycloak_brio_staging_backup", "127.0.0.1/32", "scram-sha-256"), ("host", "all", "keycloak_brio_staging_backup", "all", "reject")),
):
    require(hba_records.index(allow_record) < hba_records.index(reject_record), "Brio identity HBA allows must precede their target-wide role rejection.")
require("MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG=makepad_postgres_canary_runtrace_hba_v3" in canary_env, "Canary must use the fresh immutable Brio HBA v3 object.")
require("MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG=makepad_postgres_runtrace_hba_v3" in production_env, "Production must use the fresh immutable Brio HBA v3 object.")
require("runtrace_hba_v2" not in canary_env + production_env, "Active environments must never drift an already deployed HBA v2 object.")
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
require(len(re.findall(r"docker network create[^\n]+--opt encrypted=true", manual_deploy)) == 2, "Manual deploy must explicitly create both database overlay network variants with encrypted=true.")
require(re.search(r"--opt\s+encrypted(?:\s|$)", manual_deploy) is None, "Manual deploy must not use Docker's valueless encrypted option.")
require("postgres_root_password_file" in manual_deploy, "Manual deploy must load the PostgreSQL superuser password from the host file.")
require('docker config inspect "${postgres_tls_cert_config}"' in manual_deploy, "Manual deploy must validate the PostgreSQL TLS certificate config.")
require('docker secret inspect "${postgres_tls_key_secret}"' in manual_deploy, "Manual deploy must validate the PostgreSQL TLS private-key secret.")
require('docker config create --label "content-sha256=${hba_sha256}"' in manual_deploy, "Manual deploy must create a content-labelled Runtrace HBA config.")
require('deployed_hba_sha256' in manual_deploy, "Manual deploy must reject Runtrace HBA content drift.")
require("config/runtrace-pg_hba.conf" in manual_deploy, "Manual deploy must include the Runtrace HBA policy.")
require("-e PGPASSWORD=" not in manual_deploy, "Manual deploy must not expose the PostgreSQL superuser password as a container environment argument.")
require("POSTGRES_PASSWORD_FILE" in normalized_readme, "README must document file-based PostgreSQL bootstrap credentials.")
require("--opt encrypted=true" in normalized_readme, "README must document the explicit encrypted=true database overlay option.")
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
require("keycloak_brio_staging_backup" not in production_compose, "The Brio identity backup must never be routed through the production Swarm override.")
require("Postgres did not become reachable via makepad-postgres-vif" in manual_deploy, "Manual deploy workflow must fail clearly when VIF readiness times out.")
require(
    not re.search(r"\S\\gexec", vif_sql),
    "VIF bootstrap must separate every \\gexec command from SQL text by whitespace.",
)
require("ALTER ROLE %I LOGIN PASSWORD %L" in vif_sql, "VIF bootstrap must always refresh the VIF role password.")
require("ALTER DATABASE %I OWNER TO %I" in vif_sql, "VIF bootstrap must repair VIF database ownership drift.")
require("\\getenv vif_password VIF_PASSWORD" in vif_sql, "VIF bootstrap must read its password from the mounted-file environment only.")
require("MAKEPAD_POSTGRES_VIF_DB_PASSWORD" not in manual_deploy_workflow + remote_deploy, "VIF password must never be persisted in the deployment environment file.")
require('-v vif_password=' not in remote_deploy, "VIF password must never be placed in psql command arguments.")
for required in ("postgres-brio-vif-runtime-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}", "vif-db-password", "bootstrap/vif-app.sql"):
    require(required in manual_deploy, f"VIF deployment is missing file-only credential control: {required}")
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
require("PGUSER=postgres" not in canary_backup_service + host_compose, "Brio backup services must never run as the PostgreSQL superuser.")
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
    require(required in ci_runner, f"CI must run the Brio PostgreSQL contract: {required}")
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
    ("identity DB-VM deploy", identity_workflow),
    ("identity database release", release_workflow),
    ("Keycloak cohort restore", cohort_workflow),
    ("PR CI finalizer", pr_finalizer_workflow),
):
    checkout_ref = "uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5"
    checkout_count = workflow_text.count(checkout_ref)
    require(checkout_count > 0, f"{workflow_name} workflow must check out the repository.")
    require(
        workflow_text.count("persist-credentials: false") == checkout_count,
        f"Every self-hosted checkout in the {workflow_name} workflow must disable persisted Git credentials.",
    )

# The repository is public. Every Actions job must therefore use one of the
# explicitly selected self-hosted runner groups; adding a hosted runner (or a
# string-form, ungrouped self-hosted label) is a release-policy violation.
workflow_paths = sorted((repo_root / ".github/workflows").glob("*.yml")) + sorted(
    (repo_root / ".github/workflows").glob("*.yaml")
)
require(workflow_paths, "At least one GitHub Actions workflow must exist.")
for workflow_path in workflow_paths:
    workflow_text = read_required_text(workflow_path, f"workflow {workflow_path.name}")
    runs_on_count = len(re.findall(r"(?m)^    runs-on:\s*$", workflow_text))
    grouped_count = len(re.findall(r"(?m)^    runs-on:\s*\n      group: [^\n]+\n      labels: \[[^\n]*self-hosted[^\n]*\]$", workflow_text))
    require(runs_on_count > 0, f"Workflow {workflow_path.name} must define at least one job runner.")
    require(
        runs_on_count == grouped_count,
        f"Every job in {workflow_path.name} must use a selected group and explicit self-hosted labels.",
    )
    require(
        not re.search(r"(?i)(ubuntu|windows|macos)-(latest|[0-9]+)", workflow_text),
        f"Workflow {workflow_path.name} must not use a GitHub-hosted runner image.",
    )

# Credential material is canonical in Proton Pass and may be mirrored only to
# its reviewed consumer. The machine-readable inventory, rather than a prose
# table substring, is the exact contract checked against every workflow.
credential_inventory_path = repo_root / "deploy/credential-inventory.json"
credential_inventory = json.loads(read_required_text(credential_inventory_path, "credential inventory"))
require(
    set(credential_inventory) == {
        "schemaVersion", "repository", "vault", "githubEntries",
        "repositoryVariables", "nonGitHubEntries",
    },
    "Credential inventory has unexpected top-level keys.",
)
require(credential_inventory["schemaVersion"] == 1, "Credential inventory schema must be version 1.")
require(credential_inventory["repository"] == "Makepad-fr/postgres", "Credential inventory targets the wrong repository.")
require(credential_inventory["vault"] == "Makepad", "Credential inventory targets the wrong Proton vault.")

github_entries = credential_inventory["githubEntries"]
repository_variables = credential_inventory["repositoryVariables"]
non_github_entries = credential_inventory["nonGitHubEntries"]
require(all(isinstance(entries, list) and entries for entries in (github_entries, repository_variables, non_github_entries)), "Every credential inventory section must be non-empty.")
required_environments = {
    "canary", "production", "staging-brio-identity-db",
    "release-brio-identity-db", "keycloak-cohort-restore",
    "postgres-ci-attestation",
}
require({entry.get("environment") for entry in github_entries} == required_environments, "Credential inventory environment set drifted.")
github_destinations = {
    (entry.get("environment"), entry.get("kind"), entry.get("destination"))
    for entry in github_entries
}
require(len(github_destinations) == len(github_entries), "Credential inventory has duplicate environment destinations.")
repository_destinations = {entry.get("destination") for entry in repository_variables}
require(len(repository_destinations) == len(repository_variables), "Credential inventory has duplicate repository variables.")
require(
    repository_destinations == {
        "POSTGRES_CI_LAUNCHER_APP_SENDER_ID",
        "POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256",
        "POSTGRES_CI_ATTESTATION_PUBLIC_KEY",
        "POSTGRES_PR_CHECK_APP_ID",
    },
    "Public repository policy variable inventory drifted.",
)

secret_references = set()
variable_references = set()
for workflow_path in workflow_paths:
    workflow_text = read_required_text(workflow_path, f"workflow {workflow_path.name}")
    secret_references.update(re.findall(r"secrets\.([A-Z][A-Z0-9_]*)", workflow_text))
    variable_references.update(re.findall(r"vars\.([A-Z][A-Z0-9_]*)", workflow_text))
for entry in github_entries:
    destination = entry.get("destination")
    kind = entry.get("kind")
    require(kind in {"secret", "variable"}, f"Credential destination {destination} has an invalid kind.")
    expected_references = secret_references if kind == "secret" else variable_references
    require(destination in expected_references, f"Credential destination {destination} has the wrong kind or no workflow consumer.")
inventory_secret_names = {entry["destination"] for entry in github_entries if entry["kind"] == "secret"}
inventory_variable_names = {entry["destination"] for entry in github_entries if entry["kind"] == "variable"} | repository_destinations
require(secret_references <= inventory_secret_names, "A workflow secret is absent from the protected-environment inventory.")
require(variable_references <= inventory_variable_names, "A workflow variable is absent from the reviewed variable inventory.")

pki_item = "Brio Staging - PKI and Backup Keys"
pki_destinations = {
    (entry["environment"], entry["destination"])
    for entry in github_entries if entry["item"] == pki_item and entry["destination"].endswith("_PEM")
}
require(
    pki_destinations == {
        ("canary", "POSTGRES_CA_PEM"),
        ("canary", "POSTGRES_SERVER_CERT_PEM"),
        ("canary", "POSTGRES_SERVER_KEY_PEM"),
        ("canary", "BRIO_BACKUP_RECIPIENT_CERT_PEM"),
        ("staging-brio-identity-db", "BRIO_BACKUP_RECIPIENT_CERT_PEM"),
    },
    "Brio PKI fields must match their exact workflow destinations.",
)
require(all(entry.get("boundary") in {"host-root-file", "host-root-setting", "operator-stdin", "operator-verification"} for entry in non_github_entries), "Non-GitHub credential boundary is invalid.")
for canonical_item in {
    "Hetzner App Server makepad", "Hetzner Database Server makepad",
    "Brio Staging - PostgreSQL",
    "PostgreSQL · shared Swarm deployment", pki_item,
    "PostgreSQL · Brio identity release orchestrator",
    "PostgreSQL · Keycloak cohort source reader", "Makepad Docker Hardened Images",
    "PostgreSQL · PR Checks App", "PostgreSQL · JIT Launcher App",
    "PostgreSQL · JIT hypervisor attestation",
}:
    require(canonical_item in readme, f"README credential inventory is missing canonical Proton item {canonical_item}.")
ssh_source_by_environment = {
    environment: {
        entry["item"] for entry in github_entries
        if entry["environment"] == environment and entry["destination"].startswith("DEPLOY_SSH_")
    }
    for environment in ("canary", "production")
}
require(
    ssh_source_by_environment == {
        "canary": {"Hetzner App Server makepad"},
        "production": {"Hetzner App Server makepad"},
    },
    "Shared-Swarm deployment credentials must target the application Swarm host.",
)
native_ssh_field_by_suffix = {
    "HOST": "host", "PORT": "port", "USER": "user",
    "PRIVATE_KEY": "private_key", "KNOWN_HOSTS": "known_hosts",
}
for entry in github_entries:
    if entry.get("item") not in {"Hetzner App Server makepad", "Hetzner Database Server makepad"}:
        continue
    suffix = next((suffix for suffix in native_ssh_field_by_suffix if entry["destination"].endswith(f"SSH_{suffix}")), None)
    require(suffix is not None, f"Unexpected SSH destination {entry['destination']}.")
    require(
        entry.get("field") == native_ssh_field_by_suffix[suffix],
        f"SSH destination {entry['destination']} must use its native Proton source field.",
    )
for required in (
    "--sync requires one explicit --environment",
    "--sync-repository-variables requires --confirm Makepad-fr/postgres:repository-variables",
    "pass-cli item list",
    "pass-cli item view",
    'gh secret set "${destination}" --repo "${repository}" --env "${environment}"',
    'gh variable set "${destination}" --repo "${repository}" --env "${environment}"',
    'gh variable set "${destination}" --repo "${repository}"',
    'gh variable get "${destination}" --repo "${repository}" --json value',
    "REPOSITORY name=%s policy=public-active-main",
    'status=forbidden',
    "environment_policy_reconciler",
    "protection=exact-reviewed-matrix",
):
    require(required in credential_sync, f"Credential sync helper is missing fail-closed control: {required}")
for forbidden in ("gh secret delete", "gh variable delete", "pass-cli item delete"):
    require(forbidden not in credential_sync, f"Credential sync helper must never delete provider state: {forbidden}")
require("if [[ \"${mode}\" == check ]]" in credential_sync, "Credential sync helper must branch before Proton field reads.")
require(credential_sync.find('if [[ "${mode}" == check ]]') < credential_sync.find("pass-cli item view"), "Check mode must exit before any Proton field-value read.")
for required in (
    "POSTGRES_CI_LAUNCHER_APP_SENDER_ID",
    "POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256",
    "POSTGRES_CI_ATTESTATION_PUBLIC_KEY",
    "POSTGRES_PR_CHECK_APP_ID",
    "ED25519_SPKI_PREFIX",
    "MAX_PROVIDER_INTEGER",
):
    require(required in repository_anchor_validator, f"Repository trust-anchor validator is missing: {required}")
for required in (
    "assert_no_value_read_or_write",
    "FAKE_REPOSITORY_LEGACY_KIND=secret",
    "FAKE_INVALID_REPOSITORY=1",
    "FAKE_INVALID_PROTECTION",
    "FAKE_MISSING_FIELD",
    "FAKE_OVERSIZED_FIELD",
    "wrong public/secret classification",
    "PKI destinations do not match",
    "FAKE_INVALID_ANCHOR_FIELD",
    "FAKE_READBACK_MISMATCH",
    "repository_last_source_read < repository_first_write",
):
    require(required in credential_sync_test, f"Credential sync behavioral test is missing adversarial case: {required}")
require("./scripts/test-sync-github-environments.sh" in ci_runner, "CI must run the credential sync behavioral test.")
require("pass-cli item view --item-title '<item>' --field '<field>'" in readme, "README must document stdin-only pass-cli credential synchronization.")
require("| gh secret set '<NAME>' --env '<environment>' --repo 'Makepad-fr/postgres'" in normalized_readme, "README must mirror workflow secrets only into protected GitHub environments.")
for policy in (
    "hostnossl brio_staging",
    "hostnossl keycloak_brio_staging",
    "hostssl brio_staging",
    "hostssl keycloak_brio_staging",
):
    require(policy in runtrace_hba, f"PostgreSQL HBA policy is missing {policy}.")

for path in (
    canary_deploy_path,
    identity_deploy_path,
    tmp_cleaner_path,
    repo_root / "scripts/test-brio-deploy-guards.sh",
    deployment_failure_test_path,
    deployment_failure_fixture_path,
    repo_root / "scripts/capture-keycloak-cohort-backups.sh",
    repo_root / "scripts/restore-keycloak-cohort-backups.sh",
    repo_root / "scripts/test-keycloak-cohort-evidence.sh",
    repo_root / "scripts/test-keycloak-cohort-hardening.sh",
    cohort_dispatch_path,
    cohort_host_installer_path,
    cohort_cleaner_path,
    cohort_cleaner_installer_path,
    repo_root / "scripts/run-postgres-ci-jit-vm.sh",
    pr_jit_result_validator_path,
    repo_root / "scripts/test-postgres-ci-jit-result.sh",
    repo_root / "scripts/run-postgres-ci-queue-controller.sh",
    repo_root / "scripts/configure-postgres-ci-runner-group.sh",
):
    require(os.access(path, os.X_OK), f"Brio deployment script must be executable: {path}")

for required in (
    "BRIO_BACKUP_RECIPIENT_CERT_PEM",
    "BRIO_STAGING_BACKUP_DB_PASSWORD",
    "BRIO_STAGING_DB_PASSWORD",
    "POSTGRES_CANARY_SUPERUSER_PASSWORD",
    "POSTGRES_CA_PEM",
    "POSTGRES_SERVER_CERT_PEM",
    "POSTGRES_SERVER_KEY_PEM",
    "Materialize job-scoped Brio canary inputs",
    "postgres-brio-canary-runtime-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}",
    "install -d -m 0700",
    "chmod 0600",
    "bootstrap/brio-staging-app.sql",
    "deploy-brio-canary-postgres.sh",
    "Remove remote job-scoped deployment material",
):
    require(required in manual_deploy_workflow, f"Canary workflow is missing secure Brio input/deploy control: {required}")
require("makepad-postgres-deploy" in manual_deploy_workflow, "Manual deployment must use the repository-scoped deploy runner label.")
require("group: Postgres Deploy" in manual_deploy_workflow, "Manual deployment must use the protected Postgres Deploy runner group.")
require('[[ "${GITHUB_REF}" == "refs/heads/main" ]]' in manual_deploy_workflow, "Manual deployment must refuse unreviewed refs.")
require("pull_request_target:" in ci_workflow, "PR CI must execute protected-base workflow code.")
require("github.event.pull_request.head.repo.full_name == github.repository" in ci_workflow, "PR CI must reject forks.")
require("ref: ${{ github.event.pull_request.head.sha }}" in ci_workflow, "PR CI must check out the exact candidate head.")
require("group: org/Postgres PR Ephemeral" in ci_workflow, "PR CI must use the selected-workflow ephemeral runner group.")
require("group: org/Postgres Main CI" in ci_workflow, "Main CI must use its protected selected-workflow runner group.")
require("repository_dispatch:" in pr_finalizer_workflow and "types: [postgres-pr-ci-attestation]" in pr_finalizer_workflow and "environment: postgres-ci-attestation" in pr_finalizer_workflow, "PR result publication must accept only protected signed teardown dispatches.")
require("POSTGRES_PR_CHECK_APP_PRIVATE_KEY" in pr_finalizer_workflow and 'CHECK_NAMES = ["postgres-ci"]' in pr_check_publisher, "The required PR result must be published by its dedicated Checks App.")
for required in (
    "makepad.postgres.ci-attestation.v1",
    "verifySignature",
    "registration_absent",
    "runnerLookupStatus !== 404",
    "POSTGRES_CI_ATTESTATION_PUBLIC_KEY",
    "POSTGRES_CI_LAUNCHER_APP_SENDER_ID",
):
    require(required in pr_check_publisher + pr_finalizer_workflow, f"Signed JIT teardown finalization is missing: {required}")
for required in (
    "generate-jitconfig",
    "--jitconfig",
    "qemu-img convert",
    "virsh undefine",
    "nft delete table",
    "registration_absent",
    "dispatch-ci-attestation.mjs",
    "makepad-postgres-pr-ephemeral",
    "resources.json",
    "--reconcile",
    "POSTGRES_CI_RESULT_POLL_ATTEMPTS",
    "verify-postgres-ci-jit-result.py",
):
    require(required in pr_jit_launcher, f"Disposable PR VM launcher is missing: {required}")
require('base.get("sha") != workflow_sha' in pr_jit_result_validator, "The final JIT attestation verifier must bind the PR base SHA to the workflow SHA.")
require("test-postgres-ci-jit-result.sh" in ci_runner, "CI must run the executable final JIT base-SHA regression test.")
for required in (
    'job.name === "policy-and-integration"',
    "state.jobs[String(job.jobID)]",
    "await atomicState(stateFile, state)",
    "await runLauncher",
    "await reconcileIncompleteJobs",
    "launchID",
    'organization_self_hosted_runners: "write"',
):
    require(required in pr_queue_controller, f"Supervised JIT queue controller is missing: {required}")
require('"allows_public_repositories": True' in pr_runner_policy, "The selected-workflow runner policy must explicitly support the public PostgreSQL repository.")
require("makepad-postgres-ci-attestor" in pr_runner_policy and "makepad-postgres-pr-ephemeral" in pr_runner_policy, "Runner policy must separate the persistent attestor from the JIT-only label.")
require('association.head?.repo?.id !== run.repository?.id' in pr_check_publisher, "The PR Checks publisher must independently reject fork runs.")
require('association.base?.sha !== attestation.run.workflow_sha' in pr_check_publisher, "The PR Checks publisher must bind the exact PR base SHA.")
require('association.base?.sha !== run.head_sha' in pr_queue_controller, "The queue controller must bind the exact PR base SHA before launch.")
require('"${RUNNER_TEMP}"/postgres-deploy-*|"${RUNNER_TEMP}"/postgres-brio-canary-runtime-*|"${RUNNER_TEMP}"/postgres-brio-vif-runtime-*' in manual_deploy_workflow, "Cleanup must allow only the exact job-scoped deployment directory prefixes.")
require("for cleanup_target in" in manual_deploy_workflow, "Manual workflow cleanup must use a narrowly named cleanup target variable.")
require("group: postgres-shared-swarm-target" in manual_deploy_workflow, "Canary and production must share one target-wide Swarm concurrency group.")
require("postgres-swarm-${{ inputs.environment }}" not in manual_deploy_workflow, "Swarm concurrency must not split by environment on the shared target.")
require("${REMOTE_DIR}/stack.yml" not in manual_deploy_workflow + remote_deploy, "Deployment must never write the shared remote stack.yml path.")
require('stack_file="${generated_dir}/stack-${stack_name}-${deploy_env}.yml"' in remote_deploy, "Generated stack configuration must stay inside the unique run bundle.")

for required in (
    "postgres-server-cert.pem",
    "postgres-server-key.pem",
    "PostgreSQL TLS certificate and private key do not match",
    "-checkhost makepad-postgres-brio-staging",
    "prevalidate_swarm_config",
    "content-sha256",
    "prevalidate_swarm_secret",
    "bootstrap/brio-staging-app.sql",
    "\\getenv brio_staging_app_password",
    "PGSSLMODE=verify-full",
    "Plaintext access to brio_staging was unexpectedly accepted",
    "Brio application role was unexpectedly accepted by a non-target database",
    "show default_transaction_read_only",
    "makepad-postgres-brio-staging",
    "last-success.json",
    "sha256sum --check --status",
    "openssl cms -cmsout",
):
    require(required in canary_deploy, f"Canary deployment orchestrator is missing: {required}")
require('-e PGPASSWORD=' not in canary_deploy, "Canary deployment must not put database passwords in Docker command arguments.")
shared_network_validation = canary_deploy.find('prevalidate_network "${db_network}" false')
incomplete_recovery = canary_deploy.find("recover_incomplete_journals", shared_network_validation)
database_journal = canary_deploy.find('run_db_transaction prepare "${journal_stage}"', incomplete_recovery)
require(-1 not in (shared_network_validation, incomplete_recovery, database_journal) and shared_network_validation < incomplete_recovery < database_journal, "The validated shared database network must precede recovery and first-deployment journal capture.")
for required in (
    "assert_no_symlink_components",
    "candidate-stack.yml",
    "docker stack config",
    'tar --numeric-owner --no-recursion -cpf "$stage/rollback/managed.tar"',
    "rollback_canary",
    "prior-service-spec-hashes.list",
    "mv -fT \"$super_stage\"",
    "rollback_armed=0",
):
    require(required in canary_deploy, f"Canary atomic deployment contract is missing: {required}")

for required in (
    "environment: staging-brio-identity-db",
    'refs/heads/main',
    "restart-standalone-postgres-for-brio-staging",
    "backup_restore_confirmed",
    "BRIO_IDENTITY_DB_DEPLOY_SSH_PRIVATE_KEY",
    "BRIO_IDENTITY_DB_DEPLOY_SSH_KNOWN_HOSTS",
    "BRIO_IDENTITY_DB_DEPLOY_SSH_HOST",
    "BRIO_IDENTITY_DB_DEPLOY_SSH_USER",
    "KEYCLOAK_BRIO_STAGING_DB_PASSWORD",
    "KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD",
    "BRIO_BACKUP_RECIPIENT_CERT_PEM",
    "BRIO_IDENTITY_DB_HOSTNAME",
    "BRIO_KEYCLOAK_DB_SOURCE_CIDR",
    "deploy-brio-identity-db-host.sh",
    "Remove remote job-scoped identity secrets",
    "postgres-brio-identity-bundle-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}",
    "ensure-brio-tmp-cleaner.sh",
    "brio-db-deployment-evidence-${{ github.run_id }}-${{ github.run_attempt }}",
    "brio-db-deployment-evidence.json",
    "makepad.brio-db-deployment-evidence.v1",
    "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
    "makepad-postgres-deploy",
    "group: Postgres Deploy",
):
    require(required in identity_workflow, f"Standalone identity DB workflow is missing: {required}")
for required in (
    "environment: release-brio-identity-db",
    "KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN",
    "verify-brio-database.yml/dispatches",
    "verify-brio-release-evidence.py postgres-run",
    "verify-brio-release-evidence.py postgres-evidence",
    "verify-brio-release-evidence.py verifier-run",
    "verify-brio-release-evidence.py attestation",
    "brio-db-path-attestation",
    "fetch_complete_listing",
    '--config -',
    'release_token=${RELEASE_ORCHESTRATOR_TOKEN}',
    'unset RELEASE_ORCHESTRATOR_TOKEN',
):
    require(required in release_workflow + release_evidence_validator, f"Protected two-phase database release orchestrator is missing: {required}")
for forbidden in ("brio-db-path-attestation.json\" <<", "actions/upload-artifact"):
    require(forbidden not in release_workflow, "The release orchestrator must never synthesize or republish Keycloak attestation evidence.")
for required in (
    "name: Verify Keycloak Cohort Restore Compatibility",
    "workflow_dispatch:",
    "keycloak_release_sha:",
    "environment: keycloak-cohort-restore",
    "KEYCLOAK_COHORT_SOURCE_TOKEN",
    "repos/Makepad-fr/keycloak/git/ref/heads/main",
    "keycloak-cohort-restore-evidence-${{ github.run_id }}-${{ github.run_attempt }}",
    "keycloak-cohort-restore-evidence.json",
    "makepad.keycloak-cohort-restore-evidence.v2",
    "restored-databases-compatible",
    "dhi.io/keycloak:26-debian13@sha256:fab1484b1762fd1269e63a40f068ec73ea75b498eaaa5d02f62f022a5d00ff0f",
    "KEYCLOAK_UPSTREAM_VERSION=26.7.3",
    "restore-keycloak-cohort-backups.sh",
    "verify-keycloak-cohort-evidence.py",
):
    require(required in cohort_workflow + cohort_evidence_validator, f"Six-database Keycloak cohort producer is missing: {required}")
require("vars." not in cohort_workflow, "The cohort producer must not accept a mutable repository variable as release evidence.")
for slug, database in (
    ("betacrew", "keycloak_betacrew"),
    ("catwlk", "keycloak_catwlk"),
    ("makepad", "keycloak_makepad"),
    ("runtrace", "keycloak_runtrace"),
    ("vestiaire", "keycloak_vestiaire"),
    ("vif", "keycloak_vif"),
):
    require(slug in cohort_evidence_validator and database in cohort_capture + cohort_restore, f"Cohort contract is missing {slug}/{database}.")
for required in ("pg_dump", "--no-owner", "--no-privileges", "pg_restore --list", "postgres-postgres-1"):
    require(required in cohort_capture, f"Live cohort capture is missing: {required}")
for required in (
    "pg_restore", "start-dev", "/health/ready", "realm_smtp_config",
    "authentication_execution", "role_attribute", "composite_role", "client_scope_role_mapping", "protocol_mapper_config",
    "identity_provider_config", "component_config", "required_action_provider",
    "configuration_regression", "catwlk-custom-provider", "POSTGRES_PASSWORD_FILE=/run/secrets/postgres-password",
):
    require(required in cohort_restore, f"Disposable cohort restore/startup verifier is missing: {required}")
require("scp " not in cohort_workflow and "remote_script=" not in cohort_workflow, "Cohort workflow must not execute checked-out code on the database host.")
for required in (
    "SSH_ORIGINAL_COMMAND", "sha256sum", 'sha256sum "${cleaner}"', "systemctl is-enabled", "systemctl is-active",
    "--property=Result", "--property=ExecMainStatus",
    "probe)", "capture)", "fetch)", "cleanup)",
):
    require(required in cohort_dispatch, f"Cohort forced-command dispatcher is missing: {required}")
require('restrict,command="/usr/local/libexec/makepad/keycloak-cohort-capture-dispatch"' in cohort_host_installer, "Capture key must be bound to the exact forced command.")
for required in ("makepad.cleanup.contract", "makepad.cleanup.expires-epoch", "docker container ls -aq", "docker network ls -q"):
    require(required in cohort_cleaner, f"Cohort resource cleaner is missing: {required}")
require("install-keycloak-cohort-cleaner.sh" in cohort_host_installer and "makepad-keycloak-cohort-cleaner.timer" in cohort_cleaner_installer, "Capture host must install the persistent cohort resource cleaner.")
require("makepad.keycloak-config-fingerprint.v2" in cohort_evidence_validator, "Cohort evidence must bind the v2 fingerprint schema.")
require("test-keycloak-cohort-hardening.sh" in ci_runner, "CI must run the cohort hardening contract test.")
require("POSTGRES_HOST_COMPOSE_PROJECT" not in identity_workflow + readme, "The standalone Compose project must be fixed in code, not selected by a workflow variable.")

for required in (
    "Swarm.LocalNodeState",
    '[[ "${swarm_state}" == "inactive" ]]',
    "/srv/makepad/postgres",
    "compose_project=postgres",
    "expected_container_name=postgres-postgres-1",
    "com.docker.compose.project",
    "com.docker.compose.service",
    "com.docker.compose.oneoff",
    "bind|/var/lib/makepad/postgres|true",
    '"${network_mode}" == "host"',
    "keycloak-db-source-cidr",
    "-checkip",
    "127.0.0.1/32",
    "65.21.134.125",
    "88.99.209.165/32",
    "Failed to render ordered, exact source-restricted Keycloak Brio HBA rules",
    "--force-recreate",
    "--project-name",
    "bootstrap/keycloak-brio-staging.sql",
    "\\getenv keycloak_brio_staging_app_password",
    "PGHOSTADDR=127.0.0.1",
    "PGSSLMODE=verify-full",
    "Plaintext Keycloak Brio database access was unexpectedly accepted",
    "Keycloak Brio role was unexpectedly accepted by a non-target database",
    "show default_transaction_read_only",
    "last-success.json",
    "sha256sum --check --status",
    "openssl cms -cmsout",
    "restore_snapshot",
    "rollback_deployment",
    "rollback_armed=1",
    "trap handle_exit EXIT",
    "trap 'exit 129' HUP",
    "trap 'exit 130' INT",
    "trap 'exit 143' TERM",
    'tar --numeric-owner -cpf "$stage/rollback/managed.tar"',
    'identity-backups.tar',
    'identity-backup-absent',
    "up -d --remove-orphans --wait --force-recreate",
    "preserve_recovery_evidence",
    "postgres-recovery/brio-identity",
    "RECOVERY_REQUIRED",
    "recovery_id=${identifier}",
):
    require(required in identity_deploy, f"Standalone identity DB orchestrator is missing: {required}")
require("docker stack" not in identity_deploy and "docker swarm" not in identity_deploy, "Standalone identity DB deployment must not invoke Swarm deployment commands.")
require('"${key_uid}:${key_gid}:${key_mode}" == "70:70:400"' in identity_deploy, "Standalone DB-VM preflight must preserve the exact live server-key owner/group/mode contract.")
require('-e PGPASSWORD=' not in identity_deploy, "Identity DB deployment must not put database passwords in Docker command arguments.")
snapshot_index = identity_deploy.find('tar --numeric-owner -cpf "$stage/rollback/managed.tar"')
arm_index = identity_deploy.find("rollback_armed=1", snapshot_index)
first_install_index = identity_deploy.find('install_host_path "${candidate_compose}"', arm_index)
fresh_backup_index = identity_deploy.find('[[ "${backup_verified}" == "1" ]]', first_install_index)
disarm_index = identity_deploy.find("rollback_armed=0", fresh_backup_index)
require(-1 not in (snapshot_index, arm_index, first_install_index, fresh_backup_index, disarm_index), "Standalone rollback boundary markers are incomplete.")
require(snapshot_index < arm_index < first_install_index < fresh_backup_index < disarm_index, "Rollback must arm after snapshot and disarm only after probes and fresh backup verification.")
for required in (
    "MAKEPAD_POSTGRES_TLS_CERT_HOST_PATH=",
    "MAKEPAD_POSTGRES_TLS_KEY_HOST_PATH=",
    "MAKEPAD_POSTGRES_RUNTRACE_HBA_HOST_PATH=",
    "MAKEPAD_POSTGRES_BRIO_BACKUP_SCRIPT_HOST_PATH=",
):
    require(required in production_env, f"Production host environment is missing explicit standalone input: {required}")
require("test-brio-deploy-guards.sh" in ci_runner, "CI must run the deployment guard contract test.")
require("test-brio-deployment-failures.sh" in ci_runner, "CI must run executable Brio deployment failure-injection tests.")
for required in (
    "after-managed-file-promotion",
    "term-after-managed-file-promotion",
    "after-stack-deploy",
    "rollback-restore",
    "rollback-recreate",
    "RECOVERY_REQUIRED",
    ".State.Restarting",
    "unexpected cleaner command",
    "cleaner-running-output",
    "symlink component",
):
    require(required in deployment_failure_fixture, f"Failure-injection fixture is missing behavioral case: {required}")
require("PGHOSTADDR: 127.0.0.1" in host_compose, "Standalone identity backup must use a deterministic local transport address while verifying the configured certificate host.")
for required in (
    "makepad-postgres-brio-tmp-cleaner",
    "--restart unless-stopped",
    "--read-only",
    "--cap-drop ALL",
    "--security-opt no-new-privileges",
    "type=bind,src=/tmp,dst=/host-tmp",
    "-name 'postgres-brio-*'",
    "-mmin +180",
    "sleep 900",
    "RECOVERY_REQUIRED",
    "observed_command",
    "verify_running",
    ".State.Restarting",
):
    require(required in tmp_cleaner, f"Host TTL cleaner is missing its restricted contract: {required}")
for workflow in (manual_deploy_workflow, identity_workflow):
    require("ensure-brio-tmp-cleaner.sh" in workflow, "Every Brio deployment target must install the host-enforced TTL cleaner.")
    require(workflow.find("ensure-brio-tmp-cleaner.sh") < workflow.find('scp "${scp_opts[@]}" "${runtime_dir}'), "TTL cleaner must be installed before job secrets are transferred.")
for required in (
    "Verify Brio Identity Database Path",
    "Verify Brio DB path for PostgreSQL run <postgres-run-id>",
    "brio-db-path-ok",
    "65.21.134.125",
    "88.99.209.165",
    "no Keycloak database credential is granted to the PostgreSQL runner",
):
    require(required in normalized_readme, f"README is missing the Keycloak-origin database release gate: {required}")
PY
