#!/usr/bin/env bash
set -euo pipefail
# This fixture owns only uniquely named local containers and volumes.
case "$(docker context inspect --format '{{.Endpoints.docker.Host}}')" in
  unix://*) ;;
  *) echo 'Image upgrade fixture requires a local Docker socket' >&2; exit 1 ;;
esac
root=$(cd "$(dirname "$0")/.." && pwd)
old_image='postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777'
new_image=$(awk -F= '$1 == "POSTGRES_IMAGE" {print $2}' "$root/envs/production/.env.db")
[[ "$new_image" =~ ^postgres:16-alpine@sha256:[a-f0-9]{64}$ ]]
name="postgres-image-upgrade-${RANDOM}-$$"
restore="${name}-restore"
volume="${name}-data"
restore_volume="${name}-restored"
tmp=$(mktemp -d)
cleanup() {
  docker rm -f "$name" "$restore" >/dev/null 2>&1 || true
  docker volume rm "$volume" "$restore_volume" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
password=$(openssl rand -hex 24)
docker volume create "$volume" >/dev/null
docker volume create "$restore_volume" >/dev/null
start() {
  docker run -d --name "$1" --network none -e POSTGRES_PASSWORD="$password" \
    -v "$2:/var/lib/postgresql/data" "$3" >/dev/null
  for _ in $(seq 1 100); do
    if docker exec "$1" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then return; fi
    sleep 0.2
  done
  echo 'Fixture PostgreSQL did not become ready' >&2; return 1
}
query() { docker exec "$1" psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -Atc "$2"; }
start "$name" "$volume" "$old_image"
query "$name" "CREATE EXTENSION pgcrypto; CREATE EXTENSION pg_trgm; CREATE ROLE fixture_owner NOLOGIN; CREATE TABLE fixture_payload(id bigint PRIMARY KEY, body text NOT NULL, metadata jsonb NOT NULL); ALTER TABLE fixture_payload OWNER TO fixture_owner; INSERT INTO fixture_payload SELECT n, repeat(md5(n::text),16), jsonb_build_object('id',n) FROM generate_series(1,1000) n; CREATE INDEX fixture_search ON fixture_payload USING gin(body gin_trgm_ops);" >/dev/null
expected=$(query "$name" "SELECT count(*) || ':' || md5(string_agg(body || metadata::text, ',' ORDER BY id)) FROM fixture_payload")
docker exec "$name" pg_dumpall -U postgres > "$tmp/pre-upgrade.sql"
docker stop "$name" >/dev/null
docker rm "$name" >/dev/null
start "$name" "$volume" "$new_image"
[[ "$(query "$name" "SELECT count(*) || ':' || md5(string_agg(body || metadata::text, ',' ORDER BY id)) FROM fixture_payload")" == "$expected" ]]
[[ "$(query "$name" "SELECT tableowner FROM pg_tables WHERE tablename='fixture_payload'")" == fixture_owner ]]
[[ "$(query "$name" "SELECT count(*) FROM pg_extension WHERE extname IN ('pgcrypto','pg_trgm')")" == 2 ]]
query "$name" "INSERT INTO fixture_payload VALUES(1001, 'after upgrade', '{}'::jsonb); DELETE FROM fixture_payload WHERE id=1001;" >/dev/null
# A pre-upgrade logical backup must recover using the previous runtime.
start "$restore" "$restore_volume" "$old_image"
# pg_dumpall includes CREATE ROLE postgres, already created by initdb.
sed '/^CREATE ROLE postgres;$/d' "$tmp/pre-upgrade.sql" | docker exec -i "$restore" psql -X -v ON_ERROR_STOP=1 -U postgres >/dev/null
[[ "$(query "$restore" "SELECT count(*) || ':' || md5(string_agg(body || metadata::text, ',' ORDER BY id)) FROM fixture_payload")" == "$expected" ]]
[[ "$(query "$restore" "SELECT tableowner FROM pg_tables WHERE tablename='fixture_payload'")" == fixture_owner ]]
printf 'PostgreSQL candidate: '
docker exec "$name" postgres --version
printf 'In-place fixture upgrade, extensions, ownership, writes and pre-upgrade logical restore passed.\n'
