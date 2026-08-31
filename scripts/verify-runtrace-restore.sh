#!/usr/bin/env bash
set -euo pipefail

backup_dir=${1:?Usage: verify-runtrace-restore.sh <backup-directory>}
: "${PGSERVICEFILE:?PGSERVICEFILE must identify a root-owned libpq service file}"
: "${RUNTRACE_RESTORE_SERVICE:?RUNTRACE_RESTORE_SERVICE must name an empty non-production database}"
: "${KEYCLOAK_RUNTRACE_RESTORE_SERVICE:?KEYCLOAK_RUNTRACE_RESTORE_SERVICE must name an empty non-production database}"
: "${AMIARY_RESTORE_SERVICE:?AMIARY_RESTORE_SERVICE must name an empty non-production database}"
: "${AMIARY_CANARY_RESTORE_SERVICE:?AMIARY_CANARY_RESTORE_SERVICE must name an empty non-production database}"
: "${KEYCLOAK_AMIARY_RESTORE_SERVICE:?KEYCLOAK_AMIARY_RESTORE_SERVICE must name an empty non-production database}"
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

for required in runtrace.dump keycloak_runtrace.dump amiary.dump amiary_canary.dump keycloak_amiary.dump SHA256SUMS metadata.json; do
  if [[ ! -s "${backup_dir}/${required}" ]]; then
    echo "Backup artifact is missing or empty: ${required}" >&2
    exit 1
  fi
done
(
  cd "${backup_dir}"
  sha256sum -c SHA256SUMS
)

restore_dump() {
  local service=$1
  local dump=$2
  pg_restore \
    --dbname="service=${service}" \
    --clean \
    --if-exists \
    --exit-on-error \
    --single-transaction \
    "${dump}"
}

restore_dump "${RUNTRACE_RESTORE_SERVICE}" "${backup_dir}/runtrace.dump"
restore_dump "${KEYCLOAK_RUNTRACE_RESTORE_SERVICE}" "${backup_dir}/keycloak_runtrace.dump"
restore_dump "${AMIARY_RESTORE_SERVICE}" "${backup_dir}/amiary.dump"
restore_dump "${AMIARY_CANARY_RESTORE_SERVICE}" "${backup_dir}/amiary_canary.dump"
restore_dump "${KEYCLOAK_AMIARY_RESTORE_SERVICE}" "${backup_dir}/keycloak_amiary.dump"

runtrace_table=$(psql "service=${RUNTRACE_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('public.runtrace_state') IS NOT NULL;")
keycloak_table=$(psql "service=${KEYCLOAK_RUNTRACE_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('public.realm') IS NOT NULL;")
amiary_table=$(psql "service=${AMIARY_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('amiary.persons') IS NOT NULL;")
amiary_canary_table=$(psql "service=${AMIARY_CANARY_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('amiary.persons') IS NOT NULL;")
keycloak_amiary_table=$(psql "service=${KEYCLOAK_AMIARY_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('public.realm') IS NOT NULL;")
if [[ "${runtrace_table}" != "t" || "${keycloak_table}" != "t" || \
      "${amiary_table}" != "t" || "${amiary_canary_table}" != "t" || \
      "${keycloak_amiary_table}" != "t" ]]; then
  echo "Restored databases are missing required Runtrace, Amiary, or Keycloak durable tables." >&2
  exit 1
fi

amiary_security_contract=$(psql "service=${AMIARY_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc "
  SELECT count(*) = 0
  FROM (
    VALUES
      ('resolve_carddav_credential', 'amiary_security_definer', true),
      ('claim_graph_events', 'amiary_security_definer', true),
      ('finish_graph_event', 'amiary_security_definer', true),
      ('fetch_graph_projection', 'amiary_security_definer', true)
  ) expected(function_name, owner_name, security_definer)
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_proc function
    JOIN pg_namespace namespace ON namespace.oid = function.pronamespace
    JOIN pg_roles owner ON owner.oid = function.proowner
    WHERE namespace.nspname = 'amiary'
      AND function.proname = expected.function_name
      AND owner.rolname = expected.owner_name
      AND function.prosecdef = expected.security_definer
  );
  SELECT count(*) = 0
  FROM pg_class relation
  JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'amiary'
    AND relation.relkind IN ('r', 'p')
    AND NOT relation.relispartition
    AND (
      relation.relname = 'accounts'
      OR EXISTS (
        SELECT 1 FROM pg_attribute attribute
        WHERE attribute.attrelid = relation.oid
          AND attribute.attname = 'account_id'
          AND attribute.attnum > 0
          AND NOT attribute.attisdropped
      )
    )
    AND (NOT relation.relrowsecurity OR NOT relation.relforcerowsecurity);
  SELECT
    has_schema_privilege('amiary_api', 'amiary', 'USAGE')
    AND has_table_privilege('amiary_api', 'amiary.persons', 'SELECT,INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('amiary_api', 'amiary.persons', 'TRUNCATE')
    AND has_function_privilege('amiary_api', 'amiary.resolve_carddav_credential(text)', 'EXECUTE')
    AND NOT has_table_privilege('amiary_worker', 'amiary.persons', 'SELECT')
    AND has_function_privilege('amiary_worker', 'amiary.claim_graph_events(integer)', 'EXECUTE')
    AND has_function_privilege('amiary_worker', 'amiary.fetch_graph_projection(bigint,uuid,bigint,text,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('amiary_api', 'amiary.claim_graph_events(integer)', 'EXECUTE');
")
if [[ "${amiary_security_contract}" != $'t\nt\nt' ]]; then
  echo "Restored Amiary function ownership or forced-RLS contract is invalid." >&2
  exit 1
fi

echo "Shared PostgreSQL restore verification completed against non-production targets."
