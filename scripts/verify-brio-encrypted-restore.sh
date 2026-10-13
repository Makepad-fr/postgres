#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <brio-app-backup-directory> <brio-keycloak-backup-directory>" >&2
  exit 2
fi

app_backup_dir=$1
keycloak_backup_dir=$2
: "${PGSERVICEFILE:?PGSERVICEFILE must identify a protected libpq service file}"
: "${BRIO_APP_RESTORE_SERVICE:?BRIO_APP_RESTORE_SERVICE must name an explicit non-production database}"
: "${BRIO_KEYCLOAK_RESTORE_SERVICE:?BRIO_KEYCLOAK_RESTORE_SERVICE must name an explicit non-production database}"
: "${BRIO_RESTORE_RECIPIENT_CERT:?BRIO_RESTORE_RECIPIENT_CERT must identify the external recipient certificate}"
: "${BRIO_RESTORE_RECIPIENT_KEY:?BRIO_RESTORE_RECIPIENT_KEY must identify the external recipient private key}"
: "${BRIO_RESTORE_TEMP_ROOT:?BRIO_RESTORE_TEMP_ROOT must identify a mode-0700 temporary storage directory}"
: "${BRIO_RESTORE_CONFIRM:?set BRIO_RESTORE_CONFIRM=replace-nonproduction-brio-restore-targets}"

if [[ "${BRIO_RESTORE_CONFIRM}" != "replace-nonproduction-brio-restore-targets" ]]; then
  echo "Brio restore verification requires explicit non-production replacement confirmation." >&2
  exit 1
fi
if [[ "${BRIO_APP_RESTORE_SERVICE}" == "${BRIO_KEYCLOAK_RESTORE_SERVICE}" ]]; then
  echo "Brio application and Keycloak restore services must be different." >&2
  exit 1
fi
for service_name in "${BRIO_APP_RESTORE_SERVICE}" "${BRIO_KEYCLOAK_RESTORE_SERVICE}"; do
  if [[ ! "${service_name}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "Restore service names contain unsupported characters." >&2
    exit 1
  fi
  if [[ "${service_name}" != *_restore_test ]]; then
    echo "Restore service names must end in _restore_test." >&2
    exit 1
  fi
done
for command_name in openssl sha256sum pg_restore psql mktemp; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required restore command: ${command_name}" >&2
    exit 1
  fi
done

validate_protected_file() {
  local path=$1
  local label=$2
  if [[ ! -s "${path}" || -L "${path}" ]]; then
    echo "${label} must be a non-empty, non-symlink file." >&2
    exit 1
  fi
  local mode
  mode=$(stat -c '%a' "${path}" 2>/dev/null || stat -f '%Lp' "${path}")
  if (( (8#${mode} & 8#022) != 0 )); then
    echo "${label} must not be group- or world-writable." >&2
    exit 1
  fi
}

validate_protected_file "${PGSERVICEFILE}" "PGSERVICEFILE"
validate_protected_file "${BRIO_RESTORE_RECIPIENT_CERT}" "Brio restore recipient certificate"
validate_protected_file "${BRIO_RESTORE_RECIPIENT_KEY}" "Brio restore recipient private key"
service_file_mode=$(stat -c '%a' "${PGSERVICEFILE}" 2>/dev/null || stat -f '%Lp' "${PGSERVICEFILE}")
if (( (8#${service_file_mode} & 8#077) != 0 )); then
  echo "PGSERVICEFILE must not be accessible to group or other users." >&2
  exit 1
fi
key_mode=$(stat -c '%a' "${BRIO_RESTORE_RECIPIENT_KEY}" 2>/dev/null || stat -f '%Lp' "${BRIO_RESTORE_RECIPIENT_KEY}")
if (( (8#${key_mode} & 8#077) != 0 )); then
  echo "Brio restore recipient private key must not be accessible to group or other users." >&2
  exit 1
fi
if [[ ! -d "${BRIO_RESTORE_TEMP_ROOT}" || -L "${BRIO_RESTORE_TEMP_ROOT}" ]]; then
  echo "BRIO_RESTORE_TEMP_ROOT must be a pre-provisioned non-symlink directory." >&2
  exit 1
fi
temp_mode=$(stat -c '%a' "${BRIO_RESTORE_TEMP_ROOT}" 2>/dev/null || stat -f '%Lp' "${BRIO_RESTORE_TEMP_ROOT}")
if [[ "${temp_mode}" != "700" ]]; then
  echo "BRIO_RESTORE_TEMP_ROOT must have mode 0700." >&2
  exit 1
fi
temp_owner=$(stat -c '%u' "${BRIO_RESTORE_TEMP_ROOT}" 2>/dev/null || stat -f '%u' "${BRIO_RESTORE_TEMP_ROOT}")
if [[ "${temp_owner}" != "$(id -u)" ]]; then
  echo "BRIO_RESTORE_TEMP_ROOT must be owned by the restore operator." >&2
  exit 1
fi

cert_public_key=$(openssl x509 -in "${BRIO_RESTORE_RECIPIENT_CERT}" -pubkey -noout \
  | openssl pkey -pubin -outform DER 2>/dev/null \
  | sha256sum | awk '{print $1}')
private_public_key=$(openssl pkey -in "${BRIO_RESTORE_RECIPIENT_KEY}" -pubout -outform DER 2>/dev/null \
  | sha256sum | awk '{print $1}')
if [[ -z "${cert_public_key}" || "${cert_public_key}" != "${private_public_key}" ]]; then
  echo "Brio restore recipient certificate and private key do not match." >&2
  exit 1
fi

validate_bundle() {
  local backup_dir=$1
  local database=$2
  local encrypted_name=${database}.dump.cms
  if [[ ! -d "${backup_dir}" || -L "${backup_dir}" ]]; then
    echo "Backup directory must be a regular directory and not a symlink: ${backup_dir}" >&2
    exit 1
  fi
  for required in "${encrypted_name}" SHA256SUMS metadata.json; do
    if [[ ! -s "${backup_dir}/${required}" || -L "${backup_dir}/${required}" ]]; then
      echo "Encrypted backup artifact is missing, empty, or a symlink: ${required}" >&2
      exit 1
    fi
  done
  (
    cd "${backup_dir}"
    sha256sum --check --strict SHA256SUMS
  )
  if ! grep -Fq "\"database\":\"${database}\"" "${backup_dir}/metadata.json" \
    || ! grep -Fq '"envelope":"openssl-cms-der"' "${backup_dir}/metadata.json" \
    || ! grep -Fq '"cipher":"aes-256-gcm"' "${backup_dir}/metadata.json"; then
    echo "Encrypted backup metadata does not match ${database}." >&2
    exit 1
  fi
  if ! openssl cms -cmsout -inform DER -in "${backup_dir}/${encrypted_name}" -noout >/dev/null 2>&1; then
    echo "Encrypted backup is not a valid CMS envelope for ${database}." >&2
    exit 1
  fi
}

validate_bundle "${app_backup_dir}" brio_staging
validate_bundle "${keycloak_backup_dir}" keycloak_brio_staging

restore_dir=$(mktemp -d "${BRIO_RESTORE_TEMP_ROOT%/}/brio-restore.XXXXXX")
chmod 0700 "${restore_dir}"
cleanup() {
  find "${restore_dir}" -mindepth 1 -delete 2>/dev/null || true
  rmdir "${restore_dir}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

decrypt_bundle() {
  local backup_dir=$1
  local database=$2
  local output=$3
  openssl cms \
    -decrypt \
    -binary \
    -inform DER \
    -recip "${BRIO_RESTORE_RECIPIENT_CERT}" \
    -inkey "${BRIO_RESTORE_RECIPIENT_KEY}" \
    -in "${backup_dir}/${database}.dump.cms" \
    -out "${output}"
  chmod 0600 "${output}"
  pg_restore --list "${output}" >/dev/null
}

app_dump=${restore_dir}/brio_staging.dump
keycloak_dump=${restore_dir}/keycloak_brio_staging.dump
decrypt_bundle "${app_backup_dir}" brio_staging "${app_dump}"
decrypt_bundle "${keycloak_backup_dir}" keycloak_brio_staging "${keycloak_dump}"

restore_dump() {
  local service=$1
  local dump=$2
  local database
  database=$(psql "service=${service}" -v ON_ERROR_STOP=1 -Atc "SELECT current_database();")
  if [[ "${database}" != *_restore_test ]]; then
    echo "Restore service ${service} resolved to a database without the _restore_test suffix." >&2
    exit 1
  fi
  pg_restore \
    --dbname="service=${service}" \
    --clean \
    --if-exists \
    --no-owner \
    --no-acl \
    --exit-on-error \
    --single-transaction \
    "${dump}"
}

restore_dump "${BRIO_APP_RESTORE_SERVICE}" "${app_dump}"
restore_dump "${BRIO_KEYCLOAK_RESTORE_SERVICE}" "${keycloak_dump}"

app_state=$(psql "service=${BRIO_APP_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('public.schema_migrations') IS NOT NULL AND to_regclass('public.communities') IS NOT NULL;")
keycloak_state=$(psql "service=${BRIO_KEYCLOAK_RESTORE_SERVICE}" -v ON_ERROR_STOP=1 -Atc \
  "SELECT to_regclass('public.realm') IS NOT NULL;")
if [[ "${app_state}" != "t" || "${keycloak_state}" != "t" ]]; then
  echo "Restored databases are missing Brio or Keycloak durable state tables." >&2
  exit 1
fi

echo "Brio application and Keycloak encrypted restore verification completed against non-production targets."
