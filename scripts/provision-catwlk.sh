#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

set -a
source "${repo_root}/envs/production/.env.db"
source /etc/makepad/postgres/postgres.env
set +a

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

wait_for_postgres() {
  for _ in $(seq 1 30); do
    if docker compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "postgres did not become ready in time" >&2
  return 1
}

wait_for_postgres

prod_user_escaped="$(sql_escape "${MAKEPAD_CATWLK_PRODUCTION_USER}")"
prod_pass_escaped="$(sql_escape "${MAKEPAD_CATWLK_PRODUCTION_PASSWORD}")"
prod_db_escaped="$(sql_escape "${MAKEPAD_CATWLK_PRODUCTION_DB}")"
canary_user_escaped="$(sql_escape "${MAKEPAD_CATWLK_CANARY_USER}")"
canary_pass_escaped="$(sql_escape "${MAKEPAD_CATWLK_CANARY_PASSWORD}")"
canary_db_escaped="$(sql_escape "${MAKEPAD_CATWLK_CANARY_DB}")"

docker compose exec -T postgres env PGPASSWORD="${POSTGRES_PASSWORD}" \
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${prod_user_escaped}') THEN
    EXECUTE 'CREATE ROLE ${MAKEPAD_CATWLK_PRODUCTION_USER} LOGIN PASSWORD ''${prod_pass_escaped}''';
  ELSE
    EXECUTE 'ALTER ROLE ${MAKEPAD_CATWLK_PRODUCTION_USER} WITH LOGIN PASSWORD ''${prod_pass_escaped}''';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${MAKEPAD_CATWLK_PRODUCTION_DB} OWNER ${MAKEPAD_CATWLK_PRODUCTION_USER}'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = '${prod_db_escaped}'
)\gexec

ALTER DATABASE ${MAKEPAD_CATWLK_PRODUCTION_DB} OWNER TO ${MAKEPAD_CATWLK_PRODUCTION_USER};

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${canary_user_escaped}') THEN
    EXECUTE 'CREATE ROLE ${MAKEPAD_CATWLK_CANARY_USER} LOGIN PASSWORD ''${canary_pass_escaped}''';
  ELSE
    EXECUTE 'ALTER ROLE ${MAKEPAD_CATWLK_CANARY_USER} WITH LOGIN PASSWORD ''${canary_pass_escaped}''';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${MAKEPAD_CATWLK_CANARY_DB} OWNER ${MAKEPAD_CATWLK_CANARY_USER}'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = '${canary_db_escaped}'
)\gexec

ALTER DATABASE ${MAKEPAD_CATWLK_CANARY_DB} OWNER TO ${MAKEPAD_CATWLK_CANARY_USER};
SQL
