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
# A reviewed valid installation is a no-op; unsafe existing state fails closed.
docker exec -i "$name" psql -U postgres -v carthop_app_password="$password" < bootstrap/carthop-app.sql >/dev/null
reject_bootstrap() {
  if docker exec -i "$name" psql -U postgres -v carthop_app_password="$password" < bootstrap/carthop-app.sql >/dev/null 2>&1; then
    echo 'Unsafe existing installation was accepted' >&2; exit 1
  fi
}
for capability in SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS; do
  docker exec "$name" psql -U postgres -c "ALTER ROLE carthop_app $capability" >/dev/null
  reject_bootstrap
  docker exec "$name" psql -U postgres -c "ALTER ROLE carthop_app NO$capability" >/dev/null
done
docker exec "$name" psql -U postgres -c 'ALTER ROLE carthop_app NOLOGIN' >/dev/null
reject_bootstrap
docker exec "$name" psql -U postgres -c 'ALTER ROLE carthop_app LOGIN; CREATE ROLE unrelated_fixture;' >/dev/null
for membership in 'unrelated_fixture TO carthop_app' 'carthop_app TO unrelated_fixture'; do
  docker exec "$name" psql -U postgres -c "GRANT $membership" >/dev/null
  reject_bootstrap
  source_role=${membership%% TO*}
  member_role=${membership##*TO }
  docker exec "$name" psql -U postgres -c "REVOKE $source_role FROM $member_role" >/dev/null
done
for privilege in CONNECT TEMPORARY; do
  docker exec "$name" psql -U postgres -c "GRANT $privilege ON DATABASE carthop TO PUBLIC" >/dev/null
  reject_bootstrap
  docker exec "$name" psql -U postgres -c "REVOKE $privilege ON DATABASE carthop FROM PUBLIC" >/dev/null
done
docker exec "$name" psql -U postgres -c 'ALTER DATABASE carthop OWNER TO postgres' >/dev/null
reject_bootstrap
docker exec "$name" psql -U postgres -c 'ALTER DATABASE carthop OWNER TO carthop_app' >/dev/null
# A safe rerun never rotates the login to the newly supplied candidate password.
original_hash=$(docker exec "$name" psql -U postgres -Atc "SELECT rolpassword FROM pg_authid WHERE rolname='carthop_app'")
docker exec -i "$name" psql -U postgres -v carthop_app_password="$(openssl rand -hex 24)" < bootstrap/carthop-app.sql >/dev/null
test "$(docker exec "$name" psql -U postgres -Atc "SELECT rolpassword FROM pg_authid WHERE rolname='carthop_app'")" = "$original_hash"
docker exec "$name" psql -U postgres -c 'DROP DATABASE carthop' >/dev/null
reject_bootstrap
docker exec "$name" psql -U postgres -c 'DROP ROLE carthop_app' >/dev/null
docker exec "$name" psql -U postgres -c 'CREATE DATABASE carthop' >/dev/null
reject_bootstrap
test "$(docker exec "$name" psql -U postgres -Atc "SELECT count(*) FROM pg_roles WHERE rolname='unrelated_fixture'")" = 1
echo 'CartHop bootstrap: safe reruns, credentials preserved, privilege/ACL/membership/partial-state rejection passed.'
