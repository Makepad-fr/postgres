#!/bin/sh
set -eu
# No externally supplied database URL; refuse a remote Docker endpoint.
case "$(docker context inspect --format '{{.Endpoints.docker.Host}}')" in
  unix://*) ;;
  *) echo 'CartHop fixture requires a local Docker socket' >&2; exit 1 ;;
esac
name="carthop-bootstrap-verification-$$"
password=$(openssl rand -hex 24)
docker run -d --name "$name" --network none -e POSTGRES_PASSWORD="$password" \
  postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777 >/dev/null
trap 'docker rm -f "$name" >/dev/null' EXIT
n=0
until docker exec "$name" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
  n=$((n+1)); test "$n" -lt 60; sleep 1
done
cd "$(dirname "$0")/.."
# Missing/weak passwords must fail, not merely print a warning and exit zero.
if docker exec -i "$name" psql -U postgres < bootstrap/carthop-app.sql >/dev/null 2>&1; then exit 1; fi
if docker exec -i "$name" psql -U postgres -v carthop_app_password=short < bootstrap/carthop-app.sql >/dev/null 2>&1; then exit 1; fi
test "$(docker exec "$name" psql -U postgres -Atc "SELECT count(*) FROM pg_roles WHERE rolname='carthop_app'")" = 0
docker exec -i "$name" psql -U postgres -v carthop_app_password="$password" < bootstrap/carthop-app.sql >/dev/null
test "$(docker exec "$name" psql -U postgres -Atc "SELECT count(*) FROM pg_roles WHERE rolname='carthop_app' AND rolcanlogin AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls")" = 1
# This first layer deliberately refuses every existing installation.
if docker exec -i "$name" psql -U postgres -v carthop_app_password="$password" < bootstrap/carthop-app.sql >/dev/null 2>&1; then exit 1; fi
docker exec "$name" psql -U postgres -c 'ALTER ROLE carthop_app CREATEDB' >/dev/null
if docker exec -i "$name" psql -U postgres -v carthop_app_password="$password" < bootstrap/carthop-app.sql >/dev/null 2>&1; then exit 1; fi
echo 'CartHop fresh bootstrap and precondition refusal passed.'
