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

work_dir=$(mktemp -d)
cleanup() { find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true; rmdir "${work_dir}" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

for database in betacrew keycloak_betacrew; do
  openssl cms -decrypt -binary -inform DER -in "${backup_dir}/${database}.dump.cms" \
    -recip "${BETACREW_BACKUP_DECRYPTION_CERT}" -inkey "${BETACREW_BACKUP_DECRYPTION_KEY}" \
    -out "${work_dir}/${database}.dump"
  pg_restore --list "${work_dir}/${database}.dump" >/dev/null
done

pg_restore --dbname="service=${BETACREW_RESTORE_SERVICE}" --clean --if-exists --no-owner --no-acl --exit-on-error --single-transaction "${work_dir}/betacrew.dump"
pg_restore --dbname="service=${KEYCLOAK_BETACREW_RESTORE_SERVICE}" --clean --if-exists --no-owner --no-acl --exit-on-error --single-transaction "${work_dir}/keycloak_betacrew.dump"

[[ $(psql "service=${BETACREW_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc "SELECT to_regclass('public.schema_migrations') IS NOT NULL;") == t ]]
[[ $(psql "service=${KEYCLOAK_BETACREW_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc "SELECT to_regclass('public.realm') IS NOT NULL;") == t ]]
echo "BetaCrew and Keycloak restore verification completed against non-production targets."
