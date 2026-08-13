#!/usr/bin/env bash
set -euo pipefail

backup_dir=${1:?Usage: verify-jotwink-restore.sh <backup-directory>}
: "${PGSERVICEFILE:?PGSERVICEFILE must identify a root-owned libpq service file}"
: "${JOTWINK_RESTORE_SERVICE:?JOTWINK_RESTORE_SERVICE must name an empty non-production database}"
: "${KEYCLOAK_JOTWINK_RESTORE_SERVICE:?KEYCLOAK_JOTWINK_RESTORE_SERVICE must name an empty non-production database}"
: "${JOTWINK_RESTORE_CONFIRM:?set JOTWINK_RESTORE_CONFIRM=replace-nonproduction-restore-targets}"
: "${JOTWINK_BACKUP_DECRYPTION_CERT:?JOTWINK_BACKUP_DECRYPTION_CERT must identify the recipient certificate}"
: "${JOTWINK_BACKUP_DECRYPTION_KEY:?JOTWINK_BACKUP_DECRYPTION_KEY must identify the offline private key}"

[[ "${JOTWINK_RESTORE_CONFIRM}" == "replace-nonproduction-restore-targets" ]] || { echo "Restore verification requires explicit non-production replacement confirmation." >&2; exit 1; }
[[ -f "${PGSERVICEFILE}" && ! -L "${PGSERVICEFILE}" ]] || { echo "PGSERVICEFILE must be a regular, non-symlink file." >&2; exit 1; }
[[ -d "${backup_dir}" && ! -L "${backup_dir}" ]] || { echo "Backup directory must be a regular directory and not a symlink." >&2; exit 1; }
[[ -f "${JOTWINK_BACKUP_DECRYPTION_CERT}" && ! -L "${JOTWINK_BACKUP_DECRYPTION_CERT}" ]] || { echo "Backup recipient certificate must be a regular, non-symlink file." >&2; exit 1; }
[[ -f "${JOTWINK_BACKUP_DECRYPTION_KEY}" && ! -L "${JOTWINK_BACKUP_DECRYPTION_KEY}" ]] || { echo "Backup private key must be a regular, non-symlink file." >&2; exit 1; }

for required in jotwink.dump.cms keycloak_jotwink.dump.cms SHA256SUMS metadata.json; do
  [[ -s "${backup_dir}/${required}" ]] || { echo "Backup artifact is missing or empty: ${required}" >&2; exit 1; }
done
(cd "${backup_dir}" && sha256sum --check SHA256SUMS)

work_dir=$(mktemp -d)
cleanup() {
  find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true
  rmdir "${work_dir}" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

for database in jotwink keycloak_jotwink; do
  openssl cms \
    -decrypt \
    -binary \
    -inform DER \
    -in "${backup_dir}/${database}.dump.cms" \
    -recip "${JOTWINK_BACKUP_DECRYPTION_CERT}" \
    -inkey "${JOTWINK_BACKUP_DECRYPTION_KEY}" \
    -out "${work_dir}/${database}.dump"
  pg_restore --list "${work_dir}/${database}.dump" >/dev/null
done

restore_dump() {
  pg_restore \
    --dbname="service=$1" \
    --clean \
    --if-exists \
    --no-owner \
    --no-acl \
    --exit-on-error \
    --single-transaction \
    "$2"
}

restore_dump "${JOTWINK_RESTORE_SERVICE}" "${work_dir}/jotwink.dump"
restore_dump "${KEYCLOAK_JOTWINK_RESTORE_SERVICE}" "${work_dir}/keycloak_jotwink.dump"

jotwink_schema=$(psql "service=${JOTWINK_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('public.schema_migrations') IS NOT NULL;")
keycloak_schema=$(psql "service=${KEYCLOAK_JOTWINK_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('public.realm') IS NOT NULL;")
if [[ "${jotwink_schema}" != "t" || "${keycloak_schema}" != "t" ]]; then
  echo "Restored databases are missing the Jotwink or Keycloak durable schema." >&2
  exit 1
fi

echo "Jotwink and Keycloak restore verification completed against non-production targets."
