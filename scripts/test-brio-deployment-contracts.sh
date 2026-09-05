#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)

REPO_ROOT="${repo_root}" python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["REPO_ROOT"])
manual = (root / ".github/workflows/manual-deploy.yml").read_text()
identity_workflow = (root / ".github/workflows/deploy-brio-identity-db.yml").read_text()
release_workflow = (root / ".github/workflows/release-brio-identity-db.yml").read_text()
ci_workflow = (root / ".github/workflows/ci.yml").read_text()
finalizer_workflow = (root / ".github/workflows/pr-ci-result.yml").read_text()
check_publisher = (root / "scripts/publish-pr-ci-check.mjs").read_text()
jit_launcher = (root / "scripts/run-postgres-ci-jit-vm.sh").read_text()
queue_controller = (root / "scripts/postgres-ci-queue-controller.mjs").read_text()
cohort_workflow = (root / ".github/workflows/verify-keycloak-cohort-restores.yml").read_text()
cohort_validator = (root / "scripts/verify-keycloak-cohort-evidence.py").read_text()
identity = (root / "scripts/deploy-brio-identity-db-host.sh").read_text()
canary = (root / "scripts/deploy-brio-canary-postgres.sh").read_text()
stack = (root / "scripts/deploy-postgres-stack.sh").read_text()
vif = (root / "bootstrap/vif-app.sql").read_text()
hba = (root / "config/runtrace-pg_hba.conf").read_text().splitlines()
canary_env = (root / "envs/canary/.env.db").read_text()
production_env = (root / "envs/production/.env.db").read_text()

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require("makepad_postgres_canary_runtrace_hba_v3" in canary_env, "canary HBA must use immutable v3")
require("makepad_postgres_runtrace_hba_v3" in production_env, "production HBA must use immutable v3")
require("runtrace_hba_v2" not in canary_env + production_env, "active HBA v2 names must not drift")

records = [tuple(line.split()) for line in hba if line.strip() and not line.lstrip().startswith("#")]
for allow, reject in (
    (("hostssl", "keycloak_brio_staging", "keycloak_brio_staging_app", "all", "scram-sha-256"), ("host", "all", "keycloak_brio_staging_app", "all", "reject")),
    (("hostssl", "keycloak_brio_staging", "keycloak_brio_staging_backup", "127.0.0.1/32", "scram-sha-256"), ("host", "all", "keycloak_brio_staging_backup", "all", "reject")),
):
    require(records.index(allow) < records.index(reject), "identity HBA allow must precede its role rejection")

require("group: postgres-shared-swarm-target" in manual, "shared Swarm target needs one concurrency group")
require('remote_bundle="${REMOTE_DIR}/.deploy/postgres-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"' in manual, "Swarm bundle must be unique per attempt")
require("${REMOTE_DIR}/stack.yml" not in manual + stack, "shared stack.yml is forbidden")
require('stack_file="${generated_dir}/stack-${stack_name}-${deploy_env}.yml"' in stack, "stack config must stay in the run bundle")
require("MAKEPAD_POSTGRES_VIF_DB_PASSWORD" not in manual + stack, "VIF secret must not persist in .env.deploy")
require("-v vif_password=" not in stack, "VIF secret must not enter psql argv")
require("\\getenv vif_password VIF_PASSWORD" in vif, "VIF bootstrap must use getenv")

for marker in (
    "compose_project=postgres",
    "expected_container_name=postgres-postgres-1",
    "com.docker.compose.project",
    "com.docker.compose.service",
    "com.docker.compose.oneoff",
    "bind|/var/lib/makepad/postgres|true",
    '"${network_mode}" == "host"',
    'tar --numeric-owner -cpf "$stage/rollback/managed.tar"',
    "restore_snapshot",
    "rollback_deployment",
    "trap handle_exit EXIT",
    "trap 'exit 129' HUP",
    "trap 'exit 130' INT",
    "trap 'exit 143' TERM",
    "up -d --remove-orphans --wait --force-recreate",
):
    require(marker in identity, f"standalone contract missing: {marker}")

snapshot = identity.index('tar --numeric-owner -cpf "$stage/rollback/managed.tar"')
armed = identity.index("rollback_armed=1", snapshot)
mutation = identity.index('install_host_path "${candidate_compose}"', armed)
backup = identity.index('[[ "${backup_verified}" == "1" ]]', mutation)
disarmed = identity.index("rollback_armed=0", backup)
require(snapshot < armed < mutation < backup < disarmed, "rollback boundary/order is unsafe")

require("/tmp/postgres-brio-identity-bundle-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" in identity_workflow, "identity bundle must be per attempt")
require("POSTGRES_HOST_COMPOSE_PROJECT" not in identity_workflow, "standalone project must not be user-selected")
require("brio-db-deployment-evidence-${{ github.run_id }}-${{ github.run_attempt }}" in identity_workflow, "phase one must publish its exact immutable deployment artifact")
require(identity_workflow.count("actions/upload-artifact@") == 1, "phase one must publish exactly one artifact")
require("brio-db-deployment-evidence.json" in identity_workflow and "makepad.brio-db-deployment-evidence.v1" in identity_workflow, "phase one must use the canonical single-file schema")
for marker in (
    "environment: release-brio-identity-db",
    "KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN",
    "verify-brio-release-evidence.py postgres-run",
    "verify-brio-release-evidence.py postgres-evidence",
    "verify-brio-database.yml/dispatches",
    "verify-brio-release-evidence.py verifier-run",
    "verify-brio-release-evidence.py attestation",
    'release_token=${RELEASE_ORCHESTRATOR_TOKEN}',
    'unset RELEASE_ORCHESTRATOR_TOKEN',
    '--config -',
):
    require(marker in release_workflow, f"protected release orchestrator missing: {marker}")
require("actions/upload-artifact@" not in release_workflow, "release orchestrator must not synthesize or republish attestation")
require("pull_request_target:" in ci_workflow, "PR CI must use protected-base workflow code")
require("github.event.pull_request.head.repo.full_name == github.repository" in ci_workflow, "PR CI must reject forks")
require("ref: ${{ github.event.pull_request.head.sha }}" in ci_workflow, "PR CI must check out the exact head")
require("repository_dispatch:" in finalizer_workflow and "types: [postgres-pr-ci-attestation]" in finalizer_workflow and "environment: postgres-ci-attestation" in finalizer_workflow, "PR CI result must require signed hypervisor teardown")
require("POSTGRES_PR_CHECK_APP_PRIVATE_KEY" in finalizer_workflow and 'CHECK_NAMES = ["postgres-ci"]' in check_publisher, "required PR check must be App-bound")
for marker in (
    "makepad.postgres.ci-attestation.v1",
    "verifySignature",
    "registration_absent",
    "runnerLookupStatus !== 404",
    "makepad-postgres-pr-ephemeral",
):
    require(marker in check_publisher + jit_launcher, f"signed disposable PR boundary missing: {marker}")
for marker in ("generate-jitconfig", "--jitconfig", "virsh undefine", "nft delete table", "dispatch-ci-attestation.mjs", "resources.json", "--reconcile", "POSTGRES_CI_RESULT_POLL_ATTEMPTS"):
    require(marker in jit_launcher, f"JIT hypervisor teardown contract missing: {marker}")
require('job.name === "policy-and-integration"' in queue_controller and "await runLauncher" in queue_controller, "queue controller must bind and supervise the exact disposable PR job")
require("await reconcileIncompleteJobs" in queue_controller and "launchID" in queue_controller, "queue controller must reconcile deterministic incomplete launches before polling")
require('association.base?.sha !== run.head_sha' in queue_controller, "queue controller must bind the exact PR base SHA")
require('association.base?.sha !== attestation.run.workflow_sha' in check_publisher, "attestor must bind the exact PR base SHA")
for marker in (
    "name: Verify Keycloak Cohort Restore Compatibility",
    "keycloak-cohort-restore-evidence-${{ github.run_id }}-${{ github.run_attempt }}",
    "makepad.keycloak-cohort-restore-evidence.v2",
    "restored-databases-compatible",
    "keycloak_release_sha",
):
    require(marker in cohort_workflow + cohort_validator, f"five-database cohort evidence contract missing: {marker}")
require("vars." not in cohort_workflow, "cohort evidence cannot rely on a mutable repository variable")
require("Ensure interrupted cohort material expires on the release host" in cohort_workflow, "cohort workflow must verify the release-host TTL guard before credentials or dumps")
require(cohort_workflow.index("Ensure interrupted cohort material expires on the release host") < cohort_workflow.index("Configure isolated SSH and registry state"), "release-host TTL guard must precede credential material")
require('"probe ${helper_digest} ${cleaner_digest}"' in cohort_workflow and cohort_workflow.index('"probe ${helper_digest} ${cleaner_digest}"') < cohort_workflow.index('"capture ${GITHUB_RUN_ID}'), "remote helper/cleaner digest and TTL probe must precede every dump")
require("scp " not in cohort_workflow and "remote_script=" not in cohort_workflow, "cohort workflow must use only the forced-command capture protocol")
require('/tmp/postgres-keycloak-cohort-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}' in cohort_workflow, "cohort sensitive material must live under the exact TTL-cleaned namespace")
shared_network_validation = canary.index('prevalidate_network "${db_network}" false')
incomplete_recovery = canary.index("recover_incomplete_journals", shared_network_validation)
database_journal = canary.index('run_db_transaction prepare "${journal_stage}"', incomplete_recovery)
require(shared_network_validation < incomplete_recovery < database_journal, "shared DB transport validation must precede recovery and first-deploy journaling")
for marker in (
    "assert_no_symlink_components",
    "prevalidate_swarm_config",
    "prevalidate_network",
    "docker stack config",
    'tar --numeric-owner --no-recursion -cpf "$stage/rollback/managed.tar"',
    "rollback_canary",
    "prior-service-spec-hashes.list",
    'mv -fT "$super_stage"',
    "postgres-recovery/brio-canary",
    "DATABASE_MUTATION_ARMED",
    "STACK_MUTATION_ARMED",
    "keycloak_brio_staging_backup",
    "/usr/local/bin/run-brio-encrypted-backup.sh",
):
    require(marker in canary, f"canary transactional contract missing: {marker}")
for marker in ("preserve_recovery_evidence", "postgres-recovery/brio-identity", "DATABASE_MUTATION_ARMED", "RECOVERY_REQUIRED"):
    require(marker in identity, f"identity durable recovery contract missing: {marker}")
for marker in ("identity-backups.tar", "identity-backup-absent", "recovery_id=${identifier}"):
    require(marker in identity, f"identity exact backup/recovery contract missing: {marker}")

for workflow in (manual, identity_workflow):
    cleaner = workflow.index("ensure-brio-tmp-cleaner.sh")
    secret_copy = workflow.index('scp "${scp_opts[@]}" "${runtime_dir}')
    require(cleaner < secret_copy, "host TTL cleaner must precede secret transfer")
PY

cleaner_root=$(mktemp -d /tmp/postgres-brio-cleaner-test-contract-XXXXXX)
cleanup_test_root() {
  [[ "${cleaner_root}" =~ ^/tmp/postgres-brio-cleaner-test-contract-[A-Za-z0-9]+$ ]] || return 1
  find "${cleaner_root}" -depth -delete
}
trap cleanup_test_root EXIT
mkdir "${cleaner_root}/postgres-brio-old" "${cleaner_root}/postgres-brio-recovery" \
  "${cleaner_root}/postgres-brio-fresh" "${cleaner_root}/postgres-keycloak-cohort-old" \
  "${cleaner_root}/unrelated-old"
printf '%s\n' recovery-required > "${cleaner_root}/postgres-brio-recovery/RECOVERY_REQUIRED"
touch -t 202001010000 "${cleaner_root}/postgres-brio-old" "${cleaner_root}/postgres-brio-recovery" \
  "${cleaner_root}/postgres-keycloak-cohort-old" "${cleaner_root}/unrelated-old"
"${script_dir}/ensure-brio-tmp-cleaner.sh" test-clean-once "${cleaner_root}"
[[ ! -e "${cleaner_root}/postgres-brio-old" ]] || { echo "TTL cleaner retained an expired Brio directory." >&2; exit 1; }
[[ ! -e "${cleaner_root}/postgres-keycloak-cohort-old" ]] || { echo "TTL cleaner retained expired Keycloak cohort material." >&2; exit 1; }
[[ -d "${cleaner_root}/postgres-brio-fresh" ]] || { echo "TTL cleaner removed a fresh Brio directory." >&2; exit 1; }
[[ -f "${cleaner_root}/postgres-brio-recovery/RECOVERY_REQUIRED" ]] || { echo "TTL cleaner removed required recovery evidence." >&2; exit 1; }
[[ -d "${cleaner_root}/unrelated-old" ]] || { echo "TTL cleaner removed unrelated content." >&2; exit 1; }

# Reproduce production ownership: SSH-created runtime directories are mode 0700
# and owned by the deploy UID, not by the cleaner container. Minimal DAC/FOWNER
# capabilities must delete expired material while retaining recovery markers.
ownership_root=/tmp/postgres-brio-cleaner-test-production-ownership
[[ ! -e "${ownership_root}" && ! -L "${ownership_root}" ]] || find "${ownership_root}" -depth -delete
install -d -m 0700 "${ownership_root}"
cleaner_image=$(awk -F= '$1 == "POSTGRES_IMAGE" { print $2 }' "${repo_root}/envs/canary/.env.db")
docker run --rm --mount "type=bind,src=${ownership_root},dst=/fixture" "${cleaner_image}" sh -euc '
  mkdir /fixture/postgres-brio-deploy-owned /fixture/postgres-brio-recovery-owned
  printf "%s\n" secret > /fixture/postgres-brio-deploy-owned/credential
  printf "%s\n" recovery > /fixture/postgres-brio-recovery-owned/RECOVERY_REQUIRED
  chown -R 12345:12345 /fixture/postgres-brio-deploy-owned /fixture/postgres-brio-recovery-owned
  chmod 0700 /fixture/postgres-brio-deploy-owned /fixture/postgres-brio-recovery-owned
  touch -t 202001010000 /fixture/postgres-brio-deploy-owned /fixture/postgres-brio-recovery-owned
'
"${script_dir}/ensure-brio-tmp-cleaner.sh" test-clean-production-ownership "${ownership_root}" "${cleaner_image}"
[[ ! -e "${ownership_root}/postgres-brio-deploy-owned" ]] || { echo "Production cleaner retained a deploy-UID-owned expired secret directory." >&2; exit 1; }
[[ -f "${ownership_root}/postgres-brio-recovery-owned/RECOVERY_REQUIRED" ]] || { echo "Production cleaner removed recovery evidence." >&2; exit 1; }
docker run --rm --mount "type=bind,src=${ownership_root},dst=/fixture" "${cleaner_image}" sh -euc 'find /fixture -mindepth 1 -depth -delete'

echo "Brio deployment ordering, rollback, interruption, secret, and TTL contracts passed."
