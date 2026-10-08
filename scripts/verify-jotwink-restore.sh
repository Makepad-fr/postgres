#!/usr/bin/env bash
set -euo pipefail

backup_dir=${1:?Usage: verify-jotwink-restore.sh <backup-directory>}
: "${PGSERVICEFILE:?PGSERVICEFILE must identify a root-owned libpq service file}"
: "${JOTWINK_RESTORE_SERVICE:?JOTWINK_RESTORE_SERVICE must name an empty non-production database}"
: "${KEYCLOAK_JOTWINK_RESTORE_SERVICE:?KEYCLOAK_JOTWINK_RESTORE_SERVICE must name an empty non-production database}"
: "${JOTWINK_RESTORE_CONFIRM:?set JOTWINK_RESTORE_CONFIRM=replace-nonproduction-restore-targets}"
: "${JOTWINK_BACKUP_DECRYPTION_CERT:?JOTWINK_BACKUP_DECRYPTION_CERT must identify the recipient certificate}"
: "${JOTWINK_BACKUP_DECRYPTION_KEY:?JOTWINK_BACKUP_DECRYPTION_KEY must identify the offline private key}"

[[ "${JOTWINK_RESTORE_CONFIRM}" == replace-nonproduction-restore-targets ]] || { echo "Restore requires explicit non-production confirmation." >&2; exit 1; }
for path in "${PGSERVICEFILE}" "${JOTWINK_BACKUP_DECRYPTION_CERT}" "${JOTWINK_BACKUP_DECRYPTION_KEY}"; do
  [[ -f "${path}" && ! -L "${path}" ]] || { echo "Restore input must be a regular non-symlink file: ${path}" >&2; exit 1; }
done
[[ -d "${backup_dir}" && ! -L "${backup_dir}" ]] || { echo "Backup directory is invalid." >&2; exit 1; }
for required in jotwink.dump.cms keycloak_jotwink.dump.cms SHA256SUMS metadata.json; do [[ -s "${backup_dir}/${required}" ]] || exit 1; done
(cd "${backup_dir}" && sha256sum --check SHA256SUMS)

# Validate both actual destinations before decrypting or restoring either dump.
# Service names are identifiers, never arbitrary libpq connection strings.
for service in "$JOTWINK_RESTORE_SERVICE" "$KEYCLOAK_JOTWINK_RESTORE_SERVICE"; do
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
verify_target "$JOTWINK_RESTORE_SERVICE" jotwink_restore_test
verify_target "$KEYCLOAK_JOTWINK_RESTORE_SERVICE" keycloak_jotwink_restore_test

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/jotwink-restore.XXXXXX")
cleanup() { find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true; rmdir "${work_dir}" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

for database in jotwink keycloak_jotwink; do
  openssl cms -decrypt -binary -inform DER -in "${backup_dir}/${database}.dump.cms" \
    -recip "${JOTWINK_BACKUP_DECRYPTION_CERT}" -inkey "${JOTWINK_BACKUP_DECRYPTION_KEY}" \
    -out "${work_dir}/${database}.dump"
  pg_restore --list "${work_dir}/${database}.dump" >/dev/null
done

pg_restore --dbname="service=${JOTWINK_RESTORE_SERVICE} sslmode=verify-full" --no-owner --no-acl --exit-on-error --single-transaction "${work_dir}/jotwink.dump"
pg_restore --dbname="service=${KEYCLOAK_JOTWINK_RESTORE_SERVICE} sslmode=verify-full" --no-owner --no-acl --exit-on-error --single-transaction "${work_dir}/keycloak_jotwink.dump"

[[ $(psql "service=${JOTWINK_RESTORE_SERVICE} sslmode=verify-full" -X -v ON_ERROR_STOP=1 -Atc "SELECT to_regclass('public.schema_migrations') IS NOT NULL;") == t ]]
[[ $(psql "service=${KEYCLOAK_JOTWINK_RESTORE_SERVICE} sslmode=verify-full" -X -v ON_ERROR_STOP=1 -Atc "SELECT to_regclass('public.realm') IS NOT NULL;") == t ]]
echo "Jotwink and Keycloak restore verification completed against non-production targets."
