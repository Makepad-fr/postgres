#!/usr/bin/env bash
# Synthetic data only. No host ports, shared volumes, or production credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
old_image=$(sed -n 's/^POSTGRES_IMAGE=//p' envs/production/.env.db)
new_image=$(sed -n 's/.*POSTGRES_IMAGE:-\([^}]*\)}.*/\1/p' compose.yml | head -1)
data_path=$(sed -n 's/^      PGDATA: //p' compose.yml)
[[ "$old_image" == postgres:16-alpine@sha256:* && "$new_image" == postgres:18-alpine@sha256:* ]]
prefix="postgres-major-review-$$-${RANDOM}"
legacy="${prefix}-legacy"
candidate="${prefix}-candidate"
probe="${prefix}-probe"
old_volume="${prefix}-16"
new_volume="${prefix}-18"
cleanup() {
  docker rm -fv "$legacy" "$candidate" "$probe" >/dev/null 2>&1 || true
  docker volume rm "$old_volume" "$new_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker volume create "$old_volume" >/dev/null
docker volume create "$new_volume" >/dev/null
ready() {
  local name=$1
  for _ in {1..60}; do
    if [[ $(docker inspect "$name" --format '{{.State.Running}}') != true ]]; then
      docker logs "$name" >&2
      return 1
    fi
    if docker exec "$name" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  docker logs "$name" >&2
  return 1
}
docker run -d --name "$legacy" --network none --memory 256m \
  -e POSTGRES_HOST_AUTH_METHOD=trust -e PGDATA=/var/lib/postgresql/data \
  -v "$old_volume:/var/lib/postgresql/data" "$old_image" >/dev/null
ready "$legacy"
docker exec -i "$legacy" psql -U postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE DATABASE compatibility;
\connect compatibility
CREATE TABLE preserved (id integer PRIMARY KEY, amount numeric(12,2), label text);
INSERT INTO preserved VALUES (1,123.45,'Visitaki café'),(2,0.00,'retained');
SQL
data_args=()
if [[ -n "$data_path" ]]; then data_args=(-e "PGDATA=$data_path"); fi
docker run -d --name "$candidate" --network none --memory 256m \
  -e POSTGRES_HOST_AUTH_METHOD=trust "${data_args[@]}" \
  -v "$new_volume:/var/lib/postgresql/data" "$new_image" >/dev/null
ready "$candidate"
[[ $(docker exec "$candidate" cat /var/lib/postgresql/data/PG_VERSION) == 18 ]]
docker exec "$candidate" createdb -U postgres compatibility
docker exec "$legacy" pg_dump -U postgres -Fc compatibility |
  docker exec -i "$candidate" pg_restore -U postgres -d compatibility --exit-on-error
expected='2|123.45|Visitaki café'
query="SELECT count(*)||'|'||sum(amount)||'|'||max(CASE WHEN id=1 THEN label END) FROM preserved"
[[ $(docker exec "$candidate" psql -U postgres -d compatibility -Atc "$query") == "$expected" ]]
docker stop "$legacy" >/dev/null
# A major image must refuse an existing 16 directory without changing it.
docker run -d --name "$probe" --network none --memory 256m \
  -e POSTGRES_HOST_AUTH_METHOD=trust "${data_args[@]}" \
  -v "$old_volume:/var/lib/postgresql/data" "$new_image" >/dev/null
for _ in {1..30}; do
  [[ $(docker inspect "$probe" --format '{{.State.Running}}') == false ]] && break
  sleep 1
done
[[ $(docker inspect "$probe" --format '{{.State.Running}}') == false ]]
[[ $(docker inspect "$probe" --format '{{.State.ExitCode}}') != 0 ]]
docker logs "$probe" 2>&1 | grep -q 'database files are incompatible with server'
docker rm "$probe" >/dev/null
docker start "$legacy" >/dev/null
ready "$legacy"
[[ $(docker exec "$legacy" psql -U postgres -d compatibility -Atc "$query") == "$expected" ]]
[[ $(docker exec "$legacy" cat /var/lib/postgresql/data/PG_VERSION) == 16 ]]
printf '%s\n' 'PASS: fresh 18 uses the mounted directory, logical 16-to-18 restore preserves rows, and an in-place major swap refuses safely while 16 can restart.'
