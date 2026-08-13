#!/bin/sh
set -eu

umask 077

backup_root=${BETACREW_BACKUP_ROOT:-/backups}
password_file=${POSTGRES_SUPERUSER_PASSWORD_FILE:-/run/secrets/postgres_superuser_password}
encryption_cert=${BETACREW_BACKUP_ENCRYPTION_CERT:-/run/config/betacrew_backup_recipient.pem}
retention_days=${BETACREW_BACKUP_RETENTION_DAYS:-35}
pg_host=${PGHOST:-127.0.0.1}
pg_port=${PGPORT:-5432}
pg_user=${PGUSER:-postgres}

case "${retention_days}" in
  ''|*[!0-9]*) echo "BETACREW_BACKUP_RETENTION_DAYS must be a positive integer." >&2; exit 1 ;;
esac
[ "${retention_days}" -ge 1 ] || { echo "BETACREW_BACKUP_RETENTION_DAYS must be at least 1." >&2; exit 1; }
[ -s "${password_file}" ] || { echo "PostgreSQL backup credential file is missing or empty." >&2; exit 1; }
[ -s "${encryption_cert}" ] || { echo "BetaCrew backup encryption certificate is missing or empty." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required to encrypt BetaCrew backups." >&2; exit 1; }
openssl x509 -in "${encryption_cert}" -noout >/dev/null 2>&1 || { echo "BetaCrew backup certificate is invalid." >&2; exit 1; }

mkdir -p "${backup_root}"
chmod 700 "${backup_root}"
lock_dir=${backup_root}/.betacrew-backup.lock
mkdir "${lock_dir}" 2>/dev/null || { echo "Another BetaCrew backup is running." >&2; exit 1; }

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
partial_dir=${backup_root}/.${timestamp}.partial
final_dir=${backup_root}/${timestamp}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/betacrew-backup.${timestamp}.XXXXXX")
pgpass=${work_dir}/.pgpass

cleanup() {
  if [ -d "${partial_dir}" ]; then find "${partial_dir}" -mindepth 1 -delete 2>/dev/null || true; rmdir "${partial_dir}" 2>/dev/null || true; fi
  if [ -d "${work_dir}" ]; then find "${work_dir}" -mindepth 1 -delete 2>/dev/null || true; rmdir "${work_dir}" 2>/dev/null || true; fi
  rmdir "${lock_dir}" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

[ ! -e "${final_dir}" ] && [ ! -L "${final_dir}" ] || { echo "Backup destination already exists." >&2; exit 1; }
password=$(tr -d '\r\n' < "${password_file}")
[ -n "${password}" ] || { echo "PostgreSQL backup credential contains no usable value." >&2; exit 1; }
escaped_password=$(printf '%s' "${password}" | sed 's/\\/\\\\/g; s/:/\\:/g')
printf '%s:%s:*:%s:%s\n' "${pg_host}" "${pg_port}" "${pg_user}" "${escaped_password}" > "${pgpass}"
unset password escaped_password
chmod 600 "${pgpass}"
export PGPASSFILE="${pgpass}"
export PGSSLMODE="${PGSSLMODE:-verify-full}"
export PGSSLROOTCERT="${PGSSLROOTCERT:-/etc/postgresql/ca.crt}"

mkdir "${partial_dir}"
for database in betacrew keycloak_betacrew; do
  dump_path=${work_dir}/${database}.dump
  encrypted_path=${partial_dir}/${database}.dump.cms
  pg_dump --host="${pg_host}" --port="${pg_port}" --username="${pg_user}" --dbname="${database}" \
    --format=custom --compress=9 --no-owner --no-acl --file="${dump_path}"
  pg_restore --list "${dump_path}" >/dev/null
  openssl cms -encrypt -binary -outform DER -aes-256-gcm -in "${dump_path}" -out "${encrypted_path}" "${encryption_cert}"
  openssl cms -cmsout -inform DER -in "${encrypted_path}" -noout >/dev/null
  find "${dump_path}" -delete
done

(cd "${partial_dir}" && sha256sum betacrew.dump.cms keycloak_betacrew.dump.cms > SHA256SUMS)
cat > "${partial_dir}/metadata.json" <<EOF
{"createdAt":"${timestamp}","databases":["betacrew","keycloak_betacrew"],"format":"postgres-custom+openssl-cms-aes-256-gcm","transport":"verify-full"}
EOF
chmod 600 "${partial_dir}"/*
mv "${partial_dir}" "${final_dir}"
[ ! -e "${backup_root}/latest" ] || [ -L "${backup_root}/latest" ] || { echo "Backup latest marker is not a symlink." >&2; exit 1; }
ln -sfn "${timestamp}" "${backup_root}/latest"
status_tmp=${backup_root}/.last-success.json.tmp
printf '{"createdAt":"%s","backup":"%s","databases":["betacrew","keycloak_betacrew"]}\n' "${timestamp}" "${timestamp}" > "${status_tmp}"
chmod 600 "${status_tmp}"
mv "${status_tmp}" "${backup_root}/last-success.json"

find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -name '20??????T??????Z' -mtime "+${retention_days}" -exec sh -c '
  for directory do find "$directory" -mindepth 1 -delete; rmdir "$directory"; done
' sh {} +

echo "BetaCrew PostgreSQL backup completed: ${final_dir}"
