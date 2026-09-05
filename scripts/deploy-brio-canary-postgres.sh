#!/usr/bin/env bash
set -euo pipefail

if (($# != 3)); then
  echo "Usage: deploy-brio-canary-postgres.sh <remote-dir> <stack-name> <runtime-secret-dir>" >&2
  exit 2
fi

remote_dir=$1
stack_name=$2
runtime_dir=$3
db_env="${remote_dir}/envs/canary/.env.db"
env_deploy="${remote_dir}/envs/canary/.env.deploy"
rollback_armed=0
stack_mutated=0
stack_preexisting=0
db_mutated=0
postgres_image=
validation_image=
declare -a missing_configs=()
declare -a missing_secrets=()
declare -a missing_networks=()
deployment_id=${runtime_dir##*/postgres-brio-canary-runtime-}
recovery_root=/var/lib/makepad/postgres-recovery/brio-canary
journal_dir="${recovery_root}/${deployment_id}"
failure_injection=${BRIO_DEPLOY_FAILURE_INJECTION:-}

if [[ -n "${failure_injection}" ]]; then
  [[ "${BRIO_DEPLOY_TEST_MODE:-}" == "isolated-container" && -f /.dockerenv ]] || {
    echo "Failure injection is permitted only in the isolated deployment test container." >&2
    exit 2
  }
  case "${failure_injection}" in
    after-managed-file-promotion|term-after-managed-file-promotion|kill-after-managed-file-promotion|after-stack-deploy|after-bootstrap|kill-after-bootstrap|after-app-probe|after-plaintext-probe|after-nontarget-probe|after-backup-role-probe|after-backup-verification|rollback-restore) ;;
    *) echo "Unsupported canary deployment failure injection." >&2; exit 2 ;;
  esac
fi

if [[ ! "${remote_dir}" =~ ^/(srv|opt)/[A-Za-z0-9._/-]+/\.deploy/postgres-[0-9]+-[0-9]+$ ]] \
  || [[ "${remote_dir}" == *"/../"* || "${remote_dir}" == *"/.." || "${remote_dir}" == *"/./"* || "${remote_dir}" == *"/." || "${remote_dir}" == *"//"* ]]; then
  echo "remote-dir must be a unique /srv or /opt .deploy/postgres-<run>-<attempt> path." >&2
  exit 2
fi
[[ "${runtime_dir}" =~ ^/tmp/postgres-brio-canary-runtime-[0-9]+-[0-9]+$ ]] || { echo "runtime-secret-dir must be a job-scoped /tmp/postgres-brio-canary-runtime-<run>-<attempt> path." >&2; exit 2; }
case "${stack_name}" in ''|*[!a-zA-Z0-9_-]*) echo "stack-name contains unsupported characters." >&2; exit 2 ;; esac

require_brio_deployment_lease() {
  [[ "${BRIO_OPERATION_LEASE_OWNER:-}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "BRIO_OPERATION_LEASE_OWNER must be the exact deployment lease owner." >&2
    exit 1
  }
  /usr/bin/sudo -n /usr/local/libexec/makepad/brio-operation-lease \
    status "${BRIO_OPERATION_LEASE_OWNER}" deployment >/dev/null
}

cleanup_runtime() {
  local name
  for name in postgres-superuser-password brio-staging-app-password brio-staging-backup-password postgres-ca.pem postgres-server-cert.pem postgres-server-key.pem brio-backup-recipient-cert.pem; do
    [[ ! -f "${runtime_dir}/${name}" || -L "${runtime_dir}/${name}" ]] || rm -f -- "${runtime_dir:?}/${name}"
  done
  if [[ -f "${runtime_dir}/RECOVERY_REQUIRED" && ! -L "${runtime_dir}/RECOVERY_REQUIRED" ]]; then
    return
  fi
  if [[ -e "${runtime_dir}/RECOVERY_REQUIRED" || -L "${runtime_dir}/RECOVERY_REQUIRED" ]]; then
    echo "Unsafe recovery marker type; preserving the canary runtime for operator inspection." >&2
    return 1
  fi
  rm -f -- "${runtime_dir}/candidate-stack.yml" "${runtime_dir}/prior-services.list"
  rm -f -- "${runtime_dir}/prior-service-spec-hashes.list"
  if [[ -d "${runtime_dir}/prior-service-specs" && ! -L "${runtime_dir}/prior-service-specs" ]]; then
    find "${runtime_dir}/prior-service-specs" -depth -delete
  fi
  rmdir -- "${runtime_dir}" 2>/dev/null || true
}

handle_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${rollback_armed}" == "1" ]]; then
    if ! rollback_canary; then
      journal_marker "${journal_dir}" RECOVERY_REQUIRED || true
      {
        printf 'deployment_id=%s\n' "${runtime_dir##*/postgres-brio-canary-runtime-}"
        printf 'reason=%s\n' 'automatic-canary-rollback-failed'
      } > "${runtime_dir}/RECOVERY_REQUIRED"
      chmod 0600 "${runtime_dir}/RECOVERY_REQUIRED"
      echo "Automatic canary rollback failed; root-protected snapshot retained in ${journal_dir}." >&2
      status=1
    fi
  fi
  cleanup_runtime || status=1
  exit "${status}"
}
trap handle_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

read_setting() {
  local name=$1 file=$2 value
  value=$(grep -E "^${name}=" "${file}" | tail -n 1 | cut -d= -f2-)
  [[ -n "${value}" ]] || { echo "${name} is missing or empty in ${file}." >&2; exit 1; }
  printf '%s' "${value}"
}

run_db_transaction() {
  local operation=$1 source_journal=${2:-${journal_dir}} helper
  if [[ "${operation}" == prepare ]]; then helper="${remote_dir}/scripts/brio-db-transaction.sh"; else helper="${source_journal}/brio-db-transaction.sh"; fi
  [[ -f "${helper}" && ! -L "${helper}" ]] || { echo "Canary database compensation helper is unavailable." >&2; return 1; }
  # The Brio-only network is deliberately allowed to be absent on a first
  # deployment. Journal preparation and recovery therefore use the already
  # validated shared database network and its certificate SAN.
  docker run --rm --network "${db_network}" \
    --mount "type=bind,src=${helper},dst=/usr/local/bin/brio-db-transaction.sh,readonly" \
    --mount "type=bind,src=${source_journal},dst=/journal" \
    --mount "type=bind,src=${superuser_host_file},dst=/run/secrets/postgres_superuser_password,readonly" \
    --mount "type=bind,src=${ca_host_file},dst=/etc/postgresql/ca.crt,readonly" \
    -e "PGUSER=${postgres_user}" -e PGHOST=makepad-postgres \
    -e PGSSLMODE=verify-full -e PGSSLROOTCERT=/etc/postgresql/ca.crt \
    -e PGPASSWORD_FILE=/run/secrets/postgres_superuser_password \
    "${postgres_image}" /usr/local/bin/brio-db-transaction.sh "${operation}" brio /journal/database
}

journal_marker() {
  local source_journal=$1 marker=$2
  case "${marker}" in IN_PROGRESS|STACK_MUTATION_ARMED|DATABASE_MUTATION_ARMED|COMMITTED|ROLLED_BACK|RECOVERY_REQUIRED) ;;
    *) echo "Refusing unsupported canary journal marker." >&2; return 1 ;;
  esac
  docker run --rm --mount "type=bind,src=${source_journal},dst=/journal" \
    -e "MARKER=${marker}" "${validation_image}" sh -euc '
      case "$MARKER" in IN_PROGRESS|STACK_MUTATION_ARMED|DATABASE_MUTATION_ARMED|COMMITTED|ROLLED_BACK|RECOVERY_REQUIRED) ;; *) exit 1 ;; esac
      [ -d /journal ] && [ ! -L /journal ]
      tmp="/journal/.${MARKER}.tmp"
      [ ! -e "$tmp" ] && [ ! -L "$tmp" ]
      printf "%s\n" "$MARKER" > "$tmp"
      chmod 0600 "$tmp"
      mv -fT "$tmp" "/journal/$MARKER"
      sync -f /journal 2>/dev/null || sync
    '
}

remove_durable_journal() {
  local source_journal=$1
  docker run --rm --mount type=bind,src=/var/lib/makepad,dst=/managed-var-lib \
    -e "JOURNAL=${source_journal}" "${validation_image}" sh -euc '
      case "$JOURNAL" in /var/lib/makepad/postgres-recovery/brio-canary/*) identifier=${JOURNAL##*/} ;; *) exit 1 ;; esac
      case "$identifier" in ""|*[!0-9-]*|*-*-*|-*|*-|0*|*-0*) exit 1 ;; esac
      case "$identifier" in *-*) ;; *) exit 1 ;; esac
      target="/managed-var-lib${JOURNAL#/var/lib/makepad}"
      [ -d "$target" ] && [ ! -L "$target" ]
      find "$target" -depth -delete
      sync -f /managed-var-lib/postgres-recovery/brio-canary 2>/dev/null || sync
    '
}

journal_has_marker() {
  local source_journal=$1 marker=$2
  docker run --rm --mount "type=bind,src=${source_journal},dst=/journal,readonly" \
    -e "MARKER=${marker}" "${validation_image}" sh -euc '
      case "$MARKER" in IN_PROGRESS|STACK_MUTATION_ARMED|DATABASE_MUTATION_ARMED|COMMITTED|ROLLED_BACK|RECOVERY_REQUIRED) ;; *) exit 2 ;; esac
      [ -f "/journal/$MARKER" ] && [ ! -L "/journal/$MARKER" ]
    ' >/dev/null 2>&1
}

rollback_canary() {
  local rollback_status=0 service_name previous_spec name expected_hash current_hash
  echo "Canary deployment failed after the mutation boundary; restoring exact database, Swarm specs, and managed host files." >&2
  if [[ "${db_mutated}" == 1 ]] || journal_has_marker "${journal_dir}" DATABASE_MUTATION_ARMED; then
    run_db_transaction restore "${journal_dir}" || rollback_status=1
  fi
  if [[ "${failure_injection}" == rollback-restore ]]; then
    rollback_status=1
  else
    if [[ "${stack_mutated}" == 1 ]] || journal_has_marker "${journal_dir}" STACK_MUTATION_ARMED; then
      while IFS= read -r service_name; do
        if ! docker run --rm --mount "type=bind,src=${journal_dir},dst=/journal,readonly" \
          -e "SERVICE=${service_name}" "${validation_image}" sh -euc 'grep -Fxq "$SERVICE" /journal/swarm/prior-services.list'; then
          docker service rm "${service_name}" >/dev/null || rollback_status=1
        fi
      done < <(docker stack services "${stack_name}" --format '{{.Name}}' 2>/dev/null || true)
      while IFS='|' read -r service_name expected_hash; do
        docker service inspect "${service_name}" >/dev/null 2>&1 || { rollback_status=1; continue; }
        current_hash=$(docker service inspect "${service_name}" --format '{{json .Spec}}' | sha256sum | cut -d' ' -f1)
        if [[ "${current_hash}" != "${expected_hash}" ]]; then
          previous_spec=$(docker service inspect "${service_name}" --format '{{if .PreviousSpec}}present{{else}}absent{{end}}')
          if [[ "${previous_spec}" == present ]]; then
            docker service rollback --detach=false "${service_name}" >/dev/null || rollback_status=1
          else
            rollback_status=1
          fi
        fi
        current_hash=$(docker service inspect "${service_name}" --format '{{json .Spec}}' | sha256sum | cut -d' ' -f1)
        [[ "${current_hash}" == "${expected_hash}" ]] || rollback_status=1
      done < <(docker run --rm --mount "type=bind,src=${journal_dir},dst=/journal,readonly" \
        "${validation_image}" cat /journal/swarm/prior-service-spec-hashes.list)
    fi
    docker run --rm \
      --mount type=bind,src=/etc,dst=/host/etc \
      --mount type=bind,src=/var/lib,dst=/host/var/lib \
      --mount "type=bind,src=${journal_dir}/rollback,dst=/rollback,readonly" \
      "${validation_image}" sh -euc '
        backup=/host/var/lib/makepad/postgres-backups/brio-staging
        if [ -d "$backup" ] && [ ! -L "$backup" ]; then
          for child in "$backup"/* "$backup"/.*; do
            [ -e "$child" ] || [ -L "$child" ] || continue
            name=${child##*/}; case "$name" in .|..|latest|last-success.json) continue ;; esac
            if ! grep -Fxq "$name" /rollback/backup-entries.list; then
              case "$name" in 20??????T??????Z|.20??????T??????Z.partial) ;; *) echo "Unsafe unexpected backup entry: $name" >&2; exit 1 ;; esac
              [ ! -L "$child" ] || { echo "Unexpected backup entry is a symlink." >&2; exit 1; }
              find "$child" -depth -delete
            fi
          done
          rm -f -- "$backup/latest" "$backup/last-success.json"
          if [ -f /rollback/prior-latest-target ]; then
            target=$(cat /rollback/prior-latest-target)
            case "$target" in 20??????T??????Z) ;; *) exit 1 ;; esac
            ln -s "$target" "$backup/latest"
          fi
          if [ -f /rollback/prior-last-success.json ]; then cp -a /rollback/prior-last-success.json "$backup/last-success.json"; fi
        fi
        while IFS= read -r path; do
          case "$path" in
            etc/makepad/secrets/postgres-canary-superuser-password|etc/makepad/tls/postgres/ca.crt|etc/makepad/secrets/postgres-brio-app-backup-password|etc/makepad/tls/backups/brio-recipient.crt) rm -f -- "/host/$path" ;;
            var/lib/makepad/postgres-backups/brio-staging)
              if ! rmdir -- "/host/$path" 2>/dev/null; then echo "New backup directory is not empty." >&2; exit 1; fi ;;
            *) echo "Unexpected absent rollback path." >&2; exit 1 ;;
          esac
        done < /rollback/absent.list
        tar --numeric-owner -xpf /rollback/managed.tar -C /host
      ' || rollback_status=1
  fi
  for object_kind in secret config network; do
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      if docker "${object_kind}" inspect "${name}" >/dev/null 2>&1; then
        if [[ "${object_kind}" == network ]]; then
          owner=$(docker network inspect "${name}" --format '{{index .Labels "makepad.brio.deployment-id"}}')
        else
          owner=$(docker "${object_kind}" inspect "${name}" --format '{{index .Spec.Labels "makepad.brio.deployment-id"}}')
        fi
        [[ "${owner}" == "${deployment_id}" ]] && docker "${object_kind}" rm "${name}" >/dev/null || rollback_status=1
      fi
    done < <(docker "${object_kind}" ls --filter "label=makepad.brio.deployment-id=${deployment_id}" --format '{{.Name}}' 2>/dev/null || true)
  done
  if [[ "${rollback_status}" == 0 ]]; then journal_marker "${journal_dir}" ROLLED_BACK || rollback_status=1; fi
  if [[ "${rollback_status}" == 0 ]]; then remove_durable_journal "${journal_dir}" || rollback_status=1; fi
  return "${rollback_status}"
}

recover_incomplete_journals() {
  local current_id="${deployment_id}" current_journal="${journal_dir}" saved_injection="${failure_injection}"
  local listing state identifier
  listing=$(docker run --rm --mount type=bind,src=/var/lib/makepad,dst=/managed-var-lib,readonly \
    "${validation_image}" sh -euc '
      root=/managed-var-lib/postgres-recovery/brio-canary
      [ ! -e "$root" ] && exit 0
      [ -d "$root" ] && [ ! -L "$root" ]
      for candidate in "$root"/* "$root"/.*; do
        [ -e "$candidate" ] || continue
        name=${candidate##*/}; case "$name" in .|..) continue ;; .*.staging) echo "INCOMPLETE:$name"; continue ;; esac
        case "$name" in ""|*[!0-9-]*|*-*-*|-*|*-|0*|*-0*) echo "UNSAFE:$name"; continue ;; esac
        case "$name" in *-*) ;; *) echo "UNSAFE:$name"; continue ;; esac
        [ -d "$candidate" ] && [ ! -L "$candidate" ] || { echo "UNSAFE:$name"; continue; }
        if [ -f "$candidate/COMMITTED" ] && [ ! -L "$candidate/COMMITTED" ]; then echo "COMMITTED:$name"
        elif [ -f "$candidate/ROLLED_BACK" ] && [ ! -L "$candidate/ROLLED_BACK" ]; then echo "ROLLED_BACK:$name"
        elif [ -f "$candidate/IN_PROGRESS" ] && [ ! -L "$candidate/IN_PROGRESS" ]; then echo "PENDING:$name"
        else echo "UNSAFE:$name"; fi
      done
    ')
  while IFS=: read -r state identifier; do
    [[ -n "${state}" ]] || continue
    case "${state}" in
      COMMITTED|ROLLED_BACK) remove_durable_journal "${recovery_root}/${identifier}" ;;
      PENDING)
        deployment_id=${identifier}
        journal_dir="${recovery_root}/${identifier}"
        db_mutated=0; stack_mutated=0
        journal_has_marker "${journal_dir}" DATABASE_MUTATION_ARMED && db_mutated=1
        journal_has_marker "${journal_dir}" STACK_MUTATION_ARMED && stack_mutated=1
        failure_injection=
        if ! rollback_canary; then
          journal_marker "${journal_dir}" RECOVERY_REQUIRED || true
          echo "Interrupted canary transaction could not be recovered." >&2
          return 1
        fi
        ;;
      INCOMPLETE|UNSAFE) echo "Unsafe or incomplete canary journal detected: ${identifier}" >&2; return 1 ;;
      *) return 1 ;;
    esac
  done <<< "${listing}"
  deployment_id=${current_id}
  journal_dir=${current_journal}
  failure_injection=${saved_injection}
  db_mutated=0; stack_mutated=0
}

postgres_image=$(read_setting POSTGRES_IMAGE "${db_env}")
validation_image=$(read_setting BRIO_BACKUP_IMAGE "${db_env}")
postgres_user=$(read_setting POSTGRES_USER "${db_env}")
superuser_host_file=$(read_setting MAKEPAD_POSTGRES_SUPERUSER_PASSWORD_FILE_HOST_PATH "${db_env}")
ca_host_file=$(read_setting MAKEPAD_POSTGRES_CA_CERT_HOST_PATH "${db_env}")
backup_host_file=$(read_setting MAKEPAD_POSTGRES_BRIO_APP_BACKUP_PASSWORD_FILE_HOST_PATH "${db_env}")
recipient_host_file=$(read_setting MAKEPAD_POSTGRES_BRIO_BACKUP_RECIPIENT_CERT_HOST_PATH "${db_env}")
backup_host_dir=$(read_setting MAKEPAD_POSTGRES_BRIO_APP_BACKUP_PATH "${db_env}")
tls_cert_config=$(read_setting MAKEPAD_POSTGRES_TLS_CERT_CONFIG "${db_env}")
tls_key_secret=$(read_setting MAKEPAD_POSTGRES_TLS_KEY_SECRET "${db_env}")
hba_config=$(read_setting MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG "${db_env}")
brio_network=$(read_setting MAKEPAD_POSTGRES_BRIO_STAGING_DB_NETWORK "${env_deploy}")
db_network=$(read_setting MAKEPAD_POSTGRES_DB_NETWORK "${env_deploy}")
le_petit_coin_network=$(read_setting MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK "${env_deploy}")

if [[ "${brio_network}" != "makepad_brio_staging_db" ]]; then
  echo "Canary provisioning requires makepad_brio_staging_db." >&2
  exit 1
fi
[[ "${superuser_host_file}" == "/etc/makepad/secrets/postgres-canary-superuser-password" \
  && "${ca_host_file}" == "/etc/makepad/tls/postgres/ca.crt" \
  && "${backup_host_file}" == "/etc/makepad/secrets/postgres-brio-app-backup-password" \
  && "${recipient_host_file}" == "/etc/makepad/tls/backups/brio-recipient.crt" \
  && "${backup_host_dir}" == "/var/lib/makepad/postgres-backups/brio-staging" \
  && "${tls_cert_config}" == "makepad_postgres_canary_tls_cert_v2" \
  && "${tls_key_secret}" == "makepad_postgres_canary_tls_key_v2" \
  && "${hba_config}" == "makepad_postgres_canary_runtrace_hba_v3" ]] || {
  echo "Canary environment does not match the exact reviewed managed-path and immutable-object contract." >&2
  exit 1
}
for network_name in "${db_network}" "${le_petit_coin_network}" "${brio_network}"; do
  [[ "${network_name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$ ]] || {
    echo "Canary network name is not normalized: ${network_name}" >&2
    exit 1
  }
done
[[ "${db_network}" != "${le_petit_coin_network}" && "${db_network}" != "${brio_network}" \
  && "${le_petit_coin_network}" != "${brio_network}" ]] || {
  echo "Canary database networks must be distinct." >&2
  exit 1
}

assert_no_symlink_components() {
  local path=$1 current='' component
  local -a components=()
  [[ "${path}" == /* && "${path}" != *"//"* && "${path}" != *"/./"* \
    && "${path}" != */. && "${path}" != *"/../"* && "${path}" != */.. ]] || {
    echo "Managed path is not a normalized absolute path: ${path}" >&2
    return 1
  }
  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -n "${component}" && "${component}" != "." && "${component}" != ".." ]] || {
      echo "Managed path contains an unsafe component: ${path}" >&2
      return 1
    }
    current="${current}/${component}"
    [[ ! -L "${current}" ]] || {
      echo "Managed path contains a symlink component: ${current}" >&2
      return 1
    }
  done
}
for managed_path in "${superuser_host_file}" "${ca_host_file}" "${backup_host_file}" "${recipient_host_file}" "${backup_host_dir}" \
  /var/lib/makepad/postgres-recovery "${recovery_root}"; do
  assert_no_symlink_components "${managed_path}"
done
for managed_parent in \
  /etc/makepad/secrets \
  /etc/makepad/tls/postgres \
  /etc/makepad/tls/backups \
  /var/lib/makepad/postgres-backups; do
  [[ -d "${managed_parent}" && ! -L "${managed_parent}" ]] || {
    echo "Required exact managed parent is missing, not a directory, or a symlink: ${managed_parent}" >&2
    exit 1
  }
done
for managed_file in "${superuser_host_file}" "${ca_host_file}" "${backup_host_file}" "${recipient_host_file}"; do
  [[ ! -e "${managed_file}" || -f "${managed_file}" ]] || {
    echo "Managed file destination has an unexpected type: ${managed_file}" >&2
    exit 1
  }
done
[[ ! -e "${backup_host_dir}" || -d "${backup_host_dir}" ]] || {
  echo "Managed backup destination has an unexpected type: ${backup_host_dir}" >&2
  exit 1
}

require_runtime_file() {
  local path="${runtime_dir}/$1" mode
  if [[ ! -s "${path}" || -L "${path}" ]]; then
    echo "Required job-scoped input is missing, empty, or a symlink: $1" >&2
    exit 1
  fi
  mode=$(stat -c '%a' "${path}")
  if [[ "${mode}" != "600" ]]; then
    echo "Job-scoped input must have mode 0600: $1" >&2
    exit 1
  fi
}

runtime_mode=$(stat -c '%a' "${runtime_dir}")
[[ ! -L "${runtime_dir}" && "${runtime_mode}" == "700" ]] || {
  echo "Job-scoped runtime directory must be a non-symlink with mode 0700." >&2
  exit 1
}
for input in \
  postgres-superuser-password \
  brio-staging-app-password \
  brio-staging-backup-password \
  postgres-ca.pem \
  postgres-server-cert.pem \
  postgres-server-key.pem \
  brio-backup-recipient-cert.pem; do
  require_runtime_file "${input}"
done
for password_file in postgres-superuser-password brio-staging-app-password brio-staging-backup-password; do
  if [[ $(awk 'END { print NR }' "${runtime_dir}/${password_file}") -ne 1 ]] || grep -q $'\r' "${runtime_dir}/${password_file}"; then
    echo "Password input must contain one line and no carriage return: ${password_file}" >&2
    exit 1
  fi
done
if cmp -s "${runtime_dir}/postgres-superuser-password" "${runtime_dir}/brio-staging-app-password" \
  || cmp -s "${runtime_dir}/postgres-superuser-password" "${runtime_dir}/brio-staging-backup-password" \
  || cmp -s "${runtime_dir}/brio-staging-app-password" "${runtime_dir}/brio-staging-backup-password"; then
  echo "PostgreSQL superuser, Brio application, and Brio backup credentials must all be distinct." >&2
  exit 1
fi

command -v openssl >/dev/null 2>&1 || { echo "openssl is required." >&2; exit 1; }
openssl x509 -in "${runtime_dir}/postgres-ca.pem" -noout -checkend 604800 >/dev/null
openssl x509 -in "${runtime_dir}/postgres-server-cert.pem" -noout -checkend 604800 >/dev/null
openssl verify -purpose sslserver -CAfile "${runtime_dir}/postgres-ca.pem" "${runtime_dir}/postgres-server-cert.pem" >/dev/null
openssl x509 -in "${runtime_dir}/postgres-server-cert.pem" -noout -checkhost makepad-postgres-brio-staging >/dev/null
cert_key_hash=$(openssl x509 -in "${runtime_dir}/postgres-server-cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
private_key_hash=$(openssl pkey -in "${runtime_dir}/postgres-server-key.pem" -pubout -outform DER | sha256sum | cut -d' ' -f1)
[[ "${cert_key_hash}" == "${private_key_hash}" ]] || { echo "PostgreSQL TLS certificate and private key do not match." >&2; exit 1; }
if grep -q -- 'PRIVATE KEY' "${runtime_dir}/brio-backup-recipient-cert.pem" \
  || ! openssl x509 -in "${runtime_dir}/brio-backup-recipient-cert.pem" -noout -checkend 604800 >/dev/null \
  || ! printf 'brio-backup-preflight' | openssl cms -encrypt -binary -stream -outform DER -aes-256-gcm \
    -recip "${runtime_dir}/brio-backup-recipient-cert.pem" -out /dev/null; then
  echo "Brio backup recipient must be a valid public encryption certificate with at least seven days remaining." >&2
  exit 1
fi

prevalidate_swarm_config() {
  local name=$1 source=$2 kind=$3 digest deployed_digest actual_file
  digest=$(sha256sum "${source}" | cut -d' ' -f1)
  if docker config inspect "${name}" >/dev/null 2>&1; then
    deployed_digest=$(docker config inspect "${name}" --format '{{index .Spec.Labels "content-sha256"}}')
    [[ "${deployed_digest}" == "${digest}" ]] || {
      echo "${kind} config ${name} has different content; create a new versioned name." >&2
      return 1
    }
    actual_file=$(mktemp)
    docker config inspect "${name}" --format '{{printf "%s" .Spec.Data}}' > "${actual_file}"
    if [[ $(sha256sum "${actual_file}" | cut -d' ' -f1) != "${digest}" ]]; then
      rm -f "${actual_file}"
      echo "${kind} config ${name} content does not match its label." >&2
      return 1
    fi
    rm -f "${actual_file}"
  else
    missing_configs+=("${name}|${source}|${digest}")
  fi
}

prevalidate_swarm_secret() {
  local name=$1 source=$2 digest deployed_digest
  digest=$(sha256sum "${source}" | cut -d' ' -f1)
  if docker secret inspect "${name}" >/dev/null 2>&1; then
    deployed_digest=$(docker secret inspect "${name}" --format '{{index .Spec.Labels "content-sha256"}}')
    [[ "${deployed_digest}" == "${digest}" ]] || {
      echo "TLS private-key secret ${name} cannot be replaced in place; create a new versioned name." >&2
      return 1
    }
  else
    missing_secrets+=("${name}|${source}|${digest}")
  fi
}

prevalidate_network() {
  local name=$1 required_internal=$2 details
  if docker network inspect "${name}" >/dev/null 2>&1; then
    details=$(docker network inspect "${name}" --format '{{.Driver}} {{.Scope}} {{.Internal}} {{.Attachable}} {{index .Options "encrypted"}}')
    if [[ "${required_internal}" == "true" ]]; then
      [[ "${details}" == "overlay swarm true true true" ]] || {
        echo "Network ${name} must be an internal, attachable, encrypted Swarm overlay; got ${details}." >&2
        return 1
      }
    else
      [[ "${details}" == "overlay swarm false true true" ]] || {
        echo "Network ${name} must be an external, attachable, encrypted Swarm overlay; got ${details}." >&2
        return 1
      }
    fi
  else
    missing_networks+=("${name}|${required_internal}")
  fi
}

# Validate every immutable object, network, and rendered stack before crossing
# any host or Swarm mutation boundary.
[[ -f "${remote_dir}/compose.yml" && ! -L "${remote_dir}/compose.yml" \
  && -f "${remote_dir}/envs/canary/compose.yml" && ! -L "${remote_dir}/envs/canary/compose.yml" \
  && -f "${remote_dir}/config/runtrace-pg_hba.conf" && ! -L "${remote_dir}/config/runtrace-pg_hba.conf" \
  && -x "${remote_dir}/scripts/deploy-postgres-stack.sh" && ! -L "${remote_dir}/scripts/deploy-postgres-stack.sh" \
  && -x "${remote_dir}/scripts/brio-db-transaction.sh" && ! -L "${remote_dir}/scripts/brio-db-transaction.sh" ]] || {
  echo "Canary bundle inputs are missing or symlinked." >&2
  exit 1
}

# Recovery and first-deployment journal capture use the pre-existing shared
# PostgreSQL network, because the Brio-only network may not exist yet. Validate
# that transport boundary before a recovery helper can receive a superuser
# credential or connect to the database alias.
prevalidate_network "${db_network}" false
docker network inspect "${db_network}" >/dev/null 2>&1 || {
  echo "The pre-existing shared database network ${db_network} is required for crash-safe journal preparation." >&2
  exit 1
}

# A SIGKILL can leave immutable objects created by the interrupted run. Recover
# its root-owned journal before inventorying those objects so the current
# attempt cannot mistake interrupted-run state for its own validated pre-state.
require_brio_deployment_lease
recover_incomplete_journals

prevalidate_swarm_config "${tls_cert_config}" "${runtime_dir}/postgres-server-cert.pem" "TLS certificate"
prevalidate_swarm_secret "${tls_key_secret}" "${runtime_dir}/postgres-server-key.pem"
prevalidate_swarm_config "${hba_config}" "${remote_dir}/config/runtrace-pg_hba.conf" "HBA policy"
prevalidate_network "${le_petit_coin_network}" false
prevalidate_network "${brio_network}" true

export MAKEPAD_POSTGRES_DB_NETWORK="${db_network}"
export MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK="${le_petit_coin_network}"
export MAKEPAD_POSTGRES_BRIO_STAGING_DB_NETWORK="${brio_network}"
docker compose \
  --env-file "${db_env}" \
  --env-file "${env_deploy}" \
  -f "${remote_dir}/compose.yml" \
  -f "${remote_dir}/envs/canary/compose.yml" \
  config > "${runtime_dir}/candidate-stack.yml"
docker stack config --compose-file "${runtime_dir}/candidate-stack.yml" >/dev/null

: > "${runtime_dir}/prior-services.list"
: > "${runtime_dir}/prior-service-spec-hashes.list"
install -d -m 0700 "${runtime_dir}/prior-service-specs"
if docker stack services "${stack_name}" --format '{{.Name}}' > "${runtime_dir}/prior-services.list" 2>/dev/null \
  && [[ -s "${runtime_dir}/prior-services.list" ]]; then
  stack_preexisting=1
  while IFS= read -r service_name; do
    [[ "${service_name}" == "${stack_name}_"* ]] || {
      echo "Existing stack contains an unexpected service identity: ${service_name}" >&2
      exit 1
    }
    [[ $(docker service inspect "${service_name}" --format '{{index .Spec.Labels "com.docker.stack.namespace"}}') == "${stack_name}" ]] || {
      echo "Existing service ${service_name} does not carry the exact stack namespace label." >&2
      exit 1
    }
    if [[ "${service_name}" == "${stack_name}_keycloak_brio_staging_backup" ]]; then
      legacy_hash=$(docker service inspect "${service_name}" --format '{{json .Spec}}' | sha256sum | cut -d' ' -f1)
      echo "Legacy identity backup service ${service_name} is still present (spec sha256 ${legacy_hash})." >&2
      echo "Retire it through a separately reviewed operation only after standalone keycloak_brio_staging backup acceptance; this deployment will not prune it." >&2
      exit 1
    fi
    spec_file="${runtime_dir}/prior-service-specs/${service_name}.json"
    docker service inspect "${service_name}" --format '{{json .Spec}}' > "${spec_file}"
    [[ -s "${spec_file}" && ! -L "${spec_file}" ]] || { echo "Failed to inventory exact prior service spec." >&2; exit 1; }
    printf '%s|%s\n' "${service_name}" "$(sha256sum "${spec_file}" | cut -d' ' -f1)" \
      >> "${runtime_dir}/prior-service-spec-hashes.list"
  done < "${runtime_dir}/prior-services.list"
  grep -Fxq "${stack_name}_postgres" "${runtime_dir}/prior-services.list" || {
    echo "Existing canary stack does not contain its expected PostgreSQL service." >&2
    exit 1
  }
fi
[[ "${stack_preexisting}" == 1 ]] || {
  echo "Canary Brio provisioning requires a healthy pre-existing PostgreSQL stack so its database state can be journaled before mutation." >&2
  exit 1
}

# The durable root-owned transaction journal is staged atomically before the
# first host, Swarm, role, database, ACL, or service mutation.
docker run --rm \
  --mount type=bind,src=/etc,dst=/host/etc,readonly \
  --mount type=bind,src=/var/lib,dst=/host/var/lib,readonly \
  --mount type=bind,src=/var/lib/makepad,dst=/managed-var-lib \
  --mount "type=bind,src=${runtime_dir},dst=/runtime,readonly" \
  --mount "type=bind,src=${remote_dir}/scripts/brio-db-transaction.sh,dst=/input/brio-db-transaction.sh,readonly" \
  -e "DEPLOYMENT_ID=${deployment_id}" \
  "${validation_image}" sh -euc '
    case "$DEPLOYMENT_ID" in ""|*[!0-9-]*|*-*-*|-*|*-|0*|*-0*) exit 1 ;; esac
    case "$DEPLOYMENT_ID" in *-*) ;; *) exit 1 ;; esac
    root=/managed-var-lib/postgres-recovery/brio-canary
    stage="$root/.${DEPLOYMENT_ID}.staging"
    final="$root/$DEPLOYMENT_ID"
    for path in /managed-var-lib /managed-var-lib/postgres-recovery "$root"; do [ ! -L "$path" ] || exit 1; done
    install -d -o 0 -g 0 -m 0700 /managed-var-lib/postgres-recovery "$root"
    [ ! -e "$stage" ] && [ ! -L "$stage" ] && [ ! -e "$final" ] && [ ! -L "$final" ]
    install -d -o 0 -g 0 -m 0700 "$stage" "$stage/rollback" "$stage/database" "$stage/swarm"
    cat > "$stage/rollback/paths.list" <<"PATHS"
etc/makepad/secrets/postgres-canary-superuser-password
etc/makepad/tls/postgres/ca.crt
etc/makepad/secrets/postgres-brio-app-backup-password
etc/makepad/tls/backups/brio-recipient.crt
var/lib/makepad/postgres-backups/brio-staging
PATHS
    : > "$stage/rollback/present.list"
    : > "$stage/rollback/absent.list"
    while IFS= read -r path; do
      current=/host
      old_ifs=$IFS; IFS=/; set -- $path; IFS=$old_ifs
      for component do current="$current/$component"; [ ! -L "$current" ] || { echo "Snapshot path contains a symlink component." >&2; exit 1; }; done
      if [ -e "/host/$path" ]; then printf "%s\n" "$path" >> "$stage/rollback/present.list"; else printf "%s\n" "$path" >> "$stage/rollback/absent.list"; fi
    done < "$stage/rollback/paths.list"
    tar --numeric-owner --no-recursion -cpf "$stage/rollback/managed.tar" -C /host -T "$stage/rollback/present.list"
    backup=/host/var/lib/makepad/postgres-backups/brio-staging
    : > "$stage/rollback/backup-entries.list"
    if [ -d "$backup" ] && [ ! -L "$backup" ]; then
      find "$backup" -mindepth 1 -maxdepth 1 -printf "%f\n" | LC_ALL=C sort > "$stage/rollback/backup-entries.list"
      if [ -L "$backup/latest" ]; then readlink "$backup/latest" > "$stage/rollback/prior-latest-target"; fi
      if [ -f "$backup/last-success.json" ] && [ ! -L "$backup/last-success.json" ]; then
        cp -a "$backup/last-success.json" "$stage/rollback/prior-last-success.json"
      fi
    fi
    cp /runtime/prior-services.list "$stage/swarm/prior-services.list"
    cp /runtime/prior-service-spec-hashes.list "$stage/swarm/prior-service-spec-hashes.list"
    cp -a /runtime/prior-service-specs "$stage/swarm/specs"
    install -o 0 -g 0 -m 0700 /input/brio-db-transaction.sh "$stage/brio-db-transaction.sh"
    printf "%s\n" "$DEPLOYMENT_ID" > "$stage/deployment-id"
    chown -R 0:0 "$stage"
    find "$stage" -type d -exec chmod 0700 {} +
    find "$stage" -type f -exec chmod 0600 {} +
    sync -f "$stage" 2>/dev/null || sync
  '
journal_stage="${recovery_root}/.${deployment_id}.staging"
run_db_transaction prepare "${journal_stage}"
docker run --rm --mount type=bind,src=/var/lib/makepad,dst=/managed-var-lib \
  -e "DEPLOYMENT_ID=${deployment_id}" "${validation_image}" sh -euc '
    root=/managed-var-lib/postgres-recovery/brio-canary
    stage="$root/.${DEPLOYMENT_ID}.staging"; final="$root/$DEPLOYMENT_ID"
    [ -s "$stage/database/restore.sql" ] && [ -s "$stage/database/prestate.fingerprint" ]
    printf "%s\n" IN_PROGRESS > "$stage/IN_PROGRESS"; chmod 0600 "$stage/IN_PROGRESS"
    sync -f "$stage" 2>/dev/null || sync
    mv -T "$stage" "$final"
    sync -f "$root" 2>/dev/null || sync
  '

rollback_armed=1
journal_marker "${journal_dir}" STACK_MUTATION_ARMED
stack_mutated=1

for record in "${missing_networks[@]}"; do
  IFS='|' read -r name required_internal <<< "${record}"
  network_args=(--driver overlay --attachable --opt encrypted=true)
  [[ "${required_internal}" != "true" ]] || network_args+=(--internal)
  docker network create "${network_args[@]}" --label "makepad.brio.deployment-id=${deployment_id}" "${name}" >/dev/null
done
for record in "${missing_configs[@]}"; do
  IFS='|' read -r name source digest <<< "${record}"
  docker config create --label "content-sha256=${digest}" --label "makepad.brio.deployment-id=${deployment_id}" "${name}" "${source}" >/dev/null
done
for record in "${missing_secrets[@]}"; do
  IFS='|' read -r name source digest <<< "${record}"
  docker secret create --label "content-sha256=${digest}" --label "makepad.brio.deployment-id=${deployment_id}" "${name}" "${source}" >/dev/null
done

# Stage every replacement next to its final destination, then promote with
# same-filesystem renames. The exact snapshot above compensates any partial
# promotion or any later stack/bootstrap/backup failure.
stage_tag=${deployment_id}
docker run --rm \
  --mount "type=bind,src=${runtime_dir},dst=/runtime,readonly" \
  --mount type=bind,src=/etc,dst=/host/etc \
  --mount type=bind,src=/var/lib,dst=/host/var/lib \
  -e "STAGE_TAG=${stage_tag}" \
  "${postgres_image}" sh -euc '
    case "$STAGE_TAG" in ""|*[!0-9-]*|*-*-*|-*|*-|0*|*-0*) echo "Invalid stage identifier." >&2; exit 1 ;; esac
    case "$STAGE_TAG" in *-*) ;; *) echo "Invalid stage identifier." >&2; exit 1 ;; esac
    stage_run=${STAGE_TAG%-*}
    stage_attempt=${STAGE_TAG#*-}
    case "$stage_run:$stage_attempt" in *[!0-9:]*|:*|*:) echo "Invalid stage identifier." >&2; exit 1 ;; esac
    for path in \
      /host/etc /host/etc/makepad /host/etc/makepad/secrets \
      /host/etc/makepad/tls /host/etc/makepad/tls/postgres /host/etc/makepad/tls/backups \
      /host/var /host/var/lib /host/var/lib/makepad /host/var/lib/makepad/postgres-backups; do
      [ ! -L "$path" ] || { echo "Managed destination contains a symlink: $path" >&2; exit 1; }
    done
    super_stage="/host/etc/makepad/secrets/.postgres-canary-superuser-password.${STAGE_TAG}.stage"
    ca_stage="/host/etc/makepad/tls/postgres/.ca.crt.${STAGE_TAG}.stage"
    backup_stage="/host/etc/makepad/secrets/.postgres-brio-app-backup-password.${STAGE_TAG}.stage"
    recipient_stage="/host/etc/makepad/tls/backups/.brio-recipient.crt.${STAGE_TAG}.stage"
    super_final=/host/etc/makepad/secrets/postgres-canary-superuser-password
    ca_final=/host/etc/makepad/tls/postgres/ca.crt
    backup_final=/host/etc/makepad/secrets/postgres-brio-app-backup-password
    recipient_final=/host/etc/makepad/tls/backups/brio-recipient.crt
    cleanup() { rm -f -- "$super_stage" "$ca_stage" "$backup_stage" "$recipient_stage"; }
    trap cleanup EXIT HUP INT TERM
    for path in "$super_stage" "$ca_stage" "$backup_stage" "$recipient_stage"; do
      [ ! -e "$path" ] && [ ! -L "$path" ] || { echo "Refusing an existing stage path." >&2; exit 1; }
    done
    for path in "$super_final" "$ca_final" "$backup_final" "$recipient_final"; do
      [ ! -L "$path" ] && [ ! -d "$path" ] || { echo "Refusing an unsafe final managed path." >&2; exit 1; }
    done
    install -o 0 -g 0 -m 0600 /runtime/postgres-superuser-password "$super_stage"
    install -o 0 -g 0 -m 0444 /runtime/postgres-ca.pem "$ca_stage"
    install -o 999 -g 999 -m 0400 /runtime/brio-staging-backup-password "$backup_stage"
    install -o 0 -g 0 -m 0444 /runtime/brio-backup-recipient-cert.pem "$recipient_stage"
    mv -fT "$super_stage" "$super_final"
    mv -fT "$ca_stage" "$ca_final"
    mv -fT "$backup_stage" "$backup_final"
    mv -fT "$recipient_stage" "$recipient_final"
    install -d -o 999 -g 999 -m 0700 /host/var/lib/makepad/postgres-backups/brio-staging
    trap - EXIT HUP INT TERM
  '
[[ $(stat -c '%u:%a' "${superuser_host_file}") == "0:600" ]] || { echo "Canary superuser credential installation failed its ownership/mode check." >&2; exit 1; }
[[ $(stat -c '%u:%a' "${backup_host_file}") == "999:400" ]] || { echo "Canary backup credential installation failed its ownership/mode check." >&2; exit 1; }
[[ $(stat -c '%u:%a' "${backup_host_dir}") == "999:700" && ! -L "${backup_host_dir}" ]] || { echo "Canary backup directory installation failed its ownership/mode check." >&2; exit 1; }
for public_file in "${ca_host_file}" "${recipient_host_file}"; do
  public_mode=$(stat -c '%a' "${public_file}")
  if [[ $(stat -c '%u' "${public_file}") != "0" ]] || (( (8#${public_mode} & 8#022) != 0 )); then
    echo "Canary public certificate installation failed its ownership/mode check." >&2
    exit 1
  fi
done

case "${failure_injection}" in
  after-managed-file-promotion) echo "Injected failure after canary managed-file promotion." >&2; exit 96 ;;
  term-after-managed-file-promotion) kill -TERM "$$" ;;
  kill-after-managed-file-promotion) kill -KILL "$$" ;;
esac

"${remote_dir}/scripts/deploy-postgres-stack.sh" "${remote_dir}" "${stack_name}" canary
[[ "${failure_injection}" != "after-stack-deploy" ]] || { echo "Injected failure before canary bootstrap." >&2; exit 95; }

journal_marker "${journal_dir}" DATABASE_MUTATION_ARMED
db_mutated=1
docker run --rm --network "${brio_network}" \
  -v "${superuser_host_file}:/run/secrets/postgres_superuser_password:ro" \
  -v "${runtime_dir}/brio-staging-app-password:/run/secrets/brio_app_password:ro" \
  -v "${runtime_dir}/brio-staging-backup-password:/run/secrets/brio_backup_password:ro" \
  -v "${ca_host_file}:/etc/postgresql/ca.crt:ro" \
  -v "${remote_dir}/bootstrap/brio-staging-app.sql:/bootstrap/brio-staging-app.sql:ro" \
  "${postgres_image}" sh -euc '
    export PGPASSWORD="$(cat /run/secrets/postgres_superuser_password)"
    export PGSSLMODE=verify-full PGSSLROOTCERT=/etc/postgresql/ca.crt
    export BRIO_APP_PASSWORD="$(cat /run/secrets/brio_app_password)"
    export BRIO_BACKUP_PASSWORD="$(cat /run/secrets/brio_backup_password)"
    {
      printf "%s\n" "\\getenv brio_staging_app_password BRIO_APP_PASSWORD" "\\getenv brio_staging_backup_password BRIO_BACKUP_PASSWORD"
      cat /bootstrap/brio-staging-app.sql
    } > /tmp/bootstrap.sql
    exec psql -X -v ON_ERROR_STOP=1 -h makepad-postgres-brio-staging -U "$1" -d postgres -f /tmp/bootstrap.sql
  ' sh "${postgres_user}" >/dev/null

case "${failure_injection}" in
  after-bootstrap) echo "Injected failure after canary database bootstrap." >&2; exit 94 ;;
  kill-after-bootstrap) kill -KILL "$$" ;;
esac

run_role_query() {
  local password_file=$1 role=$2 database=$3 sslmode=$4 query=$5
  docker run --rm --network "${brio_network}" \
    -v "${password_file}:/run/secrets/role_password:ro" \
    -v "${ca_host_file}:/etc/postgresql/ca.crt:ro" \
    "${postgres_image}" sh -euc '
      export PGPASSWORD="$(cat /run/secrets/role_password)"
      export PGSSLMODE="$3" PGSSLROOTCERT=/etc/postgresql/ca.crt
      exec psql -X -At -h makepad-postgres-brio-staging -U "$1" -d "$2" -c "$4"
    ' sh "${role}" "${database}" "${sslmode}" "${query}"
}

alias_ip=$(docker run --rm --network "${brio_network}" "${postgres_image}" getent hosts makepad-postgres-brio-staging | awk 'NR == 1 {print $1}')
[[ -n "${alias_ip}" ]] || { echo "Brio database alias does not resolve on its isolated network." >&2; exit 1; }
if [[ $(run_role_query "${runtime_dir}/brio-staging-app-password" brio_staging_app brio_staging verify-full "select current_database() || ':' || current_user") != "brio_staging:brio_staging_app" ]]; then
  echo "Brio application role failed the verify-full identity probe." >&2
  exit 1
fi
[[ "${failure_injection}" != after-app-probe ]] || { echo "Injected failure after canary app probe." >&2; exit 93; }
if run_role_query "${runtime_dir}/brio-staging-app-password" brio_staging_app brio_staging disable "select 1" >/dev/null 2>&1; then
  echo "Plaintext access to brio_staging was unexpectedly accepted." >&2
  exit 1
fi
[[ "${failure_injection}" != after-plaintext-probe ]] || { echo "Injected failure after canary plaintext probe." >&2; exit 92; }
if run_role_query "${runtime_dir}/brio-staging-app-password" brio_staging_app postgres verify-full "select 1" >/dev/null 2>&1; then
  echo "Brio application role was unexpectedly accepted by a non-target database." >&2
  exit 1
fi
[[ "${failure_injection}" != after-nontarget-probe ]] || { echo "Injected failure after canary non-target probe." >&2; exit 91; }
if [[ $(run_role_query "${runtime_dir}/brio-staging-backup-password" brio_staging_backup brio_staging verify-full "show default_transaction_read_only") != "on" ]]; then
  echo "Brio backup role is not read-only." >&2
  exit 1
fi
[[ "${failure_injection}" != after-backup-role-probe ]] || { echo "Injected failure after canary backup-role probe." >&2; exit 90; }

previous_latest=$(docker run --rm --mount "type=bind,src=${backup_host_dir},dst=/backups,readonly" \
  "${validation_image}" sh -euc 'readlink /backups/latest 2>/dev/null || true')
backup_started_at=$(date +%s)
# A one-shot verifier creates no second Swarm service update, so PreviousSpec
# remains the exact predeployment spec and one rollback can restore it.
docker run --rm --network "${brio_network}" --user 999:999 --read-only \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=64m,mode=0700,uid=999,gid=999 \
  --mount "type=bind,src=${backup_host_dir},dst=/backups" \
  --mount "type=bind,src=${backup_host_file},dst=/run/secrets/postgres_backup_password,readonly" \
  --mount "type=bind,src=${ca_host_file},dst=/etc/postgresql/ca.crt,readonly" \
  --mount "type=bind,src=${recipient_host_file},dst=/etc/postgresql/brio-backup-recipient.crt,readonly" \
  --mount "type=bind,src=${remote_dir}/scripts/run-brio-encrypted-backup.sh,dst=/usr/local/bin/run-brio-encrypted-backup.sh,readonly" \
  -e PGHOST=makepad-postgres-brio-staging -e PGPORT=5432 -e PGUSER=brio_staging_backup \
  -e PGSSLMODE=verify-full -e PGSSLROOTCERT=/etc/postgresql/ca.crt \
  -e POSTGRES_BACKUP_PASSWORD_FILE=/run/secrets/postgres_backup_password \
  -e BRIO_BACKUP_DATABASE=brio_staging -e BRIO_BACKUP_ROOT=/backups \
  -e BRIO_BACKUP_RECIPIENT_CERT=/etc/postgresql/brio-backup-recipient.crt \
  -e BRIO_BACKUP_RETENTION_DAYS=35 \
  "${validation_image}" /usr/local/bin/run-brio-encrypted-backup.sh
backup_verified=0
for _ in $(seq 1 60); do
  if docker run --rm --mount "type=bind,src=${backup_host_dir},dst=/backups,readonly" \
    -e "BACKUP_STARTED_AT=${backup_started_at}" -e "PREVIOUS_LATEST=${previous_latest}" \
    "${validation_image}" sh -euc '
      status=/backups/last-success.json
      [ -s "$status" ] && [ "$(stat -c %Y "$status")" -ge "$BACKUP_STARTED_AT" ]
      grep -q "\"database\":\"brio_staging\"" "$status"
      grep -q "\"encrypted\":true" "$status"
      latest=$(readlink /backups/latest)
      case "$latest" in 20??????T??????Z) ;; *) exit 1 ;; esac
      [ "$latest" != "$PREVIOUS_LATEST" ]
      directory="/backups/$latest"
      [ -s "$directory/brio_staging.dump.cms" ] && [ -s "$directory/SHA256SUMS" ]
      (cd "$directory" && sha256sum --check --status SHA256SUMS)
      openssl cms -cmsout -inform DER -in "$directory/brio_staging.dump.cms" -noout >/dev/null 2>&1
    '; then
    backup_verified=1
    break
  fi
  sleep 2
done
[[ "${backup_verified}" == "1" ]] || { echo "A fresh validated encrypted brio_staging backup was not published." >&2; exit 1; }
[[ "${failure_injection}" != after-backup-verification ]] || { echo "Injected failure after canary backup verification." >&2; exit 89; }

journal_marker "${journal_dir}" COMMITTED
rollback_armed=0
remove_durable_journal "${journal_dir}"
echo "Brio canary PostgreSQL provisioning, bootstrap, transport policy, alias, and encrypted backup verification passed."
