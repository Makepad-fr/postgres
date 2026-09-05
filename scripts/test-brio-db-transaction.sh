#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
postgres_image=$(awk -F= '$1 == "POSTGRES_IMAGE" { print $2 }' "${repo_root}/envs/canary/.env.db")
container="brio-db-transaction-${RANDOM}-$$"
superuser_password='transaction-superuser-only'
old_app_password='transaction-old-app-only'
old_backup_password='transaction-old-backup-only'
new_app_password='transaction-new-app-only'
new_backup_password='transaction-new-backup-only'

cleanup() {
  local status=$?
  trap - EXIT
  docker rm -f "${container}" >/dev/null 2>&1 || true
  exit "${status}"
}
trap cleanup EXIT

docker run -d --name "${container}" \
  -e "POSTGRES_PASSWORD=${superuser_password}" \
  -e POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 \
  --mount "type=bind,src=${repo_root}/bootstrap,dst=/bootstrap,readonly" \
  --mount "type=bind,src=${repo_root}/scripts/brio-db-transaction.sh,dst=/usr/local/bin/brio-db-transaction.sh,readonly" \
  "${postgres_image}" >/dev/null
for _ in $(seq 1 300); do
  docker exec -e "PGPASSWORD=${superuser_password}" "${container}" \
    psql -X -h 127.0.0.1 -U postgres -d postgres -c 'select 1' >/dev/null 2>&1 && break
  sleep 0.1
done
docker exec -e "PGPASSWORD=${superuser_password}" "${container}" \
  psql -X -h 127.0.0.1 -U postgres -d postgres -c 'select 1' >/dev/null
docker exec "${container}" sh -euc 'install -d -m 0700 /journal/keycloak /journal/brio; printf "%s" "$1" > /run/superuser-password; chmod 0600 /run/superuser-password' sh "${superuser_password}"

psql_admin() {
  docker exec -e "PGPASSWORD=${superuser_password}" "${container}" psql -X -v ON_ERROR_STOP=1 -U postgres "$@"
}
transaction() {
  docker exec \
    -e PGUSER=postgres -e PGHOST=127.0.0.1 -e PGSSLMODE=disable -e PGPASSWORD_FILE=/run/superuser-password \
    "${container}" /usr/local/bin/brio-db-transaction.sh "$@"
}

psql_admin -d postgres \
  -c "CREATE ROLE brio_legacy_owner NOLOGIN" \
  -c "CREATE ROLE keycloak_brio_staging_app LOGIN NOINHERIT CONNECTION LIMIT 7 PASSWORD '${old_app_password}' VALID UNTIL '2035-01-02 03:04:05+00'" \
  -c "CREATE ROLE keycloak_brio_staging_backup LOGIN INHERIT CONNECTION LIMIT 3 PASSWORD '${old_backup_password}'" \
  -c "ALTER ROLE keycloak_brio_staging_app SET statement_timeout TO '17s'" \
  -c "CREATE DATABASE keycloak_brio_staging OWNER brio_legacy_owner" \
  -c "REVOKE CONNECT ON DATABASE keycloak_brio_staging FROM PUBLIC" \
  -c "GRANT CONNECT ON DATABASE keycloak_brio_staging TO keycloak_brio_staging_app" \
  -c "GRANT CREATE ON DATABASE keycloak_brio_staging TO keycloak_brio_staging_backup WITH GRANT OPTION" \
  -c "ALTER ROLE keycloak_brio_staging_backup IN DATABASE keycloak_brio_staging SET lock_timeout TO '19s'" >/dev/null
psql_admin -d keycloak_brio_staging \
  -c "REVOKE ALL ON SCHEMA public FROM PUBLIC" \
  -c "GRANT CREATE ON SCHEMA public TO keycloak_brio_staging_backup WITH GRANT OPTION" \
  -c "CREATE TABLE public.preexisting_acl_probe(id integer)" \
  -c "GRANT UPDATE ON public.preexisting_acl_probe TO keycloak_brio_staging_backup WITH GRANT OPTION" \
  -c "ALTER DEFAULT PRIVILEGES FOR ROLE keycloak_brio_staging_app IN SCHEMA public GRANT INSERT ON TABLES TO keycloak_brio_staging_backup WITH GRANT OPTION" >/dev/null

transaction prepare keycloak /journal/keycloak
pre_fingerprint=$(transaction fingerprint keycloak /journal/keycloak | sha256sum | cut -d' ' -f1)
psql_admin -d postgres \
  -v "keycloak_brio_staging_app_password=${new_app_password}" \
  -v "keycloak_brio_staging_backup_password=${new_backup_password}" \
  -f /bootstrap/keycloak-brio-staging.sql >/dev/null
docker exec -e "PGPASSWORD=${new_app_password}" "${container}" \
  psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U keycloak_brio_staging_app -d keycloak_brio_staging -c 'select 1' >/dev/null
docker exec -e "PGPASSWORD=${new_backup_password}" "${container}" \
  psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U keycloak_brio_staging_backup -d postgres -c 'select 1' >/dev/null
if docker exec -e "PGPASSWORD=${old_app_password}" "${container}" \
  psql -X -h 127.0.0.1 -U keycloak_brio_staging_app -d keycloak_brio_staging -c 'select 1' >/dev/null 2>&1; then
  echo "Old application credential unexpectedly survived the simulated mutation." >&2
  exit 1
fi
if docker exec -e "PGPASSWORD=${old_backup_password}" "${container}" \
  psql -X -h 127.0.0.1 -U keycloak_brio_staging_backup -d postgres -c 'select 1' >/dev/null 2>&1; then
  echo "Old backup credential unexpectedly survived the simulated mutation." >&2
  exit 1
fi
transaction restore keycloak /journal/keycloak
post_fingerprint=$(transaction fingerprint keycloak /journal/keycloak | sha256sum | cut -d' ' -f1)
[[ "${post_fingerprint}" == "${pre_fingerprint}" ]] || { echo "Exact Keycloak Brio state fingerprint was not restored." >&2; exit 1; }
docker exec -e "PGPASSWORD=${old_app_password}" "${container}" \
  psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U keycloak_brio_staging_app -d keycloak_brio_staging -c 'select 1' >/dev/null
docker exec -e "PGPASSWORD=${old_backup_password}" "${container}" \
  psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U keycloak_brio_staging_backup -d postgres -c 'select 1' >/dev/null
if docker exec -e "PGPASSWORD=${new_app_password}" "${container}" \
  psql -X -h 127.0.0.1 -U keycloak_brio_staging_app -d keycloak_brio_staging -c 'select 1' >/dev/null 2>&1; then
  echo "New application credential remained valid after compensation." >&2
  exit 1
fi
if docker exec -e "PGPASSWORD=${new_backup_password}" "${container}" \
  psql -X -h 127.0.0.1 -U keycloak_brio_staging_backup -d postgres -c 'select 1' >/dev/null 2>&1; then
  echo "New backup credential remained valid after compensation." >&2
  exit 1
fi

# The absent-state path must remove every object introduced by a failed first
# deployment, not merely rotate credentials back.
transaction prepare brio /journal/brio
psql_admin -d postgres \
  -v "brio_staging_app_password=${new_app_password}" \
  -v "brio_staging_backup_password=${new_backup_password}" \
  -f /bootstrap/brio-staging-app.sql >/dev/null
transaction restore brio /journal/brio
[[ $(psql_admin -At -d postgres -c "SELECT count(*) FROM pg_database WHERE datname='brio_staging'") == 0 ]]
[[ $(psql_admin -At -d postgres -c "SELECT count(*) FROM pg_roles WHERE rolname IN ('brio_staging_app','brio_staging_backup')") == 0 ]]

# A recovery mismatch must fail closed without leaking the stored fingerprint.
# That fingerprint includes SCRAM verifiers and therefore must never appear in
# CI or remote deployment diagnostics.
docker exec "${container}" sh -euc 'printf "%s\n" sentinel-secret-verifier >> /journal/brio/prestate.fingerprint'
if mismatch_output=$(transaction restore brio /journal/brio 2>&1); then
  echo "A mismatched recovery fingerprint was unexpectedly accepted." >&2
  exit 1
fi
[[ "${mismatch_output}" == *"Database compensation did not restore the exact prior Brio state."* ]] || {
  echo "Recovery mismatch did not return the expected redacted diagnostic." >&2
  exit 1
}
[[ "${mismatch_output}" != *sentinel-secret-verifier* ]] || {
  echo "Recovery mismatch leaked protected fingerprint material." >&2
  exit 1
}
unset mismatch_output

echo "Brio database transaction journal restores roles, SCRAM verifiers, attributes, database ownership, ACLs, defaults, and absent state."
