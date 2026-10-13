#!/bin/sh
set -eu

umask 077

backup_root=${RUNTRACE_BACKUP_ROOT:-/backups}
password_file=${POSTGRES_BACKUP_PASSWORD_FILE:-/run/secrets/postgres_backup_password}
retention_days=${RUNTRACE_BACKUP_RETENTION_DAYS:-35}
pg_host=${PGHOST:-makepad-postgres}
pg_port=${PGPORT:-5432}
pg_user=${PGUSER:-makepad_backup}

case "${retention_days}" in
  ''|*[!0-9]*)
    echo "RUNTRACE_BACKUP_RETENTION_DAYS must be a positive integer." >&2
    exit 1
    ;;
esac
if [ "${retention_days}" -lt 1 ]; then
  echo "RUNTRACE_BACKUP_RETENTION_DAYS must be at least 1." >&2
  exit 1
fi
if [ ! -s "${password_file}" ]; then
  echo "PostgreSQL backup credential file is missing or empty." >&2
  exit 1
fi

mkdir -p "${backup_root}"
chmod 700 "${backup_root}"
lock_dir=${backup_root}/.runtrace-backup.lock
if ! mkdir "${lock_dir}" 2>/dev/null; then
  echo "Another Runtrace PostgreSQL backup is already running." >&2
  exit 1
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
partial_dir=${backup_root}/.${timestamp}.partial
final_dir=${backup_root}/${timestamp}
pgpass=${backup_root}/.pgpass.${timestamp}
if [ -e "${final_dir}" ] || [ -L "${final_dir}" ]; then
  echo "Backup destination already exists for ${timestamp}." >&2
  exit 1
fi

cleanup() {
  if [ -d "${partial_dir}" ]; then
    find "${partial_dir}" -mindepth 1 -delete 2>/dev/null || true
    rmdir "${partial_dir}" 2>/dev/null || true
  fi
  if [ -f "${pgpass}" ]; then
    find "${pgpass}" -delete 2>/dev/null || true
  fi
  rmdir "${lock_dir}" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

password=$(tr -d '\r\n' < "${password_file}")
if [ -z "${password}" ]; then
  echo "PostgreSQL backup credential file contains no usable value." >&2
  exit 1
fi
escaped_password=$(printf '%s' "${password}" | sed 's/\\/\\\\/g; s/:/\\:/g')
printf '%s:%s:*:%s:%s\n' "${pg_host}" "${pg_port}" "${pg_user}" "${escaped_password}" > "${pgpass}"
unset password escaped_password
chmod 600 "${pgpass}"
export PGPASSFILE="${pgpass}"
export PGSSLMODE="${PGSSLMODE:-verify-full}"
export PGSSLROOTCERT="${PGSSLROOTCERT:-/etc/postgresql/ca.crt}"

mkdir "${partial_dir}"
databases='runtrace keycloak_runtrace amiary amiary_canary keycloak_amiary'
for database in ${databases}; do
  dump_path=${partial_dir}/${database}.dump
  pg_dump \
    --host="${pg_host}" \
    --port="${pg_port}" \
    --username="${pg_user}" \
    --role=makepad_backup_reader \
    --dbname="${database}" \
    --format=custom \
    --compress=9 \
    --file="${dump_path}"
  pg_restore --list "${dump_path}" >/dev/null
done

(
  cd "${partial_dir}"
  sha256sum runtrace.dump keycloak_runtrace.dump amiary.dump amiary_canary.dump keycloak_amiary.dump > SHA256SUMS
)
cat > "${partial_dir}/metadata.json" <<EOF
{"createdAt":"${timestamp}","databases":["runtrace","keycloak_runtrace","amiary","amiary_canary","keycloak_amiary"],"format":"postgres-custom","transport":"verify-full"}
EOF
chmod 600 "${partial_dir}"/*
mv "${partial_dir}" "${final_dir}"
if [ -e "${backup_root}/latest" ] && [ ! -L "${backup_root}/latest" ]; then
  echo "Backup latest marker exists but is not a symlink." >&2
  exit 1
fi
ln -sfn "${timestamp}" "${backup_root}/latest"

status_tmp=${backup_root}/.last-success.json.tmp
printf '{"createdAt":"%s","backup":"%s","databases":["runtrace","keycloak_runtrace","amiary","amiary_canary","keycloak_amiary"]}\n' "${timestamp}" "${timestamp}" > "${status_tmp}"
chmod 600 "${status_tmp}"
mv "${status_tmp}" "${backup_root}/last-success.json"

find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -name '20??????T??????Z' -mtime "+${retention_days}" -exec sh -c '
  for directory do
    find "$directory" -mindepth 1 -delete
    rmdir "$directory"
  done
' sh {} +

echo "Shared PostgreSQL backup completed: ${final_dir}"
