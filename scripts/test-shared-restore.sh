#!/usr/bin/env bash
set -euo pipefail

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 1; }

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)
suffix=$$
network="amiary-pg-restore-${suffix}"
server="amiary-pg-restore-${suffix}"
postgres_image='postgres:18-alpine@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2'
password='disposable-restore-password'

cleanup() {
  docker rm -f "${server}" >/dev/null 2>&1 || true
  docker network rm "${network}" >/dev/null 2>&1 || true
  find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true
  rmdir "${work_dir}" 2>/dev/null || true
}
trap cleanup EXIT

docker network create "${network}" >/dev/null
docker run -d --rm --name "${server}" --network "${network}" --network-alias postgres-restore \
  -e POSTGRES_PASSWORD="${password}" "${postgres_image}" >/dev/null
for _ in $(seq 1 30); do
  if docker exec "${server}" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "${server}" pg_isready -U postgres -d postgres >/dev/null

docker exec -i "${server}" psql -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null <<'SQL'
CREATE ROLE runtrace_app NOLOGIN;
CREATE ROLE keycloak_runtrace_app NOLOGIN;
CREATE ROLE amiary_migrator NOLOGIN;
CREATE ROLE amiary_canary_migrator NOLOGIN;
CREATE ROLE amiary_security_definer NOLOGIN BYPASSRLS;
CREATE ROLE amiary_api NOLOGIN;
CREATE ROLE amiary_worker NOLOGIN;
CREATE ROLE keycloak_amiary_app NOLOGIN;
CREATE ROLE makepad_backup LOGIN PASSWORD 'disposable-backup-password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE makepad_backup_reader NOLOGIN
  NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION BYPASSRLS;
GRANT pg_read_all_data TO makepad_backup_reader WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;
GRANT makepad_backup_reader TO makepad_backup WITH ADMIN FALSE, INHERIT FALSE, SET TRUE;
SQL

for database in runtrace keycloak_runtrace amiary amiary_canary keycloak_amiary; do
  docker exec "${server}" createdb -U postgres "${database}"
done
for database in runtrace_restore_test keycloak_runtrace_restore_test amiary_restore_test amiary_canary_restore_test keycloak_amiary_restore_test; do
  docker exec "${server}" createdb -U postgres "${database}"
done

docker exec -i "${server}" psql -v ON_ERROR_STOP=1 -U postgres -d runtrace >/dev/null <<'SQL'
CREATE TABLE public.runtrace_state (id bigint PRIMARY KEY);
ALTER TABLE public.runtrace_state OWNER TO runtrace_app;
SQL
docker exec -i "${server}" psql -v ON_ERROR_STOP=1 -U postgres -d keycloak_runtrace >/dev/null <<'SQL'
CREATE TABLE public.realm (id text PRIMARY KEY);
ALTER TABLE public.realm OWNER TO keycloak_runtrace_app;
SQL
docker exec -i "${server}" psql -v ON_ERROR_STOP=1 -U postgres -d keycloak_amiary >/dev/null <<'SQL'
CREATE TABLE public.realm (id text PRIMARY KEY);
ALTER TABLE public.realm OWNER TO keycloak_amiary_app;
SQL

for database in amiary amiary_canary; do
  docker exec -i "${server}" psql -v ON_ERROR_STOP=1 -U postgres -d "${database}" >/dev/null <<'SQL'
CREATE SCHEMA amiary AUTHORIZATION amiary_migrator;
CREATE TABLE amiary.persons (account_id uuid NOT NULL, id uuid PRIMARY KEY);
ALTER TABLE amiary.persons OWNER TO amiary_migrator;
ALTER TABLE amiary.persons ENABLE ROW LEVEL SECURITY;
ALTER TABLE amiary.persons FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON amiary.persons USING (true) WITH CHECK (true);
GRANT USAGE ON SCHEMA amiary TO amiary_api, amiary_worker, amiary_security_definer;
GRANT SELECT, INSERT, UPDATE, DELETE ON amiary.persons TO amiary_api;

CREATE FUNCTION amiary.resolve_carddav_credential(text) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, amiary AS 'BEGIN RETURN; END';
CREATE FUNCTION amiary.claim_graph_events(integer) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, amiary AS 'BEGIN RETURN; END';
CREATE FUNCTION amiary.finish_graph_event(bigint, timestamptz, text) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, amiary AS 'BEGIN RETURN; END';
CREATE FUNCTION amiary.fetch_graph_projection(bigint, uuid, bigint, text, uuid) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, amiary AS 'BEGIN RETURN; END';
ALTER FUNCTION amiary.resolve_carddav_credential(text) OWNER TO amiary_security_definer;
ALTER FUNCTION amiary.claim_graph_events(integer) OWNER TO amiary_security_definer;
ALTER FUNCTION amiary.finish_graph_event(bigint, timestamptz, text) OWNER TO amiary_security_definer;
ALTER FUNCTION amiary.fetch_graph_projection(bigint, uuid, bigint, text, uuid) OWNER TO amiary_security_definer;
REVOKE ALL ON FUNCTION amiary.resolve_carddav_credential(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION amiary.claim_graph_events(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION amiary.finish_graph_event(bigint, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION amiary.fetch_graph_projection(bigint, uuid, bigint, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION amiary.resolve_carddav_credential(text) TO amiary_api;
GRANT EXECUTE ON FUNCTION amiary.claim_graph_events(integer) TO amiary_worker;
GRANT EXECUTE ON FUNCTION amiary.finish_graph_event(bigint, timestamptz, text) TO amiary_worker;
GRANT EXECUTE ON FUNCTION amiary.fetch_graph_projection(bigint, uuid, bigint, text, uuid) TO amiary_worker;
SQL
done

for database in runtrace keycloak_runtrace amiary amiary_canary keycloak_amiary; do
  docker exec "${server}" psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
    -c "GRANT CONNECT ON DATABASE ${database} TO makepad_backup" >/dev/null
  docker run --rm --user "$(id -u):$(id -g)" --network "${network}" \
    -e PGPASSWORD=disposable-backup-password -v "${work_dir}:/backups" "${postgres_image}" \
    pg_dump -h postgres-restore -U makepad_backup --role=makepad_backup_reader -d "${database}" -Fc -f "/backups/${database}.dump"
done

if docker exec -e PGPASSWORD=disposable-backup-password "${server}" \
  psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U makepad_backup -d amiary \
  -c "INSERT INTO amiary.persons(account_id,id) VALUES ('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002')" >/dev/null 2>&1; then
  echo "backup login unexpectedly wrote application data" >&2
  exit 1
fi
(
  cd "${work_dir}"
  sha256sum runtrace.dump keycloak_runtrace.dump amiary.dump amiary_canary.dump keycloak_amiary.dump > SHA256SUMS
)
printf '{"fixture":"disposable","databases":["runtrace","keycloak_runtrace","amiary","amiary_canary","keycloak_amiary"]}\n' > "${work_dir}/metadata.json"

cat > "${work_dir}/pg_service.conf" <<EOF
[runtrace_restore_test]
host=postgres-restore
port=5432
user=postgres
password=${password}
dbname=runtrace_restore_test
[keycloak_runtrace_restore_test]
host=postgres-restore
port=5432
user=postgres
password=${password}
dbname=keycloak_runtrace_restore_test
[amiary_restore_test]
host=postgres-restore
port=5432
user=postgres
password=${password}
dbname=amiary_restore_test
[amiary_canary_restore_test]
host=postgres-restore
port=5432
user=postgres
password=${password}
dbname=amiary_canary_restore_test
[keycloak_amiary_restore_test]
host=postgres-restore
port=5432
user=postgres
password=${password}
dbname=keycloak_amiary_restore_test
EOF
chmod 0600 "${work_dir}/pg_service.conf"

docker run --rm --user "$(id -u):$(id -g)" --network "${network}" \
  -v "${work_dir}:/restore:ro" \
  -v "${repo_root}/scripts/verify-runtrace-restore.sh:/verify-runtrace-restore.sh:ro" \
  -e PGSERVICEFILE=/restore/pg_service.conf \
  -e RUNTRACE_RESTORE_SERVICE=runtrace_restore_test \
  -e KEYCLOAK_RUNTRACE_RESTORE_SERVICE=keycloak_runtrace_restore_test \
  -e AMIARY_RESTORE_SERVICE=amiary_restore_test \
  -e AMIARY_CANARY_RESTORE_SERVICE=amiary_canary_restore_test \
  -e KEYCLOAK_AMIARY_RESTORE_SERVICE=keycloak_amiary_restore_test \
  -e RUNTRACE_RESTORE_CONFIRM=replace-nonproduction-restore-targets \
  "${postgres_image}" bash /verify-runtrace-restore.sh /restore

echo "Shared PostgreSQL ownership/ACL restore contract passed."
