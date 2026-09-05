#!/bin/sh
set -eu

umask 077

database=${BRIO_BACKUP_DATABASE:?BRIO_BACKUP_DATABASE must be brio_staging or keycloak_brio_staging}
backup_root=${BRIO_BACKUP_ROOT:-/backups}
password_file=${POSTGRES_BACKUP_PASSWORD_FILE:-/run/secrets/postgres_backup_password}
recipient_cert=${BRIO_BACKUP_RECIPIENT_CERT:-/etc/postgresql/brio-backup-recipient.crt}
retention_days=${BRIO_BACKUP_RETENTION_DAYS:-35}
pg_host=${PGHOST:?PGHOST is required}
pg_port=${PGPORT:-5432}
pg_user=${PGUSER:?PGUSER must identify the database-specific Brio backup role}

case "${database}" in
  brio_staging) expected_pg_user=brio_staging_backup ;;
  keycloak_brio_staging) expected_pg_user=keycloak_brio_staging_backup ;;
  *)
    echo "BRIO_BACKUP_DATABASE must be brio_staging or keycloak_brio_staging." >&2
    exit 1
    ;;
esac
if [ "${pg_user}" != "${expected_pg_user}" ]; then
  echo "PGUSER must be ${expected_pg_user} when backing up ${database}." >&2
  exit 1
fi
case "${retention_days}" in
  ''|*[!0-9]*)
    echo "BRIO_BACKUP_RETENTION_DAYS must be a positive integer." >&2
    exit 1
    ;;
esac
if [ "${retention_days}" -ne 35 ]; then
  echo "Brio backup retention must remain exactly 35 days." >&2
  exit 1
fi
case "${pg_port}" in
  ''|*[!0-9]*)
    echo "PGPORT must be a positive integer." >&2
    exit 1
    ;;
esac
if [ "${pg_port}" -lt 1 ] || [ "${pg_port}" -gt 65535 ]; then
  echo "PGPORT must be between 1 and 65535." >&2
  exit 1
fi
case "${pg_host}" in
  ''|*[!A-Za-z0-9._-]*)
    echo "PGHOST contains unsupported characters." >&2
    exit 1
    ;;
esac
case "${pg_user}" in
  ''|*[!A-Za-z0-9._-]*)
    echo "PGUSER contains unsupported characters." >&2
    exit 1
    ;;
esac
case "${backup_root}" in
  ''|/)
    echo "BRIO_BACKUP_ROOT must identify a dedicated backup directory." >&2
    exit 1
    ;;
esac

for command_name in pg_dump openssl sha256sum mkfifo; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required backup command: ${command_name}" >&2
    exit 1
  fi
done
if [ ! -d "${backup_root}" ] || [ -L "${backup_root}" ]; then
  echo "BRIO_BACKUP_ROOT must be a pre-provisioned non-symlink directory." >&2
  exit 1
fi
chmod 0700 "${backup_root}"
if [ ! -s "${password_file}" ] || [ -L "${password_file}" ]; then
  echo "PostgreSQL backup credential must be a non-empty, non-symlink file." >&2
  exit 1
fi
if [ ! -s "${recipient_cert}" ] || [ -L "${recipient_cert}" ]; then
  echo "Brio backup recipient certificate must be a non-empty, non-symlink file." >&2
  exit 1
fi
if ! openssl x509 -in "${recipient_cert}" -noout -checkend 604800 >/dev/null 2>&1; then
  echo "Brio backup recipient certificate is invalid or expires in less than seven days." >&2
  exit 1
fi

lock_dir=/tmp/.brio-backup-${database}.lock
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Another Brio PostgreSQL backup is already running for ${database}." >&2
  exit 1
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
partial_dir=${backup_root}/.${timestamp}.partial
final_dir=${backup_root}/${timestamp}
encrypted_name=${database}.dump.cms
encrypted_path=${partial_dir}/${encrypted_name}
pipe_path=/tmp/brio-backup-${database}-${timestamp}-$$.pipe
pgpass=/tmp/brio-backup-${database}-${timestamp}-$$.pgpass
encrypt_pid=

cleanup() {
  if [ -n "${encrypt_pid}" ]; then
    kill "${encrypt_pid}" 2>/dev/null || true
    wait "${encrypt_pid}" 2>/dev/null || true
  fi
  if [ -p "${pipe_path}" ] || [ -f "${pipe_path}" ]; then
    rm -f "${pipe_path}"
  fi
  if [ -f "${pgpass}" ]; then
    rm -f "${pgpass}"
  fi
  if [ -d "${partial_dir}" ]; then
    find "${partial_dir}" -mindepth 1 -delete 2>/dev/null || true
    rmdir "${partial_dir}" 2>/dev/null || true
  fi
  rmdir "${lock_dir}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ -e "${final_dir}" ] || [ -L "${final_dir}" ] || [ -e "${partial_dir}" ] || [ -L "${partial_dir}" ]; then
  echo "Backup destination already exists for ${timestamp}." >&2
  exit 1
fi

password=$(tr -d '\r\n' < "${password_file}")
if [ -z "${password}" ]; then
  echo "PostgreSQL backup credential file contains no usable value." >&2
  exit 1
fi
escaped_password=$(printf '%s' "${password}" | sed 's/\\/\\\\/g; s/:/\\:/g')
printf '%s:%s:*:%s:%s\n' "${pg_host}" "${pg_port}" "${pg_user}" "${escaped_password}" > "${pgpass}"
unset password escaped_password
chmod 0600 "${pgpass}"
export PGPASSFILE="${pgpass}"
export PGSSLMODE="${PGSSLMODE:-verify-full}"
export PGSSLROOTCERT="${PGSSLROOTCERT:-/etc/postgresql/ca.crt}"
if [ "${PGSSLMODE}" != "verify-full" ]; then
  echo "Brio backups require PGSSLMODE=verify-full." >&2
  exit 1
fi

mkdir "${partial_dir}"
mkfifo -m 0600 "${pipe_path}"
openssl cms \
  -encrypt \
  -binary \
  -stream \
  -outform DER \
  -aes-256-gcm \
  -recip "${recipient_cert}" \
  -in "${pipe_path}" \
  -out "${encrypted_path}" &
encrypt_pid=$!

if pg_dump \
  --host="${pg_host}" \
  --port="${pg_port}" \
  --username="${pg_user}" \
  --dbname="${database}" \
  --format=custom \
  --compress=9 \
  --no-owner \
  --no-acl \
  > "${pipe_path}"; then
  dump_status=0
else
  dump_status=$?
fi

if wait "${encrypt_pid}"; then
  encrypt_status=0
else
  encrypt_status=$?
fi
encrypt_pid=
rm -f "${pipe_path}"

if [ "${dump_status}" -ne 0 ] || [ "${encrypt_status}" -ne 0 ]; then
  echo "Encrypted Brio backup failed before publication for ${database}." >&2
  exit 1
fi
if [ ! -s "${encrypted_path}" ]; then
  echo "Encrypted Brio backup output is empty." >&2
  exit 1
fi
if ! openssl cms -cmsout -inform DER -in "${encrypted_path}" -noout >/dev/null 2>&1; then
  echo "Encrypted Brio backup is not a valid CMS envelope." >&2
  exit 1
fi

recipient_fingerprint=$(openssl x509 -in "${recipient_cert}" -noout -fingerprint -sha256 | cut -d= -f2- | tr -d ':')
case "${recipient_fingerprint}" in
  ''|*[!A-Fa-f0-9]*)
    echo "Unable to derive the backup recipient certificate fingerprint." >&2
    exit 1
    ;;
esac
cat > "${partial_dir}/metadata.json" <<EOF
{"createdAt":"${timestamp}","database":"${database}","format":"postgres-custom","envelope":"openssl-cms-der","cipher":"aes-256-gcm","recipientCertificateSha256":"${recipient_fingerprint}","transport":"verify-full"}
EOF
(
  cd "${partial_dir}"
  sha256sum "${encrypted_name}" metadata.json > SHA256SUMS
)
chmod 0600 "${partial_dir}"/*
mv "${partial_dir}" "${final_dir}"

if [ -e "${backup_root}/latest" ] && [ ! -L "${backup_root}/latest" ]; then
  echo "Backup latest marker exists but is not a symlink." >&2
  exit 1
fi
ln -sfn "${timestamp}" "${backup_root}/latest"

status_tmp=${backup_root}/.last-success.json.tmp
printf '{"createdAt":"%s","backup":"%s","database":"%s","encrypted":true}\n' \
  "${timestamp}" "${timestamp}" "${database}" > "${status_tmp}"
chmod 0600 "${status_tmp}"
mv "${status_tmp}" "${backup_root}/last-success.json"

retention_find_days=$((retention_days - 1))
find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -name '20??????T??????Z' -mtime "+${retention_find_days}" -exec sh -c '
  for directory do
    find "$directory" -mindepth 1 -delete
    rmdir "$directory"
  done
' sh {} +

echo "Encrypted Brio PostgreSQL backup completed for ${database}: ${final_dir}"
