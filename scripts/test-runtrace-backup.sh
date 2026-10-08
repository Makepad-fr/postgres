#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)

cleanup() {
  find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true
  rmdir "${work_dir}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${work_dir}/bin" "${work_dir}/backups"
printf 'validation-password\n' > "${work_dir}/password"
chmod 600 "${work_dir}/password"

cat > "${work_dir}/bin/pg_dump" <<'EOF'
#!/bin/sh
set -eu
output=
database=
for argument in "$@"; do
  case "${argument}" in
    --file=*) output=${argument#--file=} ;;
    --dbname=*) database=${argument#--dbname=} ;;
  esac
done
[ -n "${output}" ] && [ -n "${database}" ]
printf 'validated dump for %s\n' "${database}" > "${output}"
EOF
cat > "${work_dir}/bin/pg_restore" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = "--list" ]
[ -s "$2" ]
EOF
chmod 700 "${work_dir}/bin/pg_dump" "${work_dir}/bin/pg_restore"

PATH="${work_dir}/bin:${PATH}" \
RUNTRACE_BACKUP_ROOT="${work_dir}/backups" \
POSTGRES_SUPERUSER_PASSWORD_FILE="${work_dir}/password" \
PGSSLROOTCERT="${work_dir}/unused-test-ca.crt" \
sh "${repo_root}/scripts/run-runtrace-backup.sh"

latest=$(readlink "${work_dir}/backups/latest")
backup_dir=${work_dir}/backups/${latest}
for expected in runtrace.dump keycloak_runtrace.dump SHA256SUMS metadata.json; do
  test -s "${backup_dir}/${expected}"
done
(
  cd "${backup_dir}"
  sha256sum --check SHA256SUMS >/dev/null
)
test -s "${work_dir}/backups/last-success.json"

RUNTRACE_BACKUP_ROOT="${work_dir}/backups" \
RUNTRACE_BACKUP_INTERVAL_SECONDS=300 \
RUNTRACE_BACKUP_RETRY_SECONDS=30 \
sh "${repo_root}/scripts/run-runtrace-backup-loop.sh" healthcheck

echo "Runtrace PostgreSQL backup contract passed."
