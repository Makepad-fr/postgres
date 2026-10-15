#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)
cleanup() { find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true; rmdir "${work_dir}" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "${work_dir}/bin" "${work_dir}/backups"
printf 'validation-password\n' > "${work_dir}/password"
chmod 600 "${work_dir}/password"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=betacrew-backup-test' \
  -keyout "${work_dir}/recipient.key" -out "${work_dir}/recipient.pem" >/dev/null 2>&1

cat > "${work_dir}/bin/pg_dump" <<'EOF'
#!/bin/sh
set -eu
for argument in "$@"; do
  case "${argument}" in --file=*) output=${argument#--file=} ;; --dbname=*) database=${argument#--dbname=} ;; esac
done
[ -n "${output:-}" ] && [ -n "${database:-}" ]
printf 'validated dump for %s\n' "${database}" > "${output}"
EOF
cat > "${work_dir}/bin/pg_restore" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = "--list" ] && [ -s "$2" ]
EOF
chmod 700 "${work_dir}/bin/pg_dump" "${work_dir}/bin/pg_restore"

PATH="${work_dir}/bin:${PATH}" BETACREW_BACKUP_ROOT="${work_dir}/backups" \
POSTGRES_SUPERUSER_PASSWORD_FILE="${work_dir}/password" \
BETACREW_BACKUP_ENCRYPTION_CERT="${work_dir}/recipient.pem" \
PGSSLROOTCERT="${work_dir}/unused-test-ca.crt" sh "${repo_root}/scripts/run-betacrew-backup.sh"

latest=$(readlink "${work_dir}/backups/latest")
backup_dir=${work_dir}/backups/${latest}
for expected in betacrew.dump.cms keycloak_betacrew.dump.cms SHA256SUMS metadata.json; do test -s "${backup_dir}/${expected}"; done
(cd "${backup_dir}" && sha256sum --check SHA256SUMS >/dev/null)
for database in betacrew keycloak_betacrew; do
  ! grep -a -q 'validated dump' "${backup_dir}/${database}.dump.cms"
  openssl cms -decrypt -binary -inform DER -in "${backup_dir}/${database}.dump.cms" \
    -recip "${work_dir}/recipient.pem" -inkey "${work_dir}/recipient.key" -out "${work_dir}/${database}.decrypted"
  grep -q "validated dump for ${database}" "${work_dir}/${database}.decrypted"
done
BETACREW_BACKUP_ROOT="${work_dir}/backups" BETACREW_BACKUP_INTERVAL_SECONDS=300 \
BETACREW_BACKUP_RETRY_SECONDS=30 sh "${repo_root}/scripts/run-betacrew-backup-loop.sh" healthcheck
echo "BetaCrew PostgreSQL encrypted backup contract passed."
