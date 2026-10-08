#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)

cleanup() {
  find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true
  rmdir "${work_dir}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${work_dir}/bin" "${work_dir}/backups/app" "${work_dir}/backups/failure"
chmod 0700 "${work_dir}/backups/app" "${work_dir}/backups/failure"
mkdir "${work_dir}/backups/app/20200101T000000Z" "${work_dir}/backups/app/20990101T000000Z"
touch -t 202001010000 "${work_dir}/backups/app/20200101T000000Z"
printf 'validation-password\n' > "${work_dir}/password"
chmod 0600 "${work_dir}/password"

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -days 30 \
  -subj /CN=brio-backup-contract \
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
    --file=*)
      echo "Brio backup must stream pg_dump and never write a plaintext file." >&2
      exit 91
      ;;
  esac
done
[ "${database}" = "brio_staging" ] || [ "${database}" = "keycloak_brio_staging" ]
printf 'contract plaintext for %s\n' "${database}"
if [ "${FAKE_PG_DUMP_FAIL:-0}" = "1" ]; then
  exit 42
fi
EOF
chmod 0700 "${work_dir}/bin/pg_dump"

PATH="${work_dir}/bin:${PATH}" \
BRIO_BACKUP_DATABASE=brio_staging \
BRIO_BACKUP_ROOT="${work_dir}/backups/app" \
BRIO_BACKUP_RECIPIENT_CERT="${work_dir}/recipient.crt" \
BRIO_BACKUP_RETENTION_DAYS=35 \
POSTGRES_BACKUP_PASSWORD_FILE="${work_dir}/password" \
PGHOST=makepad-postgres-brio-staging \
PGPORT=5432 \
PGUSER=brio_staging_backup \
PGSSLMODE=verify-full \
PGSSLROOTCERT="${work_dir}/unused-test-ca.crt" \
sh "${repo_root}/scripts/run-brio-encrypted-backup.sh"

latest=$(readlink "${work_dir}/backups/app/latest")
backup_dir=${work_dir}/backups/app/${latest}
for expected in brio_staging.dump.cms SHA256SUMS metadata.json; do
  test -s "${backup_dir}/${expected}"
done
test ! -e "${backup_dir}/brio_staging.dump"
if grep -aFq 'contract plaintext' "${backup_dir}/brio_staging.dump.cms"; then
  echo "Encrypted artifact exposed plaintext backup content." >&2
  exit 1
fi
(
  cd "${backup_dir}"
  sha256sum --check --strict SHA256SUMS >/dev/null
)
openssl cms \
  -decrypt \
  -binary \
  -inform DER \
  -recip "${work_dir}/recipient.crt" \
  -inkey "${work_dir}/recipient.key" \
  -in "${backup_dir}/brio_staging.dump.cms" \
  -out "${work_dir}/decrypted.dump"
grep -Fq 'contract plaintext for brio_staging' "${work_dir}/decrypted.dump"
test -s "${work_dir}/backups/app/last-success.json"
test ! -e "${work_dir}/backups/app/20200101T000000Z"
test -d "${work_dir}/backups/app/20990101T000000Z"

BRIO_BACKUP_ROOT="${work_dir}/backups/app" \
BRIO_BACKUP_INTERVAL_SECONDS=300 \
BRIO_BACKUP_RETRY_SECONDS=30 \
sh "${repo_root}/scripts/run-brio-encrypted-backup-loop.sh" healthcheck

if PATH="${work_dir}/bin:${PATH}" \
  FAKE_PG_DUMP_FAIL=1 \
  BRIO_BACKUP_DATABASE=keycloak_brio_staging \
  BRIO_BACKUP_ROOT="${work_dir}/backups/failure" \
  BRIO_BACKUP_RECIPIENT_CERT="${work_dir}/recipient.crt" \
  BRIO_BACKUP_RETENTION_DAYS=35 \
  POSTGRES_BACKUP_PASSWORD_FILE="${work_dir}/password" \
  PGHOST=makepad-postgres \
  PGPORT=5432 \
  PGUSER=keycloak_brio_staging_backup \
  PGSSLMODE=verify-full \
  PGSSLROOTCERT="${work_dir}/unused-test-ca.crt" \
  sh "${repo_root}/scripts/run-brio-encrypted-backup.sh"; then
  echo "A failing pg_dump unexpectedly published a Brio backup." >&2
  exit 1
fi
if find "${work_dir}/backups/failure" -mindepth 1 -maxdepth 1 -type d -name '20??????T??????Z' | grep -q .; then
  echo "A failing pg_dump left a published timestamp directory." >&2
  exit 1
fi
if find "${work_dir}/backups/failure" -type f -name '*.dump' -o -name '*.dump.cms' | grep -q .; then
  echo "A failing pg_dump left a backup artifact." >&2
  exit 1
fi

if PATH="${work_dir}/bin:${PATH}" \
  BRIO_BACKUP_DATABASE=brio_staging \
  BRIO_BACKUP_ROOT="${work_dir}/backups/failure" \
  BRIO_BACKUP_RECIPIENT_CERT="${work_dir}/recipient.crt" \
  POSTGRES_BACKUP_PASSWORD_FILE="${work_dir}/password" \
  PGHOST=makepad-postgres-brio-staging \
  PGUSER=postgres \
  sh "${repo_root}/scripts/run-brio-encrypted-backup.sh"; then
  echo "The PostgreSQL superuser unexpectedly passed Brio backup validation." >&2
  exit 1
fi

if PATH="${work_dir}/bin:${PATH}" \
  BRIO_BACKUP_DATABASE=unexpected_database \
  BRIO_BACKUP_ROOT="${work_dir}/backups/failure" \
  BRIO_BACKUP_RECIPIENT_CERT="${work_dir}/recipient.crt" \
  POSTGRES_BACKUP_PASSWORD_FILE="${work_dir}/password" \
  PGHOST=makepad-postgres \
  sh "${repo_root}/scripts/run-brio-encrypted-backup.sh"; then
  echo "An unallowlisted database unexpectedly passed backup validation." >&2
  exit 1
fi

echo "Brio encrypted PostgreSQL backup contract passed."
