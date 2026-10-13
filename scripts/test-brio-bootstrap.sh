#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
postgres_image=$(awk -F= '$1 == "POSTGRES_IMAGE" {print $2}' "${repo_root}/envs/canary/.env.db")
container_name="brio-postgres-bootstrap-${RANDOM}-$$"
postgres_password='brio-bootstrap-integration-only'
brio_app_password='brio-app-integration-only'
brio_backup_password='brio-app-backup-integration-only'
keycloak_app_password='brio-keycloak-integration-only'
keycloak_backup_password='brio-keycloak-backup-integration-only'

cleanup() {
  local status=$?
  trap - EXIT
  if ((status != 0)); then
    echo "Brio bootstrap test failed; PostgreSQL container state and logs follow." >&2
    docker inspect "${container_name}" \
      --format 'status={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' >&2 2>/dev/null || true
    docker logs --tail 200 "${container_name}" >&2 2>/dev/null || true
  fi
  docker rm -f "${container_name}" >/dev/null 2>&1 || true
  exit "${status}"
}
trap cleanup EXIT

docker run -d --name "${container_name}" \
  -e POSTGRES_PASSWORD="${postgres_password}" \
  -v "${repo_root}/bootstrap:/bootstrap:ro" \
  "${postgres_image}" >/dev/null

postgres_ready=false
for _ in $(seq 1 300); do
  if docker exec "${container_name}" pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1; then
    postgres_ready=true
    break
  fi
  if [[ "$(docker inspect "${container_name}" --format '{{.State.Running}}' 2>/dev/null || true)" != "true" ]]; then
    echo "PostgreSQL container exited before TCP readiness." >&2
    exit 1
  fi
  sleep 0.1
done
if [[ "${postgres_ready}" != "true" ]]; then
  echo "PostgreSQL did not become ready on TCP loopback within 30 seconds." >&2
  exit 1
fi
docker exec "${container_name}" pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null

if docker exec -e PGPASSWORD="${postgres_password}" "${container_name}" \
  psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -v brio_staging_app_password="${brio_app_password}" \
    -f /bootstrap/brio-staging-app.sql >/dev/null 2>&1; then
  echo "Brio application bootstrap unexpectedly accepted a missing backup-role password." >&2
  exit 1
fi
if docker exec -e PGPASSWORD="${postgres_password}" "${container_name}" \
  psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -v keycloak_brio_staging_app_password="${keycloak_app_password}" \
    -v keycloak_brio_staging_backup_password='' \
    -f /bootstrap/keycloak-brio-staging.sql >/dev/null 2>&1; then
  echo "Brio Keycloak bootstrap unexpectedly accepted an empty backup-role password." >&2
  exit 1
fi

if docker exec -e PGPASSWORD="${postgres_password}" "${container_name}" \
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d postgres \
    -v brio_staging_app_password="${brio_app_password}" \
    -v brio_staging_backup_password="${brio_backup_password}" \
    -f /bootstrap/brio-staging-app.sql >/dev/null 2>&1; then
  echo "Brio application bootstrap unexpectedly accepted a remote plaintext administrator session." >&2
  exit 1
fi
if docker exec -e PGPASSWORD="${postgres_password}" "${container_name}" \
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d postgres \
    -v keycloak_brio_staging_app_password="${keycloak_app_password}" \
    -v keycloak_brio_staging_backup_password="${keycloak_backup_password}" \
    -f /bootstrap/keycloak-brio-staging.sql >/dev/null 2>&1; then
  echo "Brio Keycloak bootstrap unexpectedly accepted a remote plaintext administrator session." >&2
  exit 1
fi

run_keycloak_brio_bootstrap() {
  docker exec -e PGPASSWORD="${postgres_password}" "${container_name}" \
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
      -v keycloak_brio_staging_app_password="${keycloak_app_password}" \
      -v keycloak_brio_staging_backup_password="${keycloak_backup_password}" \
      -f /bootstrap/keycloak-brio-staging.sql >/dev/null
}

run_brio_bootstrap() {
  docker exec -e PGPASSWORD="${postgres_password}" "${container_name}" \
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
      -v brio_staging_app_password="${brio_app_password}" \
      -v brio_staging_backup_password="${brio_backup_password}" \
      -f /bootstrap/brio-staging-app.sql >/dev/null
}

# Both bootstraps are explicitly idempotent.
run_keycloak_brio_bootstrap
run_brio_bootstrap
run_keycloak_brio_bootstrap
run_brio_bootstrap

role_contract=$(docker exec -e PGPASSWORD="${postgres_password}" "${container_name}" \
  psql -At -U postgres -d postgres -c \
    "SELECT count(*) FROM pg_roles WHERE rolname IN ('brio_staging_app','brio_staging_backup','keycloak_brio_staging_app','keycloak_brio_staging_backup') AND rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls")
[[ "${role_contract}" == "4" ]]

owner_contract=$(docker exec -e PGPASSWORD="${postgres_password}" "${container_name}" \
  psql -At -U postgres -d postgres -c \
    "SELECT count(*) FROM pg_database d JOIN pg_roles r ON r.oid=d.datdba WHERE (d.datname='brio_staging' AND r.rolname='brio_staging_app') OR (d.datname='keycloak_brio_staging' AND r.rolname='keycloak_brio_staging_app')")
[[ "${owner_contract}" == "2" ]]

public_connect=$(docker exec -e PGPASSWORD="${postgres_password}" "${container_name}" \
  psql -At -U postgres -d postgres -c \
    "SELECT count(*) FROM pg_database d, LATERAL aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a WHERE d.datname IN ('brio_staging','keycloak_brio_staging') AND a.grantee=0 AND a.privilege_type='CONNECT'")
[[ "${public_connect}" == "0" ]]

assert_backup_role() {
  local database=$1
  local app_user=$2
  local app_password=$3
  local backup_user=$4
  local backup_password=$5
  local other_database=$6

  docker exec -e PGPASSWORD="${app_password}" "${container_name}" \
    psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "${app_user}" -d "${database}" \
      -c "CREATE TABLE IF NOT EXISTS public.backup_role_probe (marker text NOT NULL)" \
      -c "TRUNCATE public.backup_role_probe" \
      -c "INSERT INTO public.backup_role_probe(marker) VALUES ('readable')" >/dev/null

  read_only=$(docker exec -e PGPASSWORD="${backup_password}" "${container_name}" \
    psql -At -h 127.0.0.1 -U "${backup_user}" -d "${database}" \
      -c "SHOW default_transaction_read_only")
  [[ "${read_only}" == "on" ]]

  readable=$(docker exec -e PGPASSWORD="${backup_password}" "${container_name}" \
    psql -At -h 127.0.0.1 -U "${backup_user}" -d "${database}" \
      -c "SELECT marker FROM public.backup_role_probe")
  [[ "${readable}" == "readable" ]]

  if docker exec -e PGPASSWORD="${backup_password}" "${container_name}" \
    psql -h 127.0.0.1 -U "${backup_user}" -d "${database}" \
      -c "INSERT INTO public.backup_role_probe(marker) VALUES ('forbidden')" >/dev/null 2>&1; then
    echo "Backup role ${backup_user} unexpectedly wrote to ${database}." >&2
    exit 1
  fi

  docker exec -e PGPASSWORD="${backup_password}" "${container_name}" \
    pg_dump -h 127.0.0.1 -U "${backup_user}" -d "${database}" --format=custom >/dev/null

  if docker exec -e PGPASSWORD="${backup_password}" "${container_name}" \
    psql -h 127.0.0.1 -U "${backup_user}" -d "${other_database}" -c "SELECT 1" >/dev/null 2>&1; then
    echo "Backup role ${backup_user} unexpectedly connected to ${other_database}." >&2
    exit 1
  fi
}

assert_backup_role \
  brio_staging brio_staging_app "${brio_app_password}" \
  brio_staging_backup "${brio_backup_password}" keycloak_brio_staging
assert_backup_role \
  keycloak_brio_staging keycloak_brio_staging_app "${keycloak_app_password}" \
  keycloak_brio_staging_backup "${keycloak_backup_password}" brio_staging

echo "Brio PostgreSQL app and read-only backup role, database, privilege, and idempotency tests passed"
