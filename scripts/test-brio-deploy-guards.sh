#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

expect_refusal() {
  local expected=$1
  shift
  local output status
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  if [[ ${status} -eq 0 || "${output}" != *"${expected}"* ]]; then
    echo "Expected deployment guard refusal containing: ${expected}" >&2
    exit 1
  fi
}

expect_refusal "unique /srv or /opt" \
  "${script_dir}/deploy-brio-canary-postgres.sh" relative-dir brio /tmp/postgres-brio-canary-runtime-1-1

expect_refusal "exact standalone DB restart acknowledgement" \
  "${script_dir}/deploy-brio-identity-db-host.sh" /tmp/postgres-brio-identity-bundle-1-1 /tmp/postgres-brio-identity-runtime-1-1 65.21.134.125 88.99.209.165/32

expect_refusal "reviewed standalone DB IP" \
  env BRIO_IDENTITY_DB_DEPLOY_CONFIRM=restart-standalone-postgres-for-brio-staging \
    BRIO_IDENTITY_DB_BACKUP_RESTORE_CONFIRMED=yes \
    "${script_dir}/deploy-brio-identity-db-host.sh" /tmp/postgres-brio-identity-bundle-1-1 /tmp/postgres-brio-identity-runtime-1-1 127.0.0.1 88.99.209.165/32

expect_refusal "reviewed exact egress" \
  env BRIO_IDENTITY_DB_DEPLOY_CONFIRM=restart-standalone-postgres-for-brio-staging \
    BRIO_IDENTITY_DB_BACKUP_RESTORE_CONFIRMED=yes \
    "${script_dir}/deploy-brio-identity-db-host.sh" /tmp/postgres-brio-identity-bundle-1-1 /tmp/postgres-brio-identity-runtime-1-1 65.21.134.125 10.80.0.1/32

expect_refusal "unique /srv or /opt" \
  "${script_dir}/deploy-postgres-stack.sh" /srv/makepad/postgres postgres canary

expect_refusal "Production requires a job-scoped" \
  "${script_dir}/deploy-postgres-stack.sh" /srv/makepad/postgres/.deploy/postgres-1-1 postgres production

echo "Brio deployment guard tests passed."
