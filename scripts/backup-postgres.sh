#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

set -a
source "${repo_root}/envs/production/.env.db"
source /etc/makepad/postgres/postgres.env
source /etc/makepad/backups/restic-postgres.env
set +a

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_root="${MAKEPAD_POSTGRES_BACKUP_PATH}/${timestamp}"
mkdir -p "${backup_root}"

docker compose exec -T postgres env PGPASSWORD="${POSTGRES_PASSWORD}" \
  pg_dump -Fc -U "${POSTGRES_USER}" "${MAKEPAD_CATWLK_PRODUCTION_DB}" \
  > "${backup_root}/catwlk-production.dump"

docker compose exec -T postgres env PGPASSWORD="${POSTGRES_PASSWORD}" \
  pg_dump -Fc -U "${POSTGRES_USER}" "${MAKEPAD_CATWLK_CANARY_DB}" \
  > "${backup_root}/catwlk-canary.dump"

docker compose exec -T postgres env PGPASSWORD="${POSTGRES_PASSWORD}" \
  pg_dumpall --globals-only -U "${POSTGRES_USER}" \
  > "${backup_root}/globals.sql"

restic backup "${backup_root}"
restic forget --prune \
  --keep-daily "${MAKEPAD_POSTGRES_RETENTION_DAILY:-30}" \
  --keep-monthly "${MAKEPAD_POSTGRES_RETENTION_MONTHLY:-12}"

find "${MAKEPAD_POSTGRES_BACKUP_PATH}" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +
