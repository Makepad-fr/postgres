#!/usr/bin/env bash
# Disposable local cluster: never point this script at a shared server.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v initdb >/dev/null; then export PATH="/opt/homebrew/opt/postgresql@14/bin:$PATH"; fi
root=$(mktemp -d /tmp/visitaki-db.XXXXXX)
cleanup() { pg_ctl -D "$root/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$root"; }
trap cleanup EXIT
initdb -D "$root/data" -A trust -U postgres >"$root/init.log"
pg_ctl -D "$root/data" -l "$root/postgres.log" -o "-h '' -k '$root'" -w start >/dev/null
export PGHOST="$root" PGUSER=postgres PGDATABASE=postgres
for attempt in 1 2; do
  psql -X -q -v ON_ERROR_STOP=1 \
    -v visitaki_app_password=disposable-test-only-password-not-a-real-secret \
    -v keycloak_visitaki_app_password=disposable-test-only-identity-not-a-real-secret \
    -f bootstrap/visitaki.sql >"$root/bootstrap-$attempt.log"
done
[[ $(psql -XAtc "SELECT count(*) FROM pg_roles WHERE rolname IN ('visitaki_app','keycloak_visitaki_app') AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole") == 2 ]]
[[ $(psql -XAtc "SELECT has_database_privilege('visitaki_app','keycloak_visitaki','CONNECT') OR has_database_privilege('keycloak_visitaki_app','visitaki','CONNECT')") == f ]]
psql -X -q -d visitaki -c "SET ROLE visitaki_app; CREATE TABLE restore_probe(id text PRIMARY KEY); INSERT INTO restore_probe VALUES('visitaki-preview');"
pg_dump -Fc -d visitaki > "$root/visitaki.dump"
createdb visitaki_restore_test
pg_restore --exit-on-error --no-owner --no-acl -d visitaki_restore_test "$root/visitaki.dump"
[[ $(psql -XAt -d visitaki_restore_test -c 'SELECT id FROM restore_probe') == visitaki-preview ]]
echo 'Visitaki bootstrap is repeatable, roles are isolated, and a local backup restores.'
