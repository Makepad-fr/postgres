#!/bin/sh
set -eu
# Run only against a dedicated disposable container; no host/database URL input is accepted.
name=carthop-bootstrap-verification
if docker inspect "$name" >/dev/null 2>&1; then echo 'Inspect existing test container before retrying.' >&2; exit 1; fi
password=$(openssl rand -hex 24)
docker run -d --name "$name" --network none -e POSTGRES_PASSWORD="$password" postgres:16-alpine >/dev/null
trap 'docker rm -f "$name" >/dev/null' EXIT
n=0
until docker exec "$name" pg_isready -U postgres >/dev/null 2>&1; do n=$((n+1)); test "$n" -lt 30; sleep 1; done
cd "$(dirname "$0")/.."
for attempt in first second; do
  docker exec -i "$name" psql -U postgres -v carthop_app_password="$password" < bootstrap/carthop-app.sql >/dev/null
done
test "$(docker exec "$name" psql -U postgres -Atc "SELECT count(*) FROM pg_roles WHERE rolname='carthop_app' AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole")" = 1
# Existing overprivileged roles must fail closed, not be silently reused.
docker exec "$name" psql -U postgres -c 'ALTER ROLE carthop_app CREATEDB' >/dev/null
if docker exec -i "$name" psql -U postgres -v carthop_app_password="$password" < bootstrap/carthop-app.sql >/dev/null; then echo 'Overprivileged role was accepted' >&2; exit 1; fi
echo 'CartHop bootstrap reruns and privilege checks passed.'
