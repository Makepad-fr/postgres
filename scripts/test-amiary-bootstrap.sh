#!/usr/bin/env bash
set -euo pipefail

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
container="amiary-postgres-bootstrap-test-$$"

cleanup() {
  docker rm -f "${container}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --rm --name "${container}" \
  -e POSTGRES_PASSWORD=test-superuser-password \
  -v "${repo_root}/bootstrap/amiary-apps.sql:/bootstrap/amiary-apps.sql:ro" \
  postgres:18@sha256:4ef4dbc939d61acea57712655ddb4b4ab27419c913f94cca0cd57cb3ea3c2280 >/dev/null

for _ in $(seq 1 30); do
  if docker exec "${container}" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "${container}" pg_isready -U postgres -d postgres >/dev/null
docker exec "${container}" createdb -U postgres runtrace
docker exec "${container}" createdb -U postgres keycloak_runtrace

bootstrap() {
  docker exec "${container}" psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -v amiary_migrator_password=test-prod-migrator-password \
    -v amiary_api_prod_password=test-prod-api-password \
    -v amiary_worker_prod_password=test-prod-worker-password \
    -v amiary_canary_migrator_password=test-canary-migrator-password \
    -v amiary_api_canary_password=test-canary-api-password \
    -v amiary_worker_canary_password=test-canary-worker-password \
    -v keycloak_amiary_app_password=test-keycloak-password \
    -v makepad_backup_password=test-backup-password \
    -f /bootstrap/amiary-apps.sql >/dev/null
}

bootstrap

# Introduce representative ownership, membership, and role-attribute drift. A
# second run must converge back to the declared least-privilege state.
docker exec "${container}" psql -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
ALTER ROLE amiary_api LOGIN SUPERUSER CREATEDB CREATEROLE INHERIT REPLICATION BYPASSRLS;
ALTER ROLE amiary_api_prod SUPERUSER CREATEDB CREATEROLE NOINHERIT REPLICATION BYPASSRLS;
ALTER ROLE amiary_security_definer LOGIN SUPERUSER CREATEDB CREATEROLE INHERIT REPLICATION;
ALTER DATABASE amiary OWNER TO amiary_api_prod;
GRANT ALL PRIVILEGES ON DATABASE amiary_canary TO amiary_api_prod;
GRANT amiary_security_definer TO amiary_api_prod WITH ADMIN TRUE, INHERIT TRUE, SET TRUE;
CREATE ROLE unrelated_application_role NOLOGIN;
GRANT unrelated_application_role TO amiary_api_prod;
GRANT unrelated_application_role TO makepad_backup;
GRANT unrelated_application_role TO makepad_backup_reader;
ALTER ROLE makepad_backup SUPERUSER CREATEDB CREATEROLE INHERIT REPLICATION BYPASSRLS;
SQL

bootstrap

roles=$(docker exec "${container}" psql -At -U postgres -d postgres -c \
  "SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolinherit, rolreplication, rolbypassrls FROM pg_roles WHERE rolname IN ('amiary_api','amiary_worker','amiary_security_definer','amiary_migrator','amiary_api_prod','amiary_worker_prod','amiary_canary_migrator','amiary_api_canary','amiary_worker_canary','keycloak_amiary_app','makepad_backup','makepad_backup_reader') ORDER BY rolname")
expected_roles=$'amiary_api|f|f|f|f|f|f|f\namiary_api_canary|t|f|f|f|t|f|f\namiary_api_prod|t|f|f|f|t|f|f\namiary_canary_migrator|t|f|f|f|f|f|f\namiary_migrator|t|f|f|f|f|f|f\namiary_security_definer|f|f|f|f|f|f|t\namiary_worker|f|f|f|f|f|f|f\namiary_worker_canary|t|f|f|f|t|f|f\namiary_worker_prod|t|f|f|f|t|f|f\nkeycloak_amiary_app|t|f|f|f|f|f|f\nmakepad_backup|t|f|f|f|f|f|f\nmakepad_backup_reader|f|f|f|f|t|f|t'
test "${roles}" = "${expected_roles}" || { printf 'unexpected role policy:\n%s\n' "${roles}" >&2; exit 1; }

memberships=$(docker exec "${container}" psql -At -U postgres -d postgres -c \
  "SELECT granted.rolname, member.rolname, membership.admin_option, membership.inherit_option, membership.set_option FROM pg_auth_members membership JOIN pg_roles granted ON granted.oid = membership.roleid JOIN pg_roles member ON member.oid = membership.member WHERE granted.rolname IN ('amiary_api','amiary_worker','amiary_security_definer','pg_read_all_data','makepad_backup_reader') AND member.rolname IN ('amiary_api_prod','amiary_api_canary','amiary_worker_prod','amiary_worker_canary','amiary_migrator','amiary_canary_migrator','makepad_backup','makepad_backup_reader') ORDER BY granted.rolname, member.rolname")
expected_memberships=$'amiary_api|amiary_api_canary|f|t|f\namiary_api|amiary_api_prod|f|t|f\namiary_security_definer|amiary_canary_migrator|f|f|t\namiary_security_definer|amiary_migrator|f|f|t\namiary_worker|amiary_worker_canary|f|t|f\namiary_worker|amiary_worker_prod|f|t|f\nmakepad_backup_reader|makepad_backup|f|f|t\npg_read_all_data|makepad_backup_reader|f|t|f'
test "${memberships}" = "${expected_memberships}" || { printf 'unexpected role membership policy:\n%s\n' "${memberships}" >&2; exit 1; }
undeclared_memberships=$(docker exec "${container}" psql -At -U postgres -d postgres -c \
  "SELECT count(*) FROM pg_auth_members membership JOIN pg_roles member ON member.oid = membership.member WHERE member.rolname IN ('amiary_migrator','amiary_api_prod','amiary_worker_prod','amiary_canary_migrator','amiary_api_canary','amiary_worker_canary','keycloak_amiary_app','makepad_backup','makepad_backup_reader') AND NOT EXISTS (SELECT 1 FROM (VALUES ('amiary_api','amiary_api_prod'),('amiary_api','amiary_api_canary'),('amiary_worker','amiary_worker_prod'),('amiary_worker','amiary_worker_canary'),('amiary_security_definer','amiary_migrator'),('amiary_security_definer','amiary_canary_migrator'),('pg_read_all_data','makepad_backup_reader'),('makepad_backup_reader','makepad_backup')) allowed(granted_role,member_role) JOIN pg_roles granted ON granted.rolname = allowed.granted_role WHERE granted.oid = membership.roleid AND allowed.member_role = member.rolname)")
test "${undeclared_memberships}" = 0 || { echo "Amiary login retains an undeclared role membership" >&2; exit 1; }

databases=$(docker exec "${container}" psql -At -U postgres -d postgres -c \
  "SELECT database.datname, owner.rolname FROM pg_database database JOIN pg_roles owner ON owner.oid = database.datdba WHERE database.datname IN ('amiary','amiary_canary','keycloak_amiary') ORDER BY database.datname")
expected_databases=$'amiary|amiary_migrator\namiary_canary|amiary_canary_migrator\nkeycloak_amiary|keycloak_amiary_app'
test "${databases}" = "${expected_databases}" || { printf 'unexpected database ownership:\n%s\n' "${databases}" >&2; exit 1; }

runtime_database_privileges=$(docker exec "${container}" psql -At -U postgres -d postgres -c \
  "WITH expected(role_name, database_name, may_connect) AS (VALUES ('amiary_api_prod','amiary',true), ('amiary_api_prod','amiary_canary',false), ('amiary_worker_prod','amiary',true), ('amiary_worker_prod','amiary_canary',false), ('amiary_api_canary','amiary',false), ('amiary_api_canary','amiary_canary',true), ('amiary_worker_canary','amiary',false), ('amiary_worker_canary','amiary_canary',true)) SELECT count(*) FROM expected WHERE has_database_privilege(role_name, database_name, 'CONNECT') IS DISTINCT FROM may_connect OR has_database_privilege(role_name, database_name, 'CREATE') OR has_database_privilege(role_name, database_name, 'TEMPORARY')")
test "${runtime_database_privileges}" = 0 || { echo "runtime database privileges are too broad" >&2; exit 1; }

shared_role_connect=$(docker exec "${container}" psql -At -U postgres -d postgres -c \
  "SELECT count(*) FROM (VALUES ('amiary_api'), ('amiary_worker'), ('amiary_security_definer')) AS roles(role_name) CROSS JOIN (VALUES ('amiary'), ('amiary_canary'), ('keycloak_amiary')) AS databases(database_name) WHERE has_database_privilege(role_name, database_name, 'CONNECT')")
test "${shared_role_connect}" = 0 || { echo "NOLOGIN capability role unexpectedly has database CONNECT" >&2; exit 1; }

connect_as() {
  local role=$1
  local password=$2
  local database=$3
  docker exec -e PGPASSWORD="${password}" "${container}" \
    psql -h 127.0.0.1 -At -v ON_ERROR_STOP=1 -U "${role}" -d "${database}" -c 'SELECT current_user' 2>/dev/null
}

test "$(connect_as amiary_api_prod test-prod-api-password amiary)" = amiary_api_prod
test "$(connect_as amiary_worker_prod test-prod-worker-password amiary)" = amiary_worker_prod
test "$(connect_as amiary_api_canary test-canary-api-password amiary_canary)" = amiary_api_canary
test "$(connect_as amiary_worker_canary test-canary-worker-password amiary_canary)" = amiary_worker_canary
test "$(connect_as keycloak_amiary_app test-keycloak-password keycloak_amiary)" = keycloak_amiary_app
test "$(connect_as makepad_backup test-backup-password amiary)" = makepad_backup

docker exec -e PGPASSWORD=test-backup-password "${container}" \
  psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U makepad_backup -d amiary \
  -c 'SET ROLE makepad_backup_reader; SELECT current_role' >/dev/null
if docker exec -e PGPASSWORD=test-backup-password "${container}" \
  psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U makepad_backup -d amiary \
  -c 'CREATE TABLE public.backup_privilege_escape (id bigint)' >/dev/null 2>&1; then
  echo "backup login can create schema objects" >&2
  exit 1
fi
if docker exec -e PGPASSWORD=test-backup-password "${container}" \
  psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U makepad_backup -d amiary \
  -c 'ALTER ROLE makepad_backup SUPERUSER' >/dev/null 2>&1; then
  echo "backup login can alter roles" >&2
  exit 1
fi

if connect_as amiary_api_prod test-prod-api-password amiary_canary >/dev/null; then
  echo "production API login connected to canary" >&2
  exit 1
fi
if connect_as amiary_worker_canary test-canary-worker-password amiary >/dev/null; then
  echo "canary worker login connected to production" >&2
  exit 1
fi
if connect_as keycloak_amiary_app test-keycloak-password amiary >/dev/null; then
  echo "Keycloak login connected to the Amiary application database" >&2
  exit 1
fi

if docker exec -e PGPASSWORD=test-prod-api-password "${container}" \
  psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U amiary_api_prod -d amiary \
  -c 'SET ROLE amiary_security_definer' >/dev/null 2>&1; then
  echo "API login can SET ROLE to the RLS-bypass owner" >&2
  exit 1
fi

docker exec -e PGPASSWORD=test-prod-migrator-password "${container}" \
  psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U amiary_migrator -d amiary \
  -c 'SET ROLE amiary_security_definer' >/dev/null

if docker exec -e PGPASSWORD=test-prod-api-password "${container}" \
  psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U amiary_api_prod -d amiary \
  -c 'CREATE TABLE public.privilege_escape_test (id bigint)' >/dev/null 2>&1; then
  echo "API login can create schema objects" >&2
  exit 1
fi

docker exec -e PGPASSWORD=test-prod-migrator-password "${container}" \
  psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U amiary_migrator -d amiary \
  -c 'CREATE TABLE public.migration_permission_test (id bigint); DROP TABLE public.migration_permission_test' >/dev/null

echo "Amiary PostgreSQL bootstrap is idempotent, drift-repairing, and least-privilege."
