#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
require_literal() { grep -Fq -- "$2" "${repo_root}/$1" || { echo "Missing BetaCrew contract in $1: $2" >&2; exit 1; }; }

require_literal bootstrap/betacrew-databases.sql "pg_advisory_lock"
require_literal bootstrap/betacrew-databases.sql "CREATE DATABASE betacrew OWNER betacrew_app"
require_literal bootstrap/betacrew-databases.sql "CREATE DATABASE keycloak_betacrew OWNER keycloak_betacrew_app"
require_literal config/runtrace-pg_hba.conf "hostssl betacrew            betacrew_app         10.80.0.1/32"
require_literal config/runtrace-pg_hba.conf "hostssl keycloak_betacrew   keycloak_betacrew_app 88.99.209.165/32"
require_literal compose.host.yml "betacrew_backup:"
require_literal compose.host.yml "BETACREW_BACKUP_INTERVAL_SECONDS"
require_literal compose.host.yml "BETACREW_BACKUP_ENCRYPTION_CERT"
require_literal envs/production/.env.db "MAKEPAD_POSTGRES_BETACREW_BACKUP_INTERVAL_SECONDS=21600"
require_literal scripts/run-betacrew-backup.sh "-aes-256-gcm"
require_literal scripts/verify-betacrew-restore.sh "replace-nonproduction-restore-targets"
require_literal scripts/verify-betacrew-restore.sh "--single-transaction"
echo "BetaCrew PostgreSQL configuration is valid."
