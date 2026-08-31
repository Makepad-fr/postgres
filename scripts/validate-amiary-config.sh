#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
sql="${repo_root}/bootstrap/amiary-apps.sql"
hba="${repo_root}/config/runtrace-pg_hba.conf"
readme="${repo_root}/README.md"

for file in "${sql}" "${hba}" "${readme}"; do
  test -s "${file}" || { echo "missing Amiary PostgreSQL contract: ${file}" >&2; exit 1; }
done

common_roles=(amiary_api amiary_worker)
for role in "${common_roles[@]}"; do
  grep -Fq "CREATE ROLE ${role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS" "${sql}" \
    || { echo "missing constrained NOLOGIN capability role: ${role}" >&2; exit 1; }
  grep -Fq "ALTER ROLE ${role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS" "${sql}" \
    || { echo "bootstrap does not repair capability-role drift: ${role}" >&2; exit 1; }
done

grep -Fq "CREATE ROLE amiary_security_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION BYPASSRLS" "${sql}" \
  || { echo "missing constrained RLS-bypass definer role" >&2; exit 1; }
grep -Fq "ALTER ROLE amiary_security_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION BYPASSRLS" "${sql}" \
  || { echo "bootstrap does not repair security-definer role drift" >&2; exit 1; }
grep -Fq "CREATE ROLE makepad_backup_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION BYPASSRLS" "${sql}" \
  || { echo "missing constrained backup reader role" >&2; exit 1; }
grep -Fq "ALTER ROLE makepad_backup_reader NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION BYPASSRLS" "${sql}" \
  || { echo "bootstrap does not repair backup reader role drift" >&2; exit 1; }

login_roles=(
  amiary_migrator
  amiary_api_prod
  amiary_worker_prod
  amiary_canary_migrator
  amiary_api_canary
  amiary_worker_canary
  keycloak_amiary_app
  makepad_backup
)
password_variables=(
  amiary_migrator_password
  amiary_api_prod_password
  amiary_worker_prod_password
  amiary_canary_migrator_password
  amiary_api_canary_password
  amiary_worker_canary_password
  keycloak_amiary_app_password
  makepad_backup_password
)

for index in "${!login_roles[@]}"; do
  role=${login_roles[${index}]}
  variable=${password_variables[${index}]}
  grep -Fq "CREATE ROLE ${role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE" "${sql}" \
    || { echo "missing constrained login role: ${role}" >&2; exit 1; }
  grep -Fq "ALTER ROLE ${role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE" "${sql}" \
    || { echo "bootstrap does not repair login-role drift: ${role}" >&2; exit 1; }
  grep -Fq "PASSWORD :'${variable}'" "${sql}" \
    || { echo "role password is not supplied by psql variable: ${role}" >&2; exit 1; }
  grep -Fq "NULLIF(btrim(:'${variable}'), '')" "${sql}" \
    || { echo "bootstrap does not reject an empty password: ${variable}" >&2; exit 1; }
done

membership_contracts=(
  "('amiary_api', 'amiary_api_prod', true, false)"
  "('amiary_api', 'amiary_api_canary', true, false)"
  "('amiary_worker', 'amiary_worker_prod', true, false)"
  "('amiary_worker', 'amiary_worker_canary', true, false)"
  "('amiary_security_definer', 'amiary_migrator', false, true)"
  "('amiary_security_definer', 'amiary_canary_migrator', false, true)"
  "('pg_read_all_data', 'makepad_backup_reader', true, false)"
  "('makepad_backup_reader', 'makepad_backup', false, true)"
)
for contract in "${membership_contracts[@]}"; do
  grep -Fq "${contract}" "${sql}" || { echo "missing membership contract: ${contract}" >&2; exit 1; }
done

grep -Fq "'GRANT %I TO %I WITH ADMIN FALSE, INHERIT %s, SET %s'" "${sql}"
grep -Fq "SELECT format('REVOKE %I FROM %I', granted.rolname, member.rolname)" "${sql}"
grep -Fq "WHERE member.rolname IN (" "${sql}"

for database in amiary amiary_canary keycloak_amiary; do
  grep -Eq "^hostnossl[[:space:]]+${database}[[:space:]]+all[[:space:]]+all[[:space:]]+reject$" "${hba}" \
    || { echo "missing plaintext rejection for ${database}" >&2; exit 1; }
  grep -Eq "^hostssl[[:space:]]+${database}[[:space:]]+all[[:space:]]+all[[:space:]]+scram-sha-256$" "${hba}" \
    || { echo "missing TLS/SCRAM rule for ${database}" >&2; exit 1; }
  grep -Fq "REVOKE ALL PRIVILEGES ON DATABASE ${database} FROM PUBLIC;" "${sql}" \
    || { echo "missing public database privilege revocation for ${database}" >&2; exit 1; }
done
grep -Eq '^host[[:space:]]+all[[:space:]]+amiary_migrator,amiary_api_prod,amiary_worker_prod,amiary_canary_migrator,amiary_api_canary,amiary_worker_canary,keycloak_amiary_app,makepad_backup[[:space:]]+all[[:space:]]+reject$' "${hba}" \
  || { echo "missing cross-database HBA rejection for Amiary login roles" >&2; exit 1; }

grep -Fq "CREATE DATABASE amiary OWNER amiary_migrator" "${sql}"
grep -Fq "ALTER DATABASE amiary OWNER TO amiary_migrator" "${sql}"
grep -Fq "GRANT CONNECT ON DATABASE amiary TO amiary_migrator, amiary_api_prod, amiary_worker_prod;" "${sql}"
grep -Fq "CREATE DATABASE amiary_canary OWNER amiary_canary_migrator" "${sql}"
grep -Fq "ALTER DATABASE amiary_canary OWNER TO amiary_canary_migrator" "${sql}"
grep -Fq "GRANT CONNECT ON DATABASE amiary_canary TO amiary_canary_migrator, amiary_api_canary, amiary_worker_canary;" "${sql}"
grep -Fq "CREATE DATABASE keycloak_amiary OWNER keycloak_amiary_app" "${sql}"
grep -Fq "ALTER DATABASE keycloak_amiary OWNER TO keycloak_amiary_app" "${sql}"

if grep -Eq "(CREATE|ALTER) DATABASE (amiary|amiary_canary) OWNER (amiary_api_|amiary_worker_)" "${sql}"; then
  echo "API or worker role must not own an Amiary database" >&2
  exit 1
fi

grep -Fq "pg_advisory_lock" "${sql}"
grep -Fq "pg_advisory_unlock" "${sql}"
grep -Fq "bootstrap/amiary-apps.sql" "${readme}"

readme_roles=(
  amiary_migrator
  amiary_api_prod
  amiary_worker_prod
  amiary_canary_migrator
  amiary_api_canary
  amiary_worker_canary
  amiary_api
  amiary_worker
  amiary_security_definer
  keycloak_amiary_app
  makepad_backup
  makepad_backup_reader
)
for role in "${readme_roles[@]}"; do
  grep -Fq "${role}" "${readme}" || { echo "README does not document role: ${role}" >&2; exit 1; }
done

environment_variables=(
  AMIARY_MIGRATOR_DB_PASSWORD
  AMIARY_API_DB_PASSWORD
  AMIARY_WORKER_DB_PASSWORD
  AMIARY_CANARY_MIGRATOR_DB_PASSWORD
  AMIARY_CANARY_API_DB_PASSWORD
  AMIARY_CANARY_WORKER_DB_PASSWORD
  KEYCLOAK_AMIARY_DB_PASSWORD
  MAKEPAD_BACKUP_DB_PASSWORD
)
for variable in "${environment_variables[@]}"; do
  grep -Fq "\${${variable}:?" "${readme}" || { echo "README does not fail fast for ${variable}" >&2; exit 1; }
done

for role in amiary_migrator amiary_api_prod amiary_worker_prod amiary_canary_migrator amiary_api_canary amiary_worker_canary keycloak_amiary_app; do
  grep -Fq "postgres://${role}:<secret>@<db-vm-host>:5432/" "${readme}" \
    || { echo "README is missing certificate-verified DSN for ${role}" >&2; exit 1; }
done
grep -Fq "sslmode=verify-full&sslrootcert=/run/secrets/database_ca" "${readme}"

if grep -Eq "(password|secret)[[:space:]]*=[[:space:]]*['\"][^:'\"]+['\"]" "${sql}"; then
  echo "possible literal secret in Amiary bootstrap" >&2
  exit 1
fi

echo "Amiary PostgreSQL provisioning contract is valid."
