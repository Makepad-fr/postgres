#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)

cleanup() {
  find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true
  rmdir "${work_dir}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p \
  "${work_dir}/bin" \
  "${work_dir}/backups/app" \
  "${work_dir}/backups/keycloak" \
  "${work_dir}/restore-tmp"
chmod 0700 "${work_dir}/backups/app" "${work_dir}/backups/keycloak" "${work_dir}/restore-tmp"
printf 'validation-password\n' > "${work_dir}/password"
printf '[brio_app_restore_test]\nhost=nonproduction.invalid\n\n[brio_keycloak_restore_test]\nhost=nonproduction.invalid\n' > "${work_dir}/pg_service.conf"
chmod 0600 "${work_dir}/password" "${work_dir}/pg_service.conf"

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -days 30 \
  -subj /CN=brio-restore-contract \
  -keyout "${work_dir}/recipient.key" \
  -out "${work_dir}/recipient.crt" >/dev/null 2>&1
chmod 0600 "${work_dir}/recipient.key"

cat > "${work_dir}/bin/pg_dump" <<'EOF'
#!/bin/sh
set -eu
database=
for argument in "$@"; do
  case "${argument}" in
    --dbname=*) database=${argument#--dbname=} ;;
  esac
done
printf 'fake custom dump for %s\n' "${database}"
EOF

cat > "${work_dir}/bin/pg_restore" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = "--list" ]; then
  grep -Fq 'fake custom dump for ' "$2"
  exit 0
fi
joined=" $* "
last_argument=
for argument in "$@"; do
  last_argument=${argument}
done
for expected in '--clean' '--if-exists' '--no-owner' '--no-acl' '--exit-on-error' '--single-transaction'; do
  case "${joined}" in
    *" ${expected} "*) ;;
    *) echo "missing restore flag: ${expected}" >&2; exit 1 ;;
  esac
done
case "${joined}" in
  *' --dbname=service=brio_app_restore_test '*) grep -Fq 'fake custom dump for brio_staging' "${last_argument}" ;;
  *' --dbname=service=brio_keycloak_restore_test '*) grep -Fq 'fake custom dump for keycloak_brio_staging' "${last_argument}" ;;
  *) echo "unexpected restore service" >&2; exit 1 ;;
esac
printf '%s\n' "$*" >> "${RESTORE_LOG}"
EOF

cat > "${work_dir}/bin/psql" <<'EOF'
#!/bin/sh
set -eu
case " $* " in
  *' service=brio_app_restore_test '*) database=brio_app_restore_test ;;
  *' service=brio_keycloak_restore_test '*) database=brio_keycloak_restore_test ;;
  *) echo "unexpected psql service" >&2; exit 1 ;;
esac
case " $* " in
  *'SELECT current_database();'*) printf '%s\n' "${FAKE_RESTORE_DATABASE:-${database}}" ;;
  *) printf 't\n' ;;
esac
EOF
chmod 0700 "${work_dir}/bin/pg_dump" "${work_dir}/bin/pg_restore" "${work_dir}/bin/psql"

create_bundle() {
  local database=$1
  local root=$2
  local backup_user
  case "${database}" in
    brio_staging) backup_user=brio_staging_backup ;;
    keycloak_brio_staging) backup_user=keycloak_brio_staging_backup ;;
    *) return 1 ;;
  esac
  PATH="${work_dir}/bin:${PATH}" \
  BRIO_BACKUP_DATABASE="${database}" \
  BRIO_BACKUP_ROOT="${root}" \
  BRIO_BACKUP_RECIPIENT_CERT="${work_dir}/recipient.crt" \
  BRIO_BACKUP_RETENTION_DAYS=35 \
  POSTGRES_BACKUP_PASSWORD_FILE="${work_dir}/password" \
  PGHOST=makepad-postgres \
  PGPORT=5432 \
  PGUSER="${backup_user}" \
  PGSSLMODE=verify-full \
  PGSSLROOTCERT="${work_dir}/unused-test-ca.crt" \
  sh "${repo_root}/scripts/run-brio-encrypted-backup.sh" >/dev/null
}

create_bundle brio_staging "${work_dir}/backups/app"
create_bundle keycloak_brio_staging "${work_dir}/backups/keycloak"
app_backup=${work_dir}/backups/app/$(readlink "${work_dir}/backups/app/latest")
keycloak_backup=${work_dir}/backups/keycloak/$(readlink "${work_dir}/backups/keycloak/latest")

if PATH="${work_dir}/bin:${PATH}" \
  PGSERVICEFILE="${work_dir}/pg_service.conf" \
  BRIO_APP_RESTORE_SERVICE=brio_app_restore_test \
  BRIO_KEYCLOAK_RESTORE_SERVICE=brio_keycloak_restore_test \
  BRIO_RESTORE_RECIPIENT_CERT="${work_dir}/recipient.crt" \
  BRIO_RESTORE_RECIPIENT_KEY="${work_dir}/recipient.key" \
  BRIO_RESTORE_TEMP_ROOT="${work_dir}/restore-tmp" \
  BRIO_RESTORE_CONFIRM=wrong-confirmation \
  bash "${repo_root}/scripts/verify-brio-encrypted-restore.sh" "${app_backup}" "${keycloak_backup}"; then
  echo "Restore unexpectedly accepted an invalid destructive confirmation." >&2
  exit 1
fi

if PATH="${work_dir}/bin:${PATH}" \
  FAKE_RESTORE_DATABASE=brio_staging \
  PGSERVICEFILE="${work_dir}/pg_service.conf" \
  BRIO_APP_RESTORE_SERVICE=brio_app_restore_test \
  BRIO_KEYCLOAK_RESTORE_SERVICE=brio_keycloak_restore_test \
  BRIO_RESTORE_RECIPIENT_CERT="${work_dir}/recipient.crt" \
  BRIO_RESTORE_RECIPIENT_KEY="${work_dir}/recipient.key" \
  BRIO_RESTORE_TEMP_ROOT="${work_dir}/restore-tmp" \
  BRIO_RESTORE_CONFIRM=replace-nonproduction-brio-restore-targets \
  bash "${repo_root}/scripts/verify-brio-encrypted-restore.sh" "${app_backup}" "${keycloak_backup}"; then
  echo "Restore unexpectedly accepted a production-shaped database target." >&2
  exit 1
fi

export RESTORE_LOG=${work_dir}/restore.log
PATH="${work_dir}/bin:${PATH}" \
PGSERVICEFILE="${work_dir}/pg_service.conf" \
BRIO_APP_RESTORE_SERVICE=brio_app_restore_test \
BRIO_KEYCLOAK_RESTORE_SERVICE=brio_keycloak_restore_test \
BRIO_RESTORE_RECIPIENT_CERT="${work_dir}/recipient.crt" \
BRIO_RESTORE_RECIPIENT_KEY="${work_dir}/recipient.key" \
BRIO_RESTORE_TEMP_ROOT="${work_dir}/restore-tmp" \
BRIO_RESTORE_CONFIRM=replace-nonproduction-brio-restore-targets \
bash "${repo_root}/scripts/verify-brio-encrypted-restore.sh" "${app_backup}" "${keycloak_backup}"

test "$(wc -l < "${RESTORE_LOG}" | tr -d ' ')" = "2"
test -z "$(find "${work_dir}/restore-tmp" -mindepth 1 -print -quit)"

echo "Brio encrypted PostgreSQL restore contract passed."
