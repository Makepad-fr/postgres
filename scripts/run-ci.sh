#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${repo_root}"

./scripts/validate-postgres-config.sh
shellcheck \
  scripts/run-brio-encrypted-backup.sh \
  scripts/run-brio-encrypted-backup-loop.sh \
  scripts/deploy-brio-canary-postgres.sh \
  scripts/deploy-brio-identity-db-host.sh \
  scripts/deploy-postgres-stack.sh \
  scripts/brio-db-transaction.sh \
  scripts/ensure-brio-tmp-cleaner.sh \
  scripts/clean-keycloak-cohort-resources.sh \
  scripts/install-keycloak-cohort-cleaner.sh \
  scripts/keycloak-cohort-capture-dispatch.sh \
  scripts/install-keycloak-cohort-capture-host.sh \
  scripts/verify-brio-encrypted-restore.sh \
  scripts/test-brio-bootstrap.sh \
  scripts/test-brio-db-transaction.sh \
  scripts/test-brio-encrypted-backup.sh \
  scripts/test-brio-encrypted-restore.sh \
  scripts/test-brio-deploy-guards.sh \
  scripts/test-brio-deployment-contracts.sh \
  scripts/test-brio-deployment-failures.sh \
  scripts/test-brio-release-evidence.sh \
  scripts/test-keycloak-cohort-evidence.sh \
  scripts/test-keycloak-cohort-hardening.sh \
  scripts/test-postgres-ci-jit-result.sh \
  scripts/capture-keycloak-cohort-backups.sh \
  scripts/restore-keycloak-cohort-backups.sh \
  scripts/run-postgres-ci-jit-vm.sh \
  scripts/run-postgres-ci-queue-controller.sh \
  scripts/configure-postgres-ci-runner-group.sh \
  scripts/sync-github-environments.sh \
  scripts/test-sync-github-environments.sh \
  scripts/fixtures/brio-deployment-failure-fixture.sh \
  scripts/fixtures/keycloak-cohort-cleaner-fixture.sh \
  scripts/fixtures/keycloak-cohort-dispatch-fixture.sh
python3 - <<'PY'
import ast
from pathlib import Path

for source in (
    "scripts/verify-brio-release-evidence.py",
    "scripts/verify-keycloak-cohort-evidence.py",
    "scripts/ci-base-image.py",
    "scripts/verify-postgres-ci-jit-result.py",
    "scripts/reconcile-github-environment-main-policy.py",
    "scripts/test-github-environment-main-policy.py",
    "scripts/validate-credential-inventory-contract.py",
    "scripts/validate-github-provider-contract.py",
    "scripts/validate-repository-trust-anchor.py",
):
    ast.parse(Path(source).read_text(), filename=source)
PY
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-github-environment-main-policy.py
./scripts/test-sync-github-environments.sh
node --check scripts/publish-pr-ci-check.mjs
node --check scripts/postgres-ci-queue-controller.mjs
node --check scripts/dispatch-ci-attestation.mjs
node --test scripts/test-pr-ci-check.mjs scripts/test-postgres-ci-queue-controller.mjs
./scripts/test-postgres-ci-jit-result.sh
actionlint
git show --check --format= HEAD
git diff --check
./scripts/test-brio-deploy-guards.sh
./scripts/test-brio-deployment-contracts.sh
./scripts/test-brio-deployment-failures.sh
./scripts/test-brio-release-evidence.sh
./scripts/test-keycloak-cohort-evidence.sh
./scripts/test-keycloak-cohort-hardening.sh
./scripts/test-brio-bootstrap.sh
./scripts/test-brio-db-transaction.sh
./scripts/test-brio-encrypted-backup.sh
./scripts/test-brio-encrypted-restore.sh
backup_image=$(grep '^BRIO_BACKUP_IMAGE=' envs/canary/.env.db | cut -d= -f2-)
docker run --rm --volume "${PWD}:/repo:ro" --workdir /repo "${backup_image}" bash scripts/test-brio-encrypted-backup.sh
docker run --rm --volume "${PWD}:/repo:ro" --workdir /repo "${backup_image}" bash scripts/test-brio-encrypted-restore.sh
