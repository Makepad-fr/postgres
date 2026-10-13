#!/usr/bin/env bash
set -euo pipefail

backup_dir=${1:?Usage: verify-runtrace-restore.sh <backup-directory>}
: "${PGSERVICEFILE:?PGSERVICEFILE must identify a root-owned libpq service file}"
: "${RUNTRACE_RESTORE_SERVICE:?RUNTRACE_RESTORE_SERVICE must name an empty non-production database}"
: "${KEYCLOAK_RUNTRACE_RESTORE_SERVICE:?KEYCLOAK_RUNTRACE_RESTORE_SERVICE must name an empty non-production database}"
: "${RUNTRACE_RESTORE_CONFIRM:?set RUNTRACE_RESTORE_CONFIRM=replace-nonproduction-restore-targets}"

if [[ "${RUNTRACE_RESTORE_CONFIRM}" != "replace-nonproduction-restore-targets" ]]; then
  echo "Restore verification requires explicit non-production replacement confirmation." >&2
  exit 1
fi
if [[ ! -f "${PGSERVICEFILE}" || -L "${PGSERVICEFILE}" ]]; then
  echo "PGSERVICEFILE must be a regular, non-symlink file." >&2
  exit 1
fi
if [[ ! -d "${backup_dir}" || -L "${backup_dir}" ]]; then
  echo "Backup directory must be a regular directory and not a symlink." >&2
  exit 1
fi

for required in runtrace.dump keycloak_runtrace.dump SHA256SUMS metadata.json; do
  if [[ ! -s "${backup_dir}/${required}" ]]; then
    echo "Backup artifact is missing or empty: ${required}" >&2
    exit 1
  fi
done
(
  cd "${backup_dir}"
  sha256sum --check SHA256SUMS
)

restore_dump() {
  local service=$1
  local dump=$2
  pg_restore \
    --dbname="service=${service}" \
    --clean \
    --if-exists \
    --no-owner \
    --no-acl \
    --exit-on-error \
    --single-transaction \
    "${dump}"
}

restore_dump "${RUNTRACE_RESTORE_SERVICE}" "${backup_dir}/runtrace.dump"
restore_dump "${KEYCLOAK_RUNTRACE_RESTORE_SERVICE}" "${backup_dir}/keycloak_runtrace.dump"

runtrace_table=$(psql "service=${RUNTRACE_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('public.runtrace_state') IS NOT NULL;")
keycloak_table=$(psql "service=${KEYCLOAK_RUNTRACE_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('public.realm') IS NOT NULL;")
if [[ "${runtrace_table}" != "t" || "${keycloak_table}" != "t" ]]; then
  echo "Restored databases are missing the Runtrace or Keycloak durable state tables." >&2
  exit 1
fi

echo "Runtrace and Keycloak restore verification completed against non-production targets."
