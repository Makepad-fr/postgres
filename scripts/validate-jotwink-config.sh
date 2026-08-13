#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

require_literal() {
  local file=$1
  local literal=$2
  grep -Fq -- "${literal}" "${repo_root}/${file}" || {
    echo "Missing Jotwink contract in ${file}: ${literal}" >&2
    exit 1
  }
}

for literal in \
  "jotwink_app_password" \
  "keycloak_jotwink_app_password" \
  "CREATE DATABASE jotwink OWNER jotwink_app" \
  "CREATE DATABASE keycloak_jotwink OWNER keycloak_jotwink_app" \
  "pg_advisory_lock" \
  "pg_advisory_unlock"; do
  require_literal bootstrap/jotwink-databases.sql "${literal}"
done

require_literal config/runtrace-pg_hba.conf "hostnossl jotwink"
require_literal config/runtrace-pg_hba.conf "hostnossl keycloak_jotwink"
require_literal config/runtrace-pg_hba.conf "hostssl jotwink             jotwink_app         10.80.0.1/32"
require_literal config/runtrace-pg_hba.conf "hostssl keycloak_jotwink    keycloak_jotwink_app 88.99.209.165/32"
require_literal compose.host.yml "jotwink_backup:"
require_literal compose.host.yml "JOTWINK_BACKUP_INTERVAL_SECONDS"
require_literal compose.host.yml "JOTWINK_BACKUP_ENCRYPTION_CERT"
require_literal compose.host.yml "no-new-privileges:true"
require_literal compose.yml "jotwink_backup_script:"
require_literal compose.yml "jotwink_backup_loop_script:"
require_literal envs/production/compose.yml "jotwink_backup:"
require_literal envs/production/compose.yml "JOTWINK_BACKUP_INTERVAL_SECONDS"
require_literal envs/production/compose.yml "jotwink_backup_encryption_cert:"
require_literal .github/workflows/manual-deploy.yml "cp scripts/run-jotwink-backup.sh"
require_literal .github/workflows/manual-deploy.yml "cp scripts/run-jotwink-backup-loop.sh"
require_literal .github/workflows/manual-deploy.yml "jotwink_backup_directory_mode"
require_literal .github/workflows/manual-deploy.yml "jotwink_backup_password_mode"
require_literal .github/workflows/manual-deploy.yml "jotwink_backup_encryption_cert_config"
require_literal envs/production/.env.db "MAKEPAD_POSTGRES_JOTWINK_BACKUP_INTERVAL_SECONDS=21600"
require_literal envs/production/.env.db "MAKEPAD_POSTGRES_JOTWINK_BACKUP_ENCRYPTION_CERT_CONFIG="
require_literal scripts/verify-jotwink-restore.sh "replace-nonproduction-restore-targets"
require_literal scripts/verify-jotwink-restore.sh "--single-transaction"
require_literal scripts/run-jotwink-backup.sh "-aes-256-gcm"
require_literal scripts/run-jotwink-backup.sh "mktemp -d"

if grep -Eq 'postgres://(jotwink_app|keycloak_jotwink_app):[^[:space:]]*sslmode=disable' "${repo_root}/README.md"; then
  echo "README must not document plaintext-capable Jotwink database URLs." >&2
  exit 1
fi

echo "Jotwink PostgreSQL configuration is valid."
