#!/usr/bin/env bash
set -euo pipefail

if (($# != 3)); then
  echo "Usage: deploy-postgres-stack.sh <remote-dir> <stack-name> <canary|production>" >&2
  exit 2
fi

remote_dir=$1
stack_name=$2
deploy_env=$3
env_deploy="${remote_dir}/envs/${deploy_env}/.env.deploy"
db_env="${remote_dir}/envs/${deploy_env}/.env.db"
db_network=$(grep '^MAKEPAD_POSTGRES_DB_NETWORK=' "${env_deploy}" | tail -n 1 | cut -d= -f2-)
le_petit_coin_db_network=$(grep '^MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK=' "${env_deploy}" | tail -n 1 | cut -d= -f2-)
postgres_image=$(grep '^POSTGRES_IMAGE=' "${db_env}" | tail -n 1 | cut -d= -f2-)
brio_backup_image=$(grep '^BRIO_BACKUP_IMAGE=' "${db_env}" | tail -n 1 | cut -d= -f2-)
postgres_root_user=$(grep '^POSTGRES_USER=' "${db_env}" | tail -n 1 | cut -d= -f2-)
postgres_root_password_file=$(grep '^MAKEPAD_POSTGRES_SUPERUSER_PASSWORD_FILE_HOST_PATH=' "${db_env}" | tail -n 1 | cut -d= -f2-)
postgres_tls_cert_config=$(grep '^MAKEPAD_POSTGRES_TLS_CERT_CONFIG=' "${db_env}" | tail -n 1 | cut -d= -f2-)
postgres_tls_key_secret=$(grep '^MAKEPAD_POSTGRES_TLS_KEY_SECRET=' "${db_env}" | tail -n 1 | cut -d= -f2-)
postgres_runtrace_hba_config=$(grep '^MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG=' "${db_env}" | tail -n 1 | cut -d= -f2-)
runtrace_backup_path=$(grep '^MAKEPAD_POSTGRES_RUNTRACE_BACKUP_PATH=' "${db_env}" | tail -n 1 | cut -d= -f2-)
runtrace_backup_password_file=$(grep '^MAKEPAD_POSTGRES_RUNTRACE_BACKUP_PASSWORD_FILE_HOST_PATH=' "${db_env}" | tail -n 1 | cut -d= -f2-)
postgres_ca_cert_file=$(grep '^MAKEPAD_POSTGRES_CA_CERT_HOST_PATH=' "${db_env}" | tail -n 1 | cut -d= -f2-)
brio_backup_recipient_cert=$(grep '^MAKEPAD_POSTGRES_BRIO_BACKUP_RECIPIENT_CERT_HOST_PATH=' "${db_env}" | tail -n 1 | cut -d= -f2-)
vif_enabled=0
brio_staging_enabled=0
if [[ "${deploy_env}" == "canary" ]]; then
  brio_staging_enabled=1
  brio_staging_db_network=$(grep '^MAKEPAD_POSTGRES_BRIO_STAGING_DB_NETWORK=' "${env_deploy}" | tail -n 1 | cut -d= -f2-)
  brio_backup_path=$(grep '^MAKEPAD_POSTGRES_BRIO_APP_BACKUP_PATH=' "${db_env}" | tail -n 1 | cut -d= -f2-)
  brio_backup_password_file=$(grep '^MAKEPAD_POSTGRES_BRIO_APP_BACKUP_PASSWORD_FILE_HOST_PATH=' "${db_env}" | tail -n 1 | cut -d= -f2-)
fi
if [[ "${deploy_env}" == "production" ]]; then
  vif_enabled=1
  vif_db_network=$(grep '^MAKEPAD_POSTGRES_VIF_DB_NETWORK=' "${env_deploy}" | tail -n 1 | cut -d= -f2-)
  vif_db_name=$(grep '^MAKEPAD_POSTGRES_VIF_DB_NAME=' "${env_deploy}" | tail -n 1 | cut -d= -f2-)
  vif_db_user=$(grep '^MAKEPAD_POSTGRES_VIF_DB_USER=' "${env_deploy}" | tail -n 1 | cut -d= -f2-)
  vif_db_password=$(grep '^MAKEPAD_POSTGRES_VIF_DB_PASSWORD=' "${env_deploy}" | tail -n 1 | cut -d= -f2-)
  brio_backup_path=$(grep '^MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_PATH=' "${db_env}" | tail -n 1 | cut -d= -f2-)
  brio_backup_password_file=$(grep '^MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_PASSWORD_FILE_HOST_PATH=' "${db_env}" | tail -n 1 | cut -d= -f2-)
fi
: "${db_network:?MAKEPAD_POSTGRES_DB_NETWORK is missing or empty in ${env_deploy}}"
: "${le_petit_coin_db_network:?MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK is missing or empty in ${env_deploy}}"
: "${postgres_image:?POSTGRES_IMAGE is missing or empty in ${db_env}}"
: "${brio_backup_image:?BRIO_BACKUP_IMAGE is missing or empty in ${db_env}}"
: "${postgres_root_user:?POSTGRES_USER is missing or empty in ${db_env}}"
: "${postgres_root_password_file:?MAKEPAD_POSTGRES_SUPERUSER_PASSWORD_FILE_HOST_PATH is missing or empty in ${db_env}}"
: "${postgres_tls_cert_config:?MAKEPAD_POSTGRES_TLS_CERT_CONFIG is missing or empty in ${db_env}}"
: "${postgres_tls_key_secret:?MAKEPAD_POSTGRES_TLS_KEY_SECRET is missing or empty in ${db_env}}"
: "${postgres_runtrace_hba_config:?MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG is missing or empty in ${db_env}}"
: "${postgres_ca_cert_file:?MAKEPAD_POSTGRES_CA_CERT_HOST_PATH is missing or empty in ${db_env}}"
: "${brio_backup_recipient_cert:?MAKEPAD_POSTGRES_BRIO_BACKUP_RECIPIENT_CERT_HOST_PATH is missing or empty in ${db_env}}"
: "${brio_backup_path:?Brio backup directory is missing or empty in ${db_env}}"
: "${brio_backup_password_file:?Brio backup password-file path is missing or empty in ${db_env}}"
if [[ "${deploy_env}" == "production" ]]; then
  : "${runtrace_backup_path:?MAKEPAD_POSTGRES_RUNTRACE_BACKUP_PATH is missing or empty in ${db_env}}"
  : "${runtrace_backup_password_file:?MAKEPAD_POSTGRES_RUNTRACE_BACKUP_PASSWORD_FILE_HOST_PATH is missing or empty in ${db_env}}"
fi
if [[ ! -s "${postgres_root_password_file}" ]]; then
  echo "PostgreSQL superuser password file is missing or empty: ${postgres_root_password_file}" >&2
  exit 1
fi
if ! docker config inspect "${postgres_tls_cert_config}" >/dev/null 2>&1; then
  echo "PostgreSQL TLS certificate config does not exist: ${postgres_tls_cert_config}" >&2
  exit 1
fi
if ! docker secret inspect "${postgres_tls_key_secret}" >/dev/null 2>&1; then
  echo "PostgreSQL TLS private-key secret does not exist: ${postgres_tls_key_secret}" >&2
  exit 1
fi
command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required for PostgreSQL certificate preflight." >&2
  exit 1
}
if [[ ! -s "${postgres_ca_cert_file}" || -L "${postgres_ca_cert_file}" ]] || ! grep -q -- '-----BEGIN CERTIFICATE-----' "${postgres_ca_cert_file}"; then
  echo "PostgreSQL CA certificate must be a non-empty, non-symlink PEM file: ${postgres_ca_cert_file}" >&2
  exit 1
fi
postgres_ca_mode=$(stat -c '%a' "${postgres_ca_cert_file}")
if (( (8#${postgres_ca_mode} & 8#022) != 0 )); then
  echo "PostgreSQL CA certificate must not be group- or world-writable: ${postgres_ca_cert_file}" >&2
  exit 1
fi
for backup_script in run-brio-encrypted-backup.sh run-brio-encrypted-backup-loop.sh; do
  if [[ ! -x "${remote_dir}/scripts/${backup_script}" || -L "${remote_dir}/scripts/${backup_script}" ]]; then
    echo "Brio backup script must be an executable, non-symlink file: ${remote_dir}/scripts/${backup_script}" >&2
    exit 1
  fi
done
if [[ ! -d "${brio_backup_path}" || -L "${brio_backup_path}" ]]; then
  echo "Brio backup path must be a pre-provisioned non-symlink directory: ${brio_backup_path}" >&2
  exit 1
fi
brio_backup_directory_mode=$(stat -c '%a' "${brio_backup_path}")
brio_backup_directory_uid=$(stat -c '%u' "${brio_backup_path}")
if [[ "${brio_backup_directory_mode}" != "700" || "${brio_backup_directory_uid}" != "999" ]]; then
  echo "Brio backup path must be owned by uid 999 with mode 0700: ${brio_backup_path}" >&2
  exit 1
fi
if [[ ! -s "${brio_backup_password_file}" || -L "${brio_backup_password_file}" ]]; then
  echo "Brio backup credential must be a non-empty, non-symlink file: ${brio_backup_password_file}" >&2
  exit 1
fi
brio_backup_password_mode=$(stat -c '%a' "${brio_backup_password_file}")
brio_backup_password_uid=$(stat -c '%u' "${brio_backup_password_file}")
if [[ "${brio_backup_password_mode}" != "400" || "${brio_backup_password_uid}" != "999" ]]; then
  echo "Brio backup credential must be owned by uid 999 with mode 0400." >&2
  exit 1
fi
if [[ ! -s "${brio_backup_recipient_cert}" || -L "${brio_backup_recipient_cert}" ]] || grep -q -- 'PRIVATE KEY' "${brio_backup_recipient_cert}"; then
  echo "Brio backup recipient must be a public, non-symlink X.509 certificate: ${brio_backup_recipient_cert}" >&2
  exit 1
fi
brio_backup_recipient_mode=$(stat -c '%a' "${brio_backup_recipient_cert}")
brio_backup_recipient_uid=$(stat -c '%u' "${brio_backup_recipient_cert}")
if [[ "${brio_backup_recipient_uid}" != "0" ]] || (( (8#${brio_backup_recipient_mode} & 8#022) != 0 )); then
  echo "Brio backup recipient certificate must be root-owned and not group- or world-writable." >&2
  exit 1
fi
if ! openssl x509 -in "${brio_backup_recipient_cert}" -noout -checkend 604800 >/dev/null \
  || ! printf 'brio-backup-preflight' | openssl cms -encrypt -binary -stream -outform DER -aes-256-gcm -recip "${brio_backup_recipient_cert}" -out /dev/null; then
  echo "Brio backup recipient certificate is invalid, unsuitable for CMS encryption, or expires in less than seven days." >&2
  exit 1
fi
server_certificate=$(mktemp)
cleanup_server_certificate() { rm -f "${server_certificate}"; }
trap cleanup_server_certificate EXIT
docker config inspect "${postgres_tls_cert_config}" --format '{{printf "%s" .Spec.Data}}' > "${server_certificate}"
if ! openssl x509 -in "${server_certificate}" -noout -checkend 604800 >/dev/null; then
  echo "PostgreSQL TLS certificate is invalid or expires in less than seven days." >&2
  exit 1
fi
if ! openssl verify -purpose sslserver -CAfile "${postgres_ca_cert_file}" -untrusted "${server_certificate}" "${server_certificate}" >/dev/null; then
  echo "PostgreSQL TLS certificate does not chain to the configured CA." >&2
  exit 1
fi
if [[ "${deploy_env}" == "canary" ]] && ! openssl x509 -in "${server_certificate}" -noout -checkhost makepad-postgres-brio-staging >/dev/null; then
  echo "Canary PostgreSQL TLS certificate does not cover makepad-postgres-brio-staging." >&2
  exit 1
fi
if [[ "${deploy_env}" == "production" ]]; then
  if [[ ! -d "${runtrace_backup_path}" || -L "${runtrace_backup_path}" ]]; then
    echo "Runtrace backup path must be a pre-provisioned non-symlink directory: ${runtrace_backup_path}" >&2
    exit 1
  fi
  backup_directory_mode=$(stat -c '%a' "${runtrace_backup_path}")
  backup_directory_uid=$(stat -c '%u' "${runtrace_backup_path}")
  if [[ "${backup_directory_mode}" != "700" || "${backup_directory_uid}" != "70" ]]; then
    echo "Runtrace backup path must be owned by uid 70 with mode 0700: ${runtrace_backup_path}" >&2
    exit 1
  fi
  if [[ ! -s "${runtrace_backup_password_file}" || -L "${runtrace_backup_password_file}" ]]; then
    echo "Runtrace backup credential must be a non-empty, non-symlink file: ${runtrace_backup_password_file}" >&2
    exit 1
  fi
  backup_password_mode=$(stat -c '%a' "${runtrace_backup_password_file}")
  backup_password_uid=$(stat -c '%u' "${runtrace_backup_password_file}")
  if [[ "${backup_password_mode}" != "400" || "${backup_password_uid}" != "70" ]]; then
    echo "Runtrace backup credential must be owned by uid 70 with mode 0400." >&2
    exit 1
  fi
fi
hba_path="${remote_dir}/config/runtrace-pg_hba.conf"
hba_sha256=$(sha256sum "${hba_path}" | awk '{print $1}')
if docker config inspect "${postgres_runtrace_hba_config}" >/dev/null 2>&1; then
  deployed_hba_sha256=$(docker config inspect "${postgres_runtrace_hba_config}" --format '{{index .Spec.Labels "content-sha256"}}')
  if [[ "${deployed_hba_sha256}" != "${hba_sha256}" ]]; then
    echo "PostgreSQL HBA config ${postgres_runtrace_hba_config} does not match the repository policy. Create a new versioned config name and update MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG." >&2
    exit 1
  fi
else
  docker config create --label "content-sha256=${hba_sha256}" "${postgres_runtrace_hba_config}" "${hba_path}" >/dev/null
fi
if [[ "${vif_enabled}" == "1" ]]; then
  : "${vif_db_network:?MAKEPAD_POSTGRES_VIF_DB_NETWORK is missing or empty in ${env_deploy}}"
  : "${vif_db_name:?MAKEPAD_POSTGRES_VIF_DB_NAME is missing or empty in ${env_deploy}}"
  : "${vif_db_user:?MAKEPAD_POSTGRES_VIF_DB_USER is missing or empty in ${env_deploy}}"
  : "${vif_db_password:?MAKEPAD_POSTGRES_VIF_DB_PASSWORD is missing or empty in ${env_deploy}}"
fi
if [[ "${brio_staging_enabled}" == "1" ]]; then
  : "${brio_staging_db_network:?MAKEPAD_POSTGRES_BRIO_STAGING_DB_NETWORK is missing or empty in ${env_deploy}}"
  if [[ "${brio_staging_db_network}" != "makepad_brio_staging_db" ]]; then
    echo "Brio deployment bundle must use makepad_brio_staging_db." >&2
    exit 1
  fi
fi

ensure_encrypted_overlay_network() {
  local network_name=$1
  if docker network inspect "${network_name}" >/dev/null 2>&1; then
    local driver scope encrypted
    driver=$(docker network inspect "${network_name}" --format '{{.Driver}}')
    scope=$(docker network inspect "${network_name}" --format '{{.Scope}}')
    encrypted=$(docker network inspect "${network_name}" --format '{{index .Options "encrypted"}}')
    if [[ "${driver}" != "overlay" || "${scope}" != "swarm" || "${encrypted}" != "true" ]]; then
      echo "Database network ${network_name} must be a Swarm overlay with encrypted=true. Drain dependent services, recreate it with --opt encrypted, then rerun this deployment." >&2
      exit 1
    fi
    return
  fi
  docker network create --driver overlay --attachable --opt encrypted "${network_name}" >/dev/null
}

ensure_internal_encrypted_overlay_network() {
  local network_name=$1
  if ! docker network inspect "${network_name}" >/dev/null 2>&1; then
    docker network create --driver overlay --attachable --internal --opt encrypted "${network_name}" >/dev/null
  fi
  local details
  details=$(docker network inspect "${network_name}" --format '{{.Driver}} {{.Scope}} {{.Internal}} {{.Attachable}} {{index .Options "encrypted"}}')
  if [[ "${details}" != "overlay swarm true true true" ]]; then
    echo "Brio database network ${network_name} must be an internal, encrypted, attachable Swarm overlay; got ${details}." >&2
    exit 1
  fi
}

ensure_encrypted_overlay_network "${db_network}"
ensure_encrypted_overlay_network "${le_petit_coin_db_network}"
if [[ "${vif_enabled}" == "1" ]]; then
  ensure_encrypted_overlay_network "${vif_db_network}"
  export MAKEPAD_POSTGRES_VIF_DB_NETWORK="${vif_db_network}"
fi
if [[ "${brio_staging_enabled}" == "1" ]]; then
  ensure_internal_encrypted_overlay_network "${brio_staging_db_network}"
  export MAKEPAD_POSTGRES_BRIO_STAGING_DB_NETWORK="${brio_staging_db_network}"
fi

export MAKEPAD_POSTGRES_DB_NETWORK="${db_network}"
export MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK="${le_petit_coin_db_network}"
docker compose \
  --env-file "${remote_dir}/envs/${deploy_env}/.env.db" \
  --env-file "${env_deploy}" \
  -f "${remote_dir}/compose.yml" \
  -f "${remote_dir}/envs/${deploy_env}/compose.yml" \
  config > "${remote_dir}/stack.yml"

docker stack deploy --compose-file "${remote_dir}/stack.yml" "${stack_name}"

wait_for_service_convergence() {
  local service_name=$1
  local expected_image=$2
  local update_state desired running_snapshot running_count wrong_image
  for _ in $(seq 1 60); do
    if ! docker service inspect "${service_name}" >/dev/null 2>&1; then
      sleep 2
      continue
    fi
    update_state=$(docker service inspect "${service_name}" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}none{{end}}')
    case "${update_state}" in
      paused|rollback_started|rollback_paused|rollback_completed)
        echo "Service ${service_name} update did not complete successfully: ${update_state}." >&2
        docker service ps --no-trunc "${service_name}" >&2
        return 1
        ;;
      updating)
        sleep 2
        continue
        ;;
    esac
    desired=$(docker service inspect "${service_name}" --format '{{.Spec.Mode.Replicated.Replicas}}')
    running_snapshot=$(docker service ps --no-trunc --filter desired-state=running --format '{{.Image}} {{.CurrentState}}' "${service_name}")
    running_count=$(printf '%s\n' "${running_snapshot}" | awk '$2 == "Running" {count++} END {print count + 0}')
    wrong_image=$(printf '%s\n' "${running_snapshot}" | awk -v expected="${expected_image}" '$2 == "Running" && $1 != expected {print $1; exit}')
    if [[ "${running_count}" == "${desired}" && -z "${wrong_image}" && ( "${update_state}" == "completed" || "${update_state}" == "none" ) ]]; then
      return 0
    fi
    sleep 2
  done
  echo "Service ${service_name} did not converge to ${expected_image}." >&2
  docker service ps --no-trunc "${service_name}" >&2 || true
  return 1
}

wait_for_service_convergence "${stack_name}_postgres" "${postgres_image}"
if [[ "${deploy_env}" == "canary" ]]; then
  wait_for_service_convergence "${stack_name}_brio_staging_backup" "${brio_backup_image}"
else
  wait_for_service_convergence "${stack_name}_keycloak_brio_staging_backup" "${brio_backup_image}"
fi

if [[ "${brio_staging_enabled}" == "1" ]]; then
  brio_tls_ready=0
  for _ in $(seq 1 30); do
    if docker run --rm --network "${brio_staging_db_network}" \
      -e PGSSLMODE=verify-full \
      -e PGSSLROOTCERT=/etc/postgresql/ca.crt \
      -v "${postgres_root_password_file}:/run/secrets/postgres_superuser_password:ro" \
      -v "${postgres_ca_cert_file}:/etc/postgresql/ca.crt:ro" \
      "${postgres_image}" sh -ec 'export PGPASSWORD=$(cat /run/secrets/postgres_superuser_password); exec psql "$@"' sh \
      -h makepad-postgres-brio-staging -U "${postgres_root_user}" -d postgres -Atc "select 1" >/dev/null 2>&1; then
      brio_tls_ready=1
      break
    fi
    sleep 2
  done
  if [[ "${brio_tls_ready}" != "1" ]]; then
    echo "PostgreSQL did not pass sslmode=verify-full using makepad-postgres-brio-staging within 60 seconds." >&2
    exit 1
  fi
fi

if [[ "${vif_enabled}" != "1" ]]; then
  exit 0
fi

postgres_ready=0
for _ in $(seq 1 30); do
  if docker run --rm --network "${vif_db_network}" \
    -v "${postgres_root_password_file}:/run/secrets/postgres_superuser_password:ro" \
    "${postgres_image}" sh -ec 'export PGPASSWORD=$(cat /run/secrets/postgres_superuser_password); exec psql "$@"' sh \
    -h makepad-postgres-vif -U "${postgres_root_user}" -d postgres -c "select 1" >/dev/null 2>&1; then
    postgres_ready=1
    break
  fi
  sleep 2
done
if [[ "${postgres_ready}" != "1" ]]; then
  echo "Postgres did not become reachable via makepad-postgres-vif on ${vif_db_network} after 60 seconds." >&2
  exit 1
fi

docker run --rm --network "${vif_db_network}" \
  -v "${postgres_root_password_file}:/run/secrets/postgres_superuser_password:ro" \
  "${postgres_image}" sh -ec 'export PGPASSWORD=$(cat /run/secrets/postgres_superuser_password); exec psql "$@"' sh \
  -h makepad-postgres-vif -U "${postgres_root_user}" -d postgres \
  -v ON_ERROR_STOP=1 \
  -v vif_db="${vif_db_name}" \
  -v vif_user="${vif_db_user}" \
  -v vif_password="${vif_db_password}" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'vif_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'vif_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'vif_user', :'vif_password') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'vif_db', :'vif_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'vif_db') \gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', :'vif_db', :'vif_user')
WHERE EXISTS (
  SELECT 1
  FROM pg_database d
  JOIN pg_roles r ON r.oid = d.datdba
  WHERE d.datname = :'vif_db'
    AND r.rolname <> :'vif_user'
) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'vif_db', :'vif_user') \gexec
SQL
