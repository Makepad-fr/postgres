#!/usr/bin/env bash
set -euo pipefail

backup_dir=${1:?Usage: verify-betacrew-restore.sh <backup-directory>}
: "${PGSERVICEFILE:?PGSERVICEFILE must identify a root-owned libpq service file}"
: "${BETACREW_RESTORE_SERVICE:?BETACREW_RESTORE_SERVICE must name an empty non-production database}"
: "${KEYCLOAK_BETACREW_RESTORE_SERVICE:?KEYCLOAK_BETACREW_RESTORE_SERVICE must name an empty non-production database}"
: "${BETACREW_RESTORE_CONFIRM:?set BETACREW_RESTORE_CONFIRM=replace-nonproduction-restore-targets}"
: "${BETACREW_BACKUP_DECRYPTION_CERT:?BETACREW_BACKUP_DECRYPTION_CERT must identify the recipient certificate}"
: "${BETACREW_BACKUP_DECRYPTION_KEY:?BETACREW_BACKUP_DECRYPTION_KEY must identify the offline private key}"

[[ "${BETACREW_RESTORE_CONFIRM}" == replace-nonproduction-restore-targets ]] || { echo "Restore requires explicit non-production confirmation." >&2; exit 1; }
for path in "${PGSERVICEFILE}" "${BETACREW_BACKUP_DECRYPTION_CERT}" "${BETACREW_BACKUP_DECRYPTION_KEY}"; do
  [[ -f "${path}" && ! -L "${path}" ]] || { echo "Restore input must be a regular non-symlink file: ${path}" >&2; exit 1; }
done
[[ -d "${backup_dir}" && ! -L "${backup_dir}" ]] || { echo "Backup directory is invalid." >&2; exit 1; }
for required in betacrew.dump.cms keycloak_betacrew.dump.cms SHA256SUMS metadata.json; do [[ -s "${backup_dir}/${required}" ]] || exit 1; done
(cd "${backup_dir}" && sha256sum --check SHA256SUMS)

# Validate both actual destinations before decrypting or restoring either dump.
# Service names are identifiers, never arbitrary libpq connection strings.
for service in "$BETACREW_RESTORE_SERVICE" "$KEYCLOAK_BETACREW_RESTORE_SERVICE"; do
  [[ "$service" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid restore service identifier." >&2; exit 1; }
done
verify_target() {
  local service=$1 expected=$2 result
  result=$(psql "service=$service sslmode=verify-full" -X -v ON_ERROR_STOP=1 -At \
    -v expected_database="$expected" <<'SQL'
SELECT current_database() = :'expected_database'
  AND NOT EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND n.nspname NOT LIKE 'pg_toast%'
      AND c.relkind IN ('r','p','v','m','S','f')
  );
SQL
  )
  [[ "$result" == t ]] || { echo "Restore target must be the named empty disposable database." >&2; exit 1; }
}
verify_target "$BETACREW_RESTORE_SERVICE" betacrew_restore_test
verify_target "$KEYCLOAK_BETACREW_RESTORE_SERVICE" keycloak_betacrew_restore_test

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/betacrew-restore.XXXXXX")
cleanup() { find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true; rmdir "${work_dir}" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

for database in betacrew keycloak_betacrew; do
  openssl cms -decrypt -binary -inform DER -in "${backup_dir}/${database}.dump.cms" \
    -recip "${BETACREW_BACKUP_DECRYPTION_CERT}" -inkey "${BETACREW_BACKUP_DECRYPTION_KEY}" \
    -out "${work_dir}/${database}.dump"
  pg_restore --list "${work_dir}/${database}.dump" >/dev/null
done

pg_restore --dbname="service=${BETACREW_RESTORE_SERVICE} sslmode=verify-full" --no-owner --no-acl --exit-on-error --single-transaction "${work_dir}/betacrew.dump"
pg_restore --dbname="service=${KEYCLOAK_BETACREW_RESTORE_SERVICE} sslmode=verify-full" --no-owner --no-acl --exit-on-error --single-transaction "${work_dir}/keycloak_betacrew.dump"

[[ $(psql "service=${BETACREW_RESTORE_SERVICE} sslmode=verify-full" -X -v ON_ERROR_STOP=1 -Atc "SELECT to_regclass('public.schema_migrations') IS NOT NULL;") == t ]]
[[ $(psql "service=${KEYCLOAK_BETACREW_RESTORE_SERVICE} sslmode=verify-full" -X -v ON_ERROR_STOP=1 -Atc "SELECT to_regclass('public.realm') IS NOT NULL;") == t ]]
echo "BetaCrew and Keycloak restore verification completed against non-production targets."
