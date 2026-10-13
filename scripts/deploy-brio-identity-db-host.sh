#!/usr/bin/env bash
set -euo pipefail

if (($# != 4)); then
  echo "Usage: deploy-brio-identity-db-host.sh <job-bundle-dir> <runtime-secret-dir> <db-certificate-ip> <keycloak-db-source-cidr>" >&2
  exit 2
fi

bundle_dir=$1
runtime_dir=$2
db_hostname=$3
keycloak_source_cidr=$4
live_dir=/srv/makepad/postgres
compose_project=postgres
expected_container_name=postgres-postgres-1
db_env="${bundle_dir}/envs/production/.env.db"
candidate_compose="${bundle_dir}/compose.host.yml"
rollback_armed=0
validation_image=
prior_postgres_image=
db_mutated=0
recovery_marker="${runtime_dir}/RECOVERY_REQUIRED"
recovery_root=/var/lib/makepad/postgres-recovery/brio-identity
recovery_id=${runtime_dir##*/postgres-brio-identity-runtime-}
recovery_evidence="${recovery_root}/${recovery_id}"
journal_dir=${recovery_evidence}
failure_injection=${BRIO_DEPLOY_FAILURE_INJECTION:-}

if [[ -n "${failure_injection}" ]]; then
  [[ "${BRIO_DEPLOY_TEST_MODE:-}" == "isolated-container" && -f /.dockerenv ]] || {
    echo "Failure injection is permitted only in the isolated deployment test container." >&2
    exit 2
  }
  case "${failure_injection}" in
    after-managed-file-promotion|term-after-managed-file-promotion|kill-after-managed-file-promotion|after-bootstrap|kill-after-bootstrap|after-app-probe|after-plaintext-probe|after-nontarget-probe|after-backup-role-probe|after-backup-verification|rollback-restore|rollback-recreate) ;;
    *) echo "Unsupported identity deployment failure injection." >&2; exit 2 ;;
  esac
fi

[[ "${BRIO_IDENTITY_DB_DEPLOY_CONFIRM:-}" == "restart-standalone-postgres-for-brio-staging" ]] || {
  echo "Set BRIO_IDENTITY_DB_DEPLOY_CONFIRM to the exact standalone DB restart acknowledgement." >&2
  exit 2
}
[[ "${BRIO_IDENTITY_DB_BACKUP_RESTORE_CONFIRMED:-}" == "yes" ]] || {
  echo "A successful current backup/restore gate must be confirmed before changing the standalone DB VM." >&2
  exit 2
}
[[ "${bundle_dir}" =~ ^/tmp/postgres-brio-identity-bundle-[0-9]+-[0-9]+$ ]] || {
  echo "job-bundle-dir must be /tmp/postgres-brio-identity-bundle-<run>-<attempt>." >&2
  exit 2
}
[[ "${runtime_dir}" =~ ^/tmp/postgres-brio-identity-runtime-[0-9]+-[0-9]+$ ]] || {
  echo "runtime-secret-dir must be /tmp/postgres-brio-identity-runtime-<run>-<attempt>." >&2
  exit 2
}
[[ "${db_hostname}" == "65.21.134.125" ]] || {
  echo "The Brio identity certificate endpoint must be the reviewed standalone DB IP 65.21.134.125." >&2
  exit 2
}
[[ "${keycloak_source_cidr}" == "88.99.209.165/32" ]] || {
  echo "The Keycloak source must be the reviewed exact egress 88.99.209.165/32." >&2
  exit 2
}

read_setting() {
  local name=$1 file=$2 value
  value=$(grep -E "^${name}=" "${file}" | tail -n 1 | cut -d= -f2-)
  [[ -n "${value}" ]] || { echo "${name} is missing or empty in ${file}." >&2; exit 1; }
  printf '%s' "${value}"
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
    [[ -n "${component}" && "${component}" != . && "${component}" != .. ]] || return 1
    current="${current}/${component}"
    [[ ! -L "${current}" ]] || {
      echo "Managed path contains a symlink component: ${current}" >&2
      return 1
    }
  done
}

validate_postgres_target() {
  local expected_image=$1 container_id container_name project_label service_label oneoff_label
  local network_mode actual_image data_mount running health
  container_id=$(docker container inspect "${expected_container_name}" --format '{{.Id}}' 2>/dev/null) || {
    echo "Expected standalone container ${expected_container_name} was not found." >&2
    return 1
  }
  container_name=$(docker container inspect "${container_id}" --format '{{.Name}}')
  project_label=$(docker container inspect "${container_id}" --format '{{index .Config.Labels "com.docker.compose.project"}}')
  service_label=$(docker container inspect "${container_id}" --format '{{index .Config.Labels "com.docker.compose.service"}}')
  oneoff_label=$(docker container inspect "${container_id}" --format '{{index .Config.Labels "com.docker.compose.oneoff"}}')
  network_mode=$(docker container inspect "${container_id}" --format '{{.HostConfig.NetworkMode}}')
  actual_image=$(docker container inspect "${container_id}" --format '{{.Config.Image}}')
  data_mount=$(docker container inspect "${container_id}" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{printf "%s|%s|%t\n" .Type .Source .RW}}{{end}}{{end}}')
  running=$(docker container inspect "${container_id}" --format '{{.State.Running}}')
  health=$(docker container inspect "${container_id}" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}')
  [[ "${container_name}" == "/${expected_container_name}" \
    && "${project_label}" == "${compose_project}" \
    && "${service_label}" == "postgres" \
    && "${oneoff_label}" == "False" \
    && "${network_mode}" == "host" \
    && "${actual_image}" == "${expected_image}" \
    && "${data_mount}" == 'bind|/var/lib/makepad/postgres|true' \
    && "${running}" == "true" && "${health}" == "healthy" ]] || {
    echo "The standalone target failed its exact Compose label, image, host-network, data-bind, or health contract." >&2
    return 1
  }
  printf '%s' "${container_id}"
}

restore_snapshot() {
  local source_journal=${1:-${journal_dir}}
  docker run --rm \
    --mount "type=bind,src=${live_dir},dst=/managed/live" \
    --mount type=bind,src=/etc/makepad,dst=/managed/etc \
    --mount type=bind,src=/var/lib/makepad,dst=/managed-var-lib \
    --mount "type=bind,src=${source_journal}/rollback,dst=/rollback,readonly" \
    "${validation_image}" sh -euc '
      backup=/managed-var-lib/postgres-backups/keycloak-brio-staging
      parent=${backup%/*}
      [ -d "$parent" ] && [ ! -L "$parent" ]
      if [ -e "$backup" ] || [ -L "$backup" ]; then
        [ -d "$backup" ] && [ ! -L "$backup" ] || { echo "Identity backup rollback target is unsafe." >&2; exit 1; }
        find "$backup" -depth -delete
      fi
      if [ -f /rollback/identity-backups.tar ] && [ ! -L /rollback/identity-backups.tar ]; then
        tar -tf /rollback/identity-backups.tar | while IFS= read -r member; do
          case "$member" in postgres-backups/keycloak-brio-staging|postgres-backups/keycloak-brio-staging/*) ;; *) exit 1 ;; esac
        done
        tar --numeric-owner -xpf /rollback/identity-backups.tar -C /managed-var-lib
      elif [ ! -f /rollback/identity-backup-absent ]; then
        echo "Identity backup snapshot contract is incomplete." >&2
        exit 1
      fi
      while IFS= read -r path; do
        case "$path" in
          live/compose.host.yml|live/envs/production/.env.db|live/config/brio-shared-pg_hba.conf|live/bootstrap/keycloak-brio-staging.sql|live/scripts/run-runtrace-backup.sh|live/scripts/run-runtrace-backup-loop.sh|live/scripts/run-brio-encrypted-backup.sh|live/scripts/run-brio-encrypted-backup-loop.sh|etc/secrets/postgres-brio-identity-backup-password|etc/tls/backups/brio-recipient.crt) ;;
          *) echo "Refusing an unexpected rollback path." >&2; exit 1 ;;
        esac
        rm -f -- "/managed/$path"
      done < /rollback/absent.list
      tar --numeric-owner -xpf /rollback/managed.tar -C /managed
    '
}

run_db_transaction() {
  local operation=$1 source_journal=${2:-${journal_dir}} helper
  if [[ "${operation}" == prepare ]]; then
    helper="${bundle_dir}/scripts/brio-db-transaction.sh"
  else
    helper="${source_journal}/brio-db-transaction.sh"
  fi
  [[ -f "${helper}" && ! -L "${helper}" ]] || {
    echo "The durable database compensation helper is unavailable." >&2
    return 1
  }
  docker run --rm --network host \
    --mount "type=bind,src=${helper},dst=/usr/local/bin/brio-db-transaction.sh,readonly" \
    --mount "type=bind,src=${source_journal},dst=/journal" \
    --mount "type=bind,src=${superuser_host_file},dst=/run/secrets/postgres_superuser_password,readonly" \
    --mount "type=bind,src=${ca_host_file},dst=/etc/postgresql/ca.crt,readonly" \
    -e "PGUSER=${postgres_user}" -e "PGHOST=${db_hostname}" -e PGHOSTADDR=127.0.0.1 \
    -e PGSSLMODE=verify-full -e PGSSLROOTCERT=/etc/postgresql/ca.crt \
    -e PGPASSWORD_FILE=/run/secrets/postgres_superuser_password \
    "${postgres_image}" /usr/local/bin/brio-db-transaction.sh "${operation}" keycloak /journal/database
}

journal_marker() {
  local source_journal=$1 marker=$2
  case "${marker}" in IN_PROGRESS|DATABASE_MUTATION_ARMED|COMMITTED|ROLLED_BACK|RECOVERY_REQUIRED) ;;
    *) echo "Refusing an unsupported journal marker." >&2; return 1 ;;
  esac
  docker run --rm --mount "type=bind,src=${source_journal},dst=/journal" \
    -e "MARKER=${marker}" "${validation_image}" sh -euc '
      case "$MARKER" in IN_PROGRESS|DATABASE_MUTATION_ARMED|COMMITTED|ROLLED_BACK|RECOVERY_REQUIRED) ;; *) exit 1 ;; esac
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
      case "$JOURNAL" in /var/lib/makepad/postgres-recovery/brio-identity/*) identifier=${JOURNAL##*/} ;; *) exit 1 ;; esac
      case "$identifier" in ""|*[!0-9-]*|*-*-*|-*|*-|0*|*-0*) exit 1 ;; esac
      case "$identifier" in *-*) ;; *) exit 1 ;; esac
      relative=${JOURNAL#/var/lib/makepad}
      target="/managed-var-lib$relative"
      [ -d "$target" ] && [ ! -L "$target" ]
      find "$target" -depth -delete
      sync -f /managed-var-lib/postgres-recovery/brio-identity 2>/dev/null || sync
    '
}

recover_incomplete_journals() {
  local current_id="${recovery_id}" current_journal="${journal_dir}" pending saved_injection="${failure_injection}" marker_list
  marker_list=$(docker run --rm --mount type=bind,src=/var/lib/makepad,dst=/managed-var-lib,readonly \
    "${validation_image}" sh -euc '
      root=/managed-var-lib/postgres-recovery/brio-identity
      [ ! -e "$root" ] && exit 0
      [ -d "$root" ] && [ ! -L "$root" ]
      for candidate in "$root"/* "$root"/.*; do
        [ -e "$candidate" ] || continue
        name=${candidate##*/}
        case "$name" in .|..) continue ;; .*.staging) echo "INCOMPLETE-STAGE:$name"; continue ;; esac
        case "$name" in ""|*[!0-9-]*|*-*-*|-*|*-|0*|*-0*) echo "UNSAFE:$name"; continue ;; esac
        case "$name" in *-*) ;; *) echo "UNSAFE:$name"; continue ;; esac
        [ -d "$candidate" ] && [ ! -L "$candidate" ] || { echo "UNSAFE:$name"; continue; }
        if [ -f "$candidate/COMMITTED" ] && [ ! -L "$candidate/COMMITTED" ]; then
          echo "COMMITTED:$name"
        elif [ -f "$candidate/ROLLED_BACK" ] && [ ! -L "$candidate/ROLLED_BACK" ]; then
          echo "ROLLED_BACK:$name"
        elif [ -f "$candidate/IN_PROGRESS" ] && [ ! -L "$candidate/IN_PROGRESS" ]; then
          echo "PENDING:$name"
        else
          echo "UNSAFE:$name"
        fi
      done
    ')
  while IFS=: read -r state identifier; do
    [[ -n "${state}" ]] || continue
    case "${state}" in
      COMMITTED|ROLLED_BACK)
        remove_durable_journal "${recovery_root}/${identifier}"
        ;;
      PENDING)
        pending="${recovery_root}/${identifier}"
        recovery_id=${identifier}
        journal_dir=${pending}
        recovery_evidence=${pending}
        prior_postgres_image=$(docker run --rm --mount "type=bind,src=${pending},dst=/journal,readonly" \
          "${validation_image}" sh -euc 'cat /journal/prior-postgres-image')
        [[ "${prior_postgres_image}" == *@sha256:* ]] || { echo "Recovery journal has an invalid prior image." >&2; return 1; }
        db_mutated=$(docker run --rm --mount "type=bind,src=${pending},dst=/journal,readonly" \
          "${validation_image}" sh -euc 'if [ -f /journal/DATABASE_MUTATION_ARMED ] && [ ! -L /journal/DATABASE_MUTATION_ARMED ]; then echo 1; else echo 0; fi')
        failure_injection=
        rollback_armed=1
        if ! rollback_deployment; then
          # Do not let the outer EXIT trap attempt the same failed recovery a
          # second time. Its durable journal and marker are now authoritative.
          rollback_armed=0
          preserve_recovery_evidence || true
          echo "An interrupted Brio identity database transaction could not be recovered." >&2
          return 1
        fi
        rollback_armed=0
        ;;
      INCOMPLETE-STAGE|UNSAFE)
        echo "Unsafe or incomplete durable Brio identity journal detected: ${identifier}" >&2
        return 1
        ;;
      *) echo "Unexpected durable journal state." >&2; return 1 ;;
    esac
  done <<< "${marker_list}"
  recovery_id=${current_id}
  journal_dir=${current_journal}
  recovery_evidence=${current_journal}
  failure_injection=${saved_injection}
  db_mutated=0
}

rollback_deployment() {
  local rollback_status=0
  echo "Deployment failed after the mutation boundary; restoring the exact managed-file snapshot." >&2
  if [[ "${failure_injection}" == "rollback-restore" ]]; then
    rollback_status=1
  else
    restore_snapshot "${journal_dir}" || rollback_status=1
  fi
  export MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_DB_HOST="${db_hostname}"
  export MAKEPAD_POSTGRES_RUNTRACE_HBA_HOST_PATH="${live_dir}/config/brio-shared-pg_hba.conf"
  export MAKEPAD_POSTGRES_BACKUP_SCRIPT_HOST_PATH="${live_dir}/scripts/run-runtrace-backup.sh"
  export MAKEPAD_POSTGRES_BACKUP_LOOP_SCRIPT_HOST_PATH="${live_dir}/scripts/run-runtrace-backup-loop.sh"
  export MAKEPAD_POSTGRES_BRIO_BACKUP_SCRIPT_HOST_PATH="${live_dir}/scripts/run-brio-encrypted-backup.sh"
  export MAKEPAD_POSTGRES_BRIO_BACKUP_LOOP_SCRIPT_HOST_PATH="${live_dir}/scripts/run-brio-encrypted-backup-loop.sh"
  if [[ "${failure_injection}" == "rollback-recreate" ]]; then
    rollback_status=1
  else
    docker compose --project-name postgres \
      --env-file "${live_dir}/envs/production/.env.db" \
      -f "${live_dir}/compose.host.yml" \
      up -d --remove-orphans --wait --force-recreate || rollback_status=1
  fi
  validate_postgres_target "${prior_postgres_image}" >/dev/null || rollback_status=1
  if [[ "${db_mutated}" == "1" || -f "${journal_dir}/DATABASE_MUTATION_ARMED" ]]; then
    run_db_transaction restore "${journal_dir}" || rollback_status=1
  fi
  if [[ "${rollback_status}" == "0" ]]; then
    journal_marker "${journal_dir}" ROLLED_BACK || rollback_status=1
  fi
  if [[ "${rollback_status}" == "0" ]]; then
    remove_durable_journal "${journal_dir}" || rollback_status=1
  fi
  if [[ "${rollback_status}" == "0" ]]; then
    echo "Managed files and the prior healthy postgres Compose target were restored." >&2
  else
    echo "Automatic rollback did not restore a healthy exact target; operator intervention is required." >&2
  fi
  return "${rollback_status}"
}

preserve_recovery_evidence() {
  # The rollback archive can contain the former managed backup credential. Keep
  # it outside /tmp, root-owned and unreadable to the deploy account. The
  # runtime marker contains only the fixed evidence path and run identifier.
  {
    printf 'recovery_evidence=%s\n' "${recovery_evidence}"
    printf 'deployment_id=%s\n' "${recovery_id}"
  } > "${recovery_marker}"
  chmod 0600 "${recovery_marker}"
  journal_marker "${journal_dir}" RECOVERY_REQUIRED
  echo "Root-protected recovery evidence retained at ${recovery_evidence}." >&2
}

cleanup_runtime() {
  local cleanup_status=0
  # Incoming application/backup passwords and recipient material are always
  # removed, including when rollback itself failed.
  for name in keycloak-brio-staging-app-password keycloak-brio-staging-backup-password brio-backup-recipient-cert.pem; do
    [[ ! -f "${runtime_dir}/${name}" || -L "${runtime_dir}/${name}" ]] || rm -f -- "${runtime_dir:?}/${name}" || cleanup_status=1
  done
  if [[ -f "${recovery_marker}" && ! -L "${recovery_marker}" ]]; then
    # The protected snapshot and marker are deliberately exempt from normal and
    # TTL cleanup until an operator has completed recovery.
    rm -f -- "${runtime_dir}/runtrace-pg_hba.conf" "${runtime_dir}/candidate-compose.yml" || cleanup_status=1
    return "${cleanup_status}"
  fi
  if [[ -e "${recovery_marker}" || -L "${recovery_marker}" ]]; then
    echo "Unsafe recovery marker type; preserving the runtime directory for operator inspection." >&2
    return 1
  fi
  if [[ -n "${validation_image}" ]] && docker image inspect "${validation_image}" >/dev/null 2>&1; then
    docker run --rm --mount "type=bind,src=${runtime_dir},dst=/runtime" "${validation_image}" \
      sh -euc 'for path in /runtime/runtrace-pg_hba.conf /runtime/candidate-compose.yml; do [ ! -e "$path" ] || find "$path" -depth -delete; done' \
      >/dev/null 2>&1 || cleanup_status=1
  fi
  rmdir -- "${runtime_dir}" 2>/dev/null || true
  return "${cleanup_status}"
}

handle_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${rollback_armed}" == "1" ]]; then
    if ! rollback_deployment; then
      preserve_recovery_evidence || {
        echo "CRITICAL: rollback and durable recovery-evidence preservation both failed." >&2
        status=1
      }
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

swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}')
[[ "${swarm_state}" == "inactive" ]] || {
  echo "Refusing to run the standalone DB-VM deployment on a Docker Swarm node (state: ${swarm_state})." >&2
  exit 1
}

for candidate in \
  "${candidate_compose}" \
  "${db_env}" \
  "${bundle_dir}/config/brio-shared-pg_hba.conf" \
  "${bundle_dir}/bootstrap/keycloak-brio-staging.sql" \
  "${bundle_dir}/scripts/run-runtrace-backup.sh" \
  "${bundle_dir}/scripts/run-runtrace-backup-loop.sh" \
  "${bundle_dir}/scripts/run-brio-encrypted-backup.sh" \
  "${bundle_dir}/scripts/run-brio-encrypted-backup-loop.sh" \
  "${bundle_dir}/scripts/brio-db-transaction.sh"; do
  [[ -f "${candidate}" && ! -L "${candidate}" ]] || { echo "Candidate bundle file is missing or a symlink: ${candidate}" >&2; exit 1; }
done

postgres_image=$(read_setting POSTGRES_IMAGE "${db_env}")
validation_image=$(read_setting BRIO_BACKUP_IMAGE "${db_env}")
postgres_user=$(read_setting POSTGRES_USER "${db_env}")
data_host_dir=$(read_setting MAKEPAD_POSTGRES_DATA_PATH "${db_env}")
superuser_host_file=$(read_setting MAKEPAD_POSTGRES_SUPERUSER_PASSWORD_FILE_HOST_PATH "${db_env}")
server_cert_host_file=$(read_setting MAKEPAD_POSTGRES_TLS_CERT_HOST_PATH "${db_env}")
server_key_host_file=$(read_setting MAKEPAD_POSTGRES_TLS_KEY_HOST_PATH "${db_env}")
ca_host_file=$(read_setting MAKEPAD_POSTGRES_CA_CERT_HOST_PATH "${db_env}")
hba_host_file=$(read_setting MAKEPAD_POSTGRES_RUNTRACE_HBA_HOST_PATH "${db_env}")
backup_host_file=$(read_setting MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_PASSWORD_FILE_HOST_PATH "${db_env}")
recipient_host_file=$(read_setting MAKEPAD_POSTGRES_BRIO_BACKUP_RECIPIENT_CERT_HOST_PATH "${db_env}")
backup_host_dir=$(read_setting MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_PATH "${db_env}")

[[ "${postgres_image}" == *@sha256:* && "${validation_image}" == *@sha256:* ]] || { echo "Candidate images must be digest pinned." >&2; exit 1; }
[[ "${data_host_dir}" == "/var/lib/makepad/postgres" \
  && "${superuser_host_file}" == "/etc/makepad/secrets/postgres-superuser-password" \
  && "${server_cert_host_file}" == "/etc/makepad/tls/postgres/server.crt" \
  && "${server_key_host_file}" == "/etc/makepad/secrets/postgres-server.key" \
  && "${ca_host_file}" == "/etc/makepad/tls/postgres/ca.crt" \
  && "${hba_host_file}" == "/srv/makepad/postgres/config/brio-shared-pg_hba.conf" \
  && "${backup_host_file}" == "/etc/makepad/secrets/postgres-brio-identity-backup-password" \
  && "${recipient_host_file}" == "/etc/makepad/tls/backups/brio-recipient.crt" \
  && "${backup_host_dir}" == "/var/lib/makepad/postgres-backups/keycloak-brio-staging" ]] || {
  echo "Candidate environment does not match the exact standalone DB-VM path contract." >&2
  exit 1
}
expected_data_bind="\"\${MAKEPAD_POSTGRES_DATA_PATH:-/var/lib/makepad/postgres}:/var/lib/postgresql/data\""
if ! grep -Fq 'network_mode: host' "${candidate_compose}" \
  || ! grep -Fq "${expected_data_bind}" "${candidate_compose}"; then
  echo "Candidate Compose does not declare the reviewed host network and exact PostgreSQL data bind." >&2
  exit 1
fi

runtime_mode=$(stat -c '%a' "${runtime_dir}")
[[ ! -L "${runtime_dir}" && "${runtime_mode}" == "700" ]] || { echo "Runtime directory must be a non-symlink with mode 0700." >&2; exit 1; }
for input in keycloak-brio-staging-app-password keycloak-brio-staging-backup-password brio-backup-recipient-cert.pem; do
  input_path="${runtime_dir}/${input}"
  [[ -s "${input_path}" && ! -L "${input_path}" && $(stat -c '%a' "${input_path}") == "600" ]] || {
    echo "Required runtime input must be non-empty, non-symlinked, and mode 0600: ${input}" >&2
    exit 1
  }
done
for password_file in keycloak-brio-staging-app-password keycloak-brio-staging-backup-password; do
  if [[ $(awk 'END { print NR }' "${runtime_dir}/${password_file}") -ne 1 ]] || grep -q $'\r' "${runtime_dir}/${password_file}"; then
    echo "Password input must contain one line and no carriage return: ${password_file}" >&2
    exit 1
  fi
done
cmp -s "${runtime_dir}/keycloak-brio-staging-app-password" "${runtime_dir}/keycloak-brio-staging-backup-password" \
  && { echo "Keycloak Brio application and backup credentials must be distinct." >&2; exit 1; }

for live_input in \
  "${live_dir}/compose.host.yml" \
  "${live_dir}/envs/production/.env.db" \
  "${live_dir}/config/brio-shared-pg_hba.conf" \
  "${live_dir}/scripts/run-runtrace-backup.sh" \
  "${live_dir}/scripts/run-runtrace-backup-loop.sh" \
  "${superuser_host_file}" "${server_cert_host_file}" "${server_key_host_file}" "${ca_host_file}"; do
  [[ -s "${live_input}" && ! -L "${live_input}" ]] || { echo "Required existing DB-VM input is unavailable or unsafe: ${live_input}" >&2; exit 1; }
done
for managed_path in \
  "${live_dir}" "${live_dir}/compose.host.yml" "${live_dir}/envs/production" "${live_dir}/envs/production/.env.db" \
  "${live_dir}/config" "${hba_host_file}" "${live_dir}/bootstrap" "${live_dir}/scripts" \
  "${superuser_host_file}" "${server_cert_host_file}" "${server_key_host_file}" "${ca_host_file}" \
  "${backup_host_file}" "${recipient_host_file}" "${backup_host_dir}" \
  /var/lib/makepad/postgres-backups /var/lib/makepad/postgres-recovery; do
  assert_no_symlink_components "${managed_path}"
done
for exact_parent in \
  /srv /srv/makepad "${live_dir}" "${live_dir}/envs" "${live_dir}/envs/production" \
  "${live_dir}/config" "${live_dir}/bootstrap" "${live_dir}/scripts" \
  /etc /etc/makepad /etc/makepad/secrets /etc/makepad/tls /etc/makepad/tls/postgres \
  /var /var/lib /var/lib/makepad /var/lib/makepad/postgres-backups; do
  [[ -d "${exact_parent}" && ! -L "${exact_parent}" ]] || {
    echo "Required managed parent is missing, symlinked, or not a directory: ${exact_parent}" >&2
    exit 1
  }
done
[[ $(stat -c '%u:%a' "${superuser_host_file}") == "0:600" ]] || { echo "Existing PostgreSQL superuser credential must be root-owned with mode 0600." >&2; exit 1; }
for public_file in "${server_cert_host_file}" "${ca_host_file}"; do
  public_mode=$(stat -c '%a' "${public_file}")
  if [[ $(stat -c '%u' "${public_file}") != "0" ]] || (( (8#${public_mode} & 8#022) != 0 )); then
    echo "Existing PostgreSQL public TLS files must be root-owned and not group/world writable." >&2
    exit 1
  fi
done
key_uid=$(stat -c '%u' "${server_key_host_file}")
key_gid=$(stat -c '%g' "${server_key_host_file}")
key_mode=$(stat -c '%a' "${server_key_host_file}")
[[ "${key_uid}:${key_gid}:${key_mode}" == "70:70:400" ]] || {
  echo "Existing PostgreSQL server key must retain the verified 70:70 mode-0400 contract." >&2
  exit 1
}
for optional_managed in "${backup_host_file}" "${recipient_host_file}"; do
  [[ ! -L "${optional_managed}" ]] || { echo "Refusing a symlink at a managed identity backup path." >&2; exit 1; }
done
if [[ -L "${backup_host_dir}" || ( -e "${backup_host_dir}" && ! -d "${backup_host_dir}" ) ]]; then
  echo "Refusing a symlink or non-directory Brio identity backup path." >&2
  exit 1
fi

command -v openssl >/dev/null 2>&1 || { echo "openssl is required." >&2; exit 1; }
openssl x509 -in "${server_cert_host_file}" -noout -checkend 604800 >/dev/null
openssl x509 -in "${server_cert_host_file}" -noout -checkip "${db_hostname}" >/dev/null
openssl verify -purpose sslserver -CAfile "${ca_host_file}" "${server_cert_host_file}" >/dev/null
cert_key_hash=$(openssl x509 -in "${server_cert_host_file}" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
private_key_hash=$(docker run --rm --mount "type=bind,src=${server_key_host_file},dst=/runtime/server.key,readonly" \
  "${validation_image}" openssl pkey -in /runtime/server.key -pubout -outform DER | sha256sum | cut -d' ' -f1)
[[ "${cert_key_hash}" == "${private_key_hash}" ]] || { echo "Existing DB-VM server certificate and key do not match." >&2; exit 1; }
if grep -q -- 'PRIVATE KEY' "${runtime_dir}/brio-backup-recipient-cert.pem" \
  || ! openssl x509 -in "${runtime_dir}/brio-backup-recipient-cert.pem" -noout -checkend 604800 >/dev/null \
  || ! printf 'brio-backup-preflight' | openssl cms -encrypt -binary -stream -outform DER -aes-256-gcm \
    -recip "${runtime_dir}/brio-backup-recipient-cert.pem" -out /dev/null; then
  echo "Brio backup recipient is not a valid public encryption certificate." >&2
  exit 1
fi

rendered_hba="${runtime_dir}/runtrace-pg_hba.conf"
awk -v cidr="${keycloak_source_cidr}" '
  $1 == "hostssl" && $2 == "keycloak_brio_staging" && $3 == "keycloak_brio_staging_app" && $4 == "all" && $5 == "scram-sha-256" {
    print "hostssl keycloak_brio_staging keycloak_brio_staging_app 127.0.0.1/32 scram-sha-256"
    print "hostssl keycloak_brio_staging keycloak_brio_staging_app " cidr " scram-sha-256"
    next
  }
  { print }
' "${bundle_dir}/config/brio-shared-pg_hba.conf" > "${rendered_hba}"
chmod 0600 "${rendered_hba}"
app_allow_line=$(grep -n -E "^hostssl keycloak_brio_staging[[:space:]]+keycloak_brio_staging_app[[:space:]]+${keycloak_source_cidr//./\.}[[:space:]]+scram-sha-256$" "${rendered_hba}" | cut -d: -f1)
backup_allow_line=$(grep -n -E '^hostssl keycloak_brio_staging[[:space:]]+keycloak_brio_staging_backup[[:space:]]+127\.0\.0\.1/32[[:space:]]+scram-sha-256$' "${rendered_hba}" | cut -d: -f1)
app_reject_line=$(grep -n -E '^host[[:space:]]+all[[:space:]]+keycloak_brio_staging_app[[:space:]]+all[[:space:]]+reject$' "${rendered_hba}" | cut -d: -f1)
backup_reject_line=$(grep -n -E '^host[[:space:]]+all[[:space:]]+keycloak_brio_staging_backup[[:space:]]+all[[:space:]]+reject$' "${rendered_hba}" | cut -d: -f1)
if [[ -z "${app_allow_line}" || -z "${backup_allow_line}" || -z "${app_reject_line}" || -z "${backup_reject_line}" \
  || "${app_allow_line}" -ge "${app_reject_line}" || "${backup_allow_line}" -ge "${backup_reject_line}" \
  || $(grep -Ec '^hostssl keycloak_brio_staging[[:space:]]+keycloak_brio_staging_app[[:space:]]+127\.0\.0\.1/32[[:space:]]+scram-sha-256$' "${rendered_hba}") -ne 1 \
  || $(grep -Ec "^hostssl keycloak_brio_staging[[:space:]]+keycloak_brio_staging_app[[:space:]]+${keycloak_source_cidr//./\.}[[:space:]]+scram-sha-256$" "${rendered_hba}") -ne 1 ]] \
  || grep -Eq '^hostssl keycloak_brio_staging[[:space:]]+keycloak_brio_staging_app[[:space:]]+all[[:space:]]' "${rendered_hba}"; then
  echo "Failed to render ordered, exact source-restricted Keycloak Brio HBA rules." >&2
  exit 1
fi

export MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_DB_HOST="${db_hostname}"
export MAKEPAD_POSTGRES_RUNTRACE_HBA_HOST_PATH="${hba_host_file}"
export MAKEPAD_POSTGRES_BACKUP_SCRIPT_HOST_PATH="${live_dir}/scripts/run-runtrace-backup.sh"
export MAKEPAD_POSTGRES_BACKUP_LOOP_SCRIPT_HOST_PATH="${live_dir}/scripts/run-runtrace-backup-loop.sh"
export MAKEPAD_POSTGRES_BRIO_BACKUP_SCRIPT_HOST_PATH="${live_dir}/scripts/run-brio-encrypted-backup.sh"
export MAKEPAD_POSTGRES_BRIO_BACKUP_LOOP_SCRIPT_HOST_PATH="${live_dir}/scripts/run-brio-encrypted-backup-loop.sh"
candidate_compose_command=(docker compose --project-name postgres --env-file "${db_env}" -f "${candidate_compose}")
"${candidate_compose_command[@]}" config --quiet
"${candidate_compose_command[@]}" config > "${runtime_dir}/candidate-compose.yml"
if ! grep -Fq 'network_mode: host' "${runtime_dir}/candidate-compose.yml" \
  || ! grep -Fq 'source: /var/lib/makepad/postgres' "${runtime_dir}/candidate-compose.yml" \
  || ! grep -Fq 'target: /var/lib/postgresql/data' "${runtime_dir}/candidate-compose.yml"; then
  echo "Rendered candidate Compose failed the host-network or exact data-bind prevalidation." >&2
  exit 1
fi

prior_container_id=$(validate_postgres_target "${postgres_image}")
prior_postgres_image=$(docker container inspect "${prior_container_id}" --format '{{.Config.Image}}')
docker pull "${postgres_image}" >/dev/null
docker pull "${validation_image}" >/dev/null

# A SIGKILL cannot run shell traps. Recover any root-owned transaction journal
# left by an interrupted prior deployment before creating a new mutation.
recover_incomplete_journals

# Build the complete root-owned journal at a same-filesystem staging path. It
# includes exact managed files and a compensating database-state program before
# the first host, Compose, role, database, ACL, or backup-service mutation.
docker run --rm \
  --mount "type=bind,src=${live_dir},dst=/managed/live,readonly" \
  --mount type=bind,src=/etc/makepad,dst=/managed/etc,readonly \
  --mount type=bind,src=/var/lib/makepad,dst=/managed-var-lib \
  --mount "type=bind,src=${bundle_dir}/scripts/brio-db-transaction.sh,dst=/input/brio-db-transaction.sh,readonly" \
  -e "RECOVERY_ID=${recovery_id}" -e "PRIOR_POSTGRES_IMAGE=${prior_postgres_image}" \
  "${validation_image}" sh -euc '
    case "$RECOVERY_ID" in ""|*[!0-9-]*|*-*-*|-*|*-|0*|*-0*) exit 1 ;; esac
    case "$RECOVERY_ID" in *-*) ;; *) exit 1 ;; esac
    root=/managed-var-lib/postgres-recovery/brio-identity
    stage="$root/.${RECOVERY_ID}.staging"
    final="$root/$RECOVERY_ID"
    for path in /managed-var-lib /managed-var-lib/postgres-recovery "$root"; do
      [ ! -L "$path" ] || { echo "Recovery path contains a symlink component." >&2; exit 1; }
    done
    install -d -o 0 -g 0 -m 0700 /managed-var-lib/postgres-recovery "$root"
    [ ! -e "$stage" ] && [ ! -L "$stage" ] && [ ! -e "$final" ] && [ ! -L "$final" ]
    install -d -o 0 -g 0 -m 0700 "$stage" "$stage/rollback" "$stage/database"
    cat > "$stage/rollback/paths.list" <<"PATHS"
live/compose.host.yml
live/envs/production/.env.db
live/config/brio-shared-pg_hba.conf
live/bootstrap/keycloak-brio-staging.sql
live/scripts/run-runtrace-backup.sh
live/scripts/run-runtrace-backup-loop.sh
live/scripts/run-brio-encrypted-backup.sh
live/scripts/run-brio-encrypted-backup-loop.sh
etc/secrets/postgres-brio-identity-backup-password
etc/tls/backups/brio-recipient.crt
PATHS
    : > "$stage/rollback/present.list"
    : > "$stage/rollback/absent.list"
    while IFS= read -r path; do
      current=/managed
      old_ifs=$IFS
      IFS=/
      set -- $path
      IFS=$old_ifs
      for component do
        current="$current/$component"
        [ ! -L "$current" ] || { echo "Managed snapshot path contains a symlink component: $path" >&2; exit 1; }
      done
      if [ -e "/managed/$path" ]; then printf "%s\n" "$path" >> "$stage/rollback/present.list"; else printf "%s\n" "$path" >> "$stage/rollback/absent.list"; fi
    done < "$stage/rollback/paths.list"
    tar --numeric-owner -cpf "$stage/rollback/managed.tar" -C /managed -T "$stage/rollback/present.list"
    backup=/managed-var-lib/postgres-backups/keycloak-brio-staging
    if [ -e "$backup" ] || [ -L "$backup" ]; then
      [ -d "$backup" ] && [ ! -L "$backup" ] || { echo "Identity backup snapshot path is unsafe." >&2; exit 1; }
      tar --numeric-owner -cpf "$stage/rollback/identity-backups.tar" -C /managed-var-lib postgres-backups/keycloak-brio-staging
    else
      printf "%s\n" absent > "$stage/rollback/identity-backup-absent"
    fi
    install -o 0 -g 0 -m 0700 /input/brio-db-transaction.sh "$stage/brio-db-transaction.sh"
    printf "%s\n" "$PRIOR_POSTGRES_IMAGE" > "$stage/prior-postgres-image"
    printf "%s\n" "$RECOVERY_ID" > "$stage/deployment-id"
    find "$stage" -type d -exec chmod 0700 {} +
    find "$stage" -type f -exec chmod 0600 {} +
    sync -f "$stage" 2>/dev/null || sync
  '
journal_stage="${recovery_root}/.${recovery_id}.staging"
run_db_transaction prepare "${journal_stage}"
docker run --rm \
  --mount type=bind,src=/var/lib/makepad,dst=/managed-var-lib \
  -e "RECOVERY_ID=${recovery_id}" \
  "${validation_image}" sh -euc '
    root=/managed-var-lib/postgres-recovery/brio-identity
    stage="$root/.${RECOVERY_ID}.staging"
    final="$root/$RECOVERY_ID"
    [ -d "$stage/database" ] && [ -s "$stage/database/restore.sql" ] && [ -s "$stage/database/prestate.fingerprint" ]
    printf "%s\n" IN_PROGRESS > "$stage/IN_PROGRESS"
    chmod 0600 "$stage/IN_PROGRESS"
    sync -f "$stage" 2>/dev/null || sync
    mv -T "$stage" "$final"
    sync -f "$root" 2>/dev/null || sync
  '
rollback_armed=1

install_host_path() {
  local source=$1 destination=$2 owner=$3 mode=$4
  case "${destination}" in
    "${live_dir}"/*|/etc/makepad/*) ;;
    *) echo "Refusing unmanaged host path: ${destination}" >&2; return 1 ;;
  esac
  docker run --rm \
    --mount "type=bind,src=${source},dst=/runtime/input,readonly" \
    --mount type=bind,src=/srv,dst=/host/srv \
    --mount type=bind,src=/etc,dst=/host/etc \
    -e "DESTINATION=${destination}" -e "FILE_OWNER=${owner}" -e "FILE_MODE=${mode}" -e "STAGE_TAG=${recovery_id}" \
    "${postgres_image}" sh -euc '
      case "$DESTINATION" in /srv/makepad/postgres/*|/etc/makepad/*) ;; *) exit 1 ;; esac
      case "$STAGE_TAG" in ""|*[!0-9-]*|*-*-*|-*|*-|0*|*-0*) exit 1 ;; esac
      case "$STAGE_TAG" in *-*) ;; *) exit 1 ;; esac
      host_destination="/host$DESTINATION"
      parent=${host_destination%/*}
      base=${host_destination##*/}
      current=/host
      old_ifs=$IFS
      IFS=/
      set -- ${DESTINATION#/}
      IFS=$old_ifs
      last=$#
      index=0
      for component do
        index=$((index + 1))
        current="$current/$component"
        [ ! -L "$current" ] || { echo "Managed promotion path contains a symlink component: $current" >&2; exit 1; }
        if [ "$index" -lt "$last" ]; then [ -d "$current" ] || { echo "Managed promotion parent is not a directory: $current" >&2; exit 1; }; fi
      done
      [ -d "$parent" ] && [ ! -L "$parent" ]
      [ ! -L "$host_destination" ] && [ ! -d "$host_destination" ]
      stage="$parent/.${base}.${STAGE_TAG}.stage"
      [ ! -e "$stage" ] && [ ! -L "$stage" ]
      cleanup() { rm -f -- "$stage"; }
      trap cleanup EXIT HUP INT TERM
      install -o "${FILE_OWNER%:*}" -g "${FILE_OWNER#*:}" -m "${FILE_MODE}" /runtime/input "$stage"
      mv -fT "$stage" "$host_destination"
      trap - EXIT HUP INT TERM
    '
}

install_host_path "${candidate_compose}" "${live_dir}/compose.host.yml" 0:0 0644
install_host_path "${db_env}" "${live_dir}/envs/production/.env.db" 0:0 0644
install_host_path "${rendered_hba}" "${hba_host_file}" 0:0 0444
install_host_path "${bundle_dir}/bootstrap/keycloak-brio-staging.sql" "${live_dir}/bootstrap/keycloak-brio-staging.sql" 0:0 0644
for script in run-runtrace-backup.sh run-runtrace-backup-loop.sh run-brio-encrypted-backup.sh run-brio-encrypted-backup-loop.sh; do
  install_host_path "${bundle_dir}/scripts/${script}" "${live_dir}/scripts/${script}" 0:0 0755
done
install_host_path "${runtime_dir}/keycloak-brio-staging-backup-password" "${backup_host_file}" 999:999 0400
install_host_path "${runtime_dir}/brio-backup-recipient-cert.pem" "${recipient_host_file}" 0:0 0444
docker run --rm --mount type=bind,src=/var/lib,dst=/host/var/lib \
  "${postgres_image}" sh -euc '
    for path in /host/var /host/var/lib /host/var/lib/makepad /host/var/lib/makepad/postgres-backups; do
      [ -d "$path" ] && [ ! -L "$path" ] || { echo "Identity backup promotion path is unsafe: $path" >&2; exit 1; }
    done
    install -d -o 999 -g 999 -m 0700 /host/var/lib/makepad/postgres-backups/keycloak-brio-staging
  '
[[ $(stat -c '%u:%a' "${hba_host_file}") == "0:444" && ! -L "${hba_host_file}" ]] || { echo "Active HBA installation failed its ownership/mode check." >&2; exit 1; }
[[ $(stat -c '%u:%a' "${backup_host_file}") == "999:400" && ! -L "${backup_host_file}" ]] || { echo "Identity backup credential installation failed its ownership/mode check." >&2; exit 1; }
[[ $(stat -c '%u:%a' "${recipient_host_file}") == "0:444" && ! -L "${recipient_host_file}" ]] || { echo "Backup recipient installation failed its ownership/mode check." >&2; exit 1; }
[[ $(stat -c '%u:%a' "${backup_host_dir}") == "999:700" && ! -L "${backup_host_dir}" ]] || { echo "Identity backup directory installation failed its ownership/mode check." >&2; exit 1; }

case "${failure_injection}" in
  after-managed-file-promotion) echo "Injected failure after identity managed-file promotion." >&2; exit 97 ;;
  term-after-managed-file-promotion) kill -TERM "$$" ;;
  kill-after-managed-file-promotion) kill -KILL "$$" ;;
esac

compose=(docker compose --project-name postgres --env-file "${live_dir}/envs/production/.env.db" -f "${live_dir}/compose.host.yml")
"${compose[@]}" up -d --wait --force-recreate postgres
validate_postgres_target "${postgres_image}" >/dev/null

journal_marker "${journal_dir}" DATABASE_MUTATION_ARMED
db_mutated=1
docker run --rm --network host \
  -v "${superuser_host_file}:/run/secrets/postgres_superuser_password:ro" \
  -v "${runtime_dir}/keycloak-brio-staging-app-password:/run/secrets/keycloak_app_password:ro" \
  -v "${runtime_dir}/keycloak-brio-staging-backup-password:/run/secrets/keycloak_backup_password:ro" \
  -v "${ca_host_file}:/etc/postgresql/ca.crt:ro" \
  -v "${live_dir}/bootstrap/keycloak-brio-staging.sql:/bootstrap/keycloak-brio-staging.sql:ro" \
  "${postgres_image}" sh -euc '
    export PGPASSWORD="$(cat /run/secrets/postgres_superuser_password)"
    export KEYCLOAK_APP_PASSWORD="$(cat /run/secrets/keycloak_app_password)"
    export KEYCLOAK_BACKUP_PASSWORD="$(cat /run/secrets/keycloak_backup_password)"
    export PGHOST="$1" PGHOSTADDR=127.0.0.1 PGSSLMODE=verify-full PGSSLROOTCERT=/etc/postgresql/ca.crt
    {
      printf "%s\n" "\\getenv keycloak_brio_staging_app_password KEYCLOAK_APP_PASSWORD" "\\getenv keycloak_brio_staging_backup_password KEYCLOAK_BACKUP_PASSWORD"
      cat /bootstrap/keycloak-brio-staging.sql
    } > /tmp/bootstrap.sql
    exec psql -X -v ON_ERROR_STOP=1 -U "$2" -d postgres -f /tmp/bootstrap.sql
  ' sh "${db_hostname}" "${postgres_user}" >/dev/null

case "${failure_injection}" in
  after-bootstrap) echo "Injected failure after identity database bootstrap." >&2; exit 96 ;;
  kill-after-bootstrap) kill -KILL "$$" ;;
esac

run_role_query() {
  local password_file=$1 role=$2 database=$3 sslmode=$4 query=$5
  docker run --rm --network host \
    -v "${password_file}:/run/secrets/role_password:ro" \
    -v "${ca_host_file}:/etc/postgresql/ca.crt:ro" \
    "${postgres_image}" sh -euc '
      export PGPASSWORD="$(cat /run/secrets/role_password)"
      export PGHOST="$1" PGHOSTADDR=127.0.0.1 PGSSLMODE="$4" PGSSLROOTCERT=/etc/postgresql/ca.crt
      exec psql -X -At -U "$2" -d "$3" -c "$5"
    ' sh "${db_hostname}" "${role}" "${database}" "${sslmode}" "${query}"
}

if [[ $(run_role_query "${runtime_dir}/keycloak-brio-staging-app-password" keycloak_brio_staging_app keycloak_brio_staging verify-full "select current_database() || ':' || current_user") != "keycloak_brio_staging:keycloak_brio_staging_app" ]]; then
  echo "Keycloak Brio role failed the local verify-full identity probe." >&2
  exit 1
fi
[[ "${failure_injection}" != after-app-probe ]] || { echo "Injected failure after identity app-role probe." >&2; exit 95; }
if run_role_query "${runtime_dir}/keycloak-brio-staging-app-password" keycloak_brio_staging_app keycloak_brio_staging disable "select 1" >/dev/null 2>&1; then
  echo "Plaintext Keycloak Brio database access was unexpectedly accepted." >&2
  exit 1
fi
[[ "${failure_injection}" != after-plaintext-probe ]] || { echo "Injected failure after identity plaintext probe." >&2; exit 94; }
if run_role_query "${runtime_dir}/keycloak-brio-staging-app-password" keycloak_brio_staging_app postgres verify-full "select 1" >/dev/null 2>&1; then
  echo "Keycloak Brio role was unexpectedly accepted by a non-target database." >&2
  exit 1
fi
[[ "${failure_injection}" != after-nontarget-probe ]] || { echo "Injected failure after identity non-target probe." >&2; exit 93; }
if [[ $(run_role_query "${runtime_dir}/keycloak-brio-staging-backup-password" keycloak_brio_staging_backup keycloak_brio_staging verify-full "show default_transaction_read_only") != "on" ]]; then
  echo "Keycloak Brio backup role is not read-only." >&2
  exit 1
fi
[[ "${failure_injection}" != after-backup-role-probe ]] || { echo "Injected failure after identity backup-role probe." >&2; exit 92; }

previous_latest=$(docker run --rm --mount "type=bind,src=${backup_host_dir},dst=/backups,readonly" \
  "${validation_image}" sh -euc 'readlink /backups/latest 2>/dev/null || true')
backup_started_at=$(date +%s)
"${compose[@]}" up -d --no-deps --force-recreate keycloak_brio_staging_backup
backup_verified=0
for _ in $(seq 1 60); do
  if docker run --rm --mount "type=bind,src=${backup_host_dir},dst=/backups,readonly" \
    -e "BACKUP_STARTED_AT=${backup_started_at}" -e "PREVIOUS_LATEST=${previous_latest}" \
    "${validation_image}" sh -euc '
      status=/backups/last-success.json
      [ -s "$status" ] && [ "$(stat -c %Y "$status")" -ge "$BACKUP_STARTED_AT" ]
      grep -q "\"database\":\"keycloak_brio_staging\"" "$status"
      grep -q "\"encrypted\":true" "$status"
      latest=$(readlink /backups/latest)
      case "$latest" in 20??????T??????Z) ;; *) exit 1 ;; esac
      [ "$latest" != "$PREVIOUS_LATEST" ]
      directory="/backups/$latest"
      [ -s "$directory/keycloak_brio_staging.dump.cms" ] && [ -s "$directory/SHA256SUMS" ]
      (cd "$directory" && sha256sum --check --status SHA256SUMS)
      openssl cms -cmsout -inform DER -in "$directory/keycloak_brio_staging.dump.cms" -noout >/dev/null 2>&1
    '; then
    backup_verified=1
    break
  fi
  sleep 2
done
[[ "${backup_verified}" == "1" ]] || { echo "A fresh validated encrypted keycloak_brio_staging backup was not published." >&2; exit 1; }
[[ "${failure_injection}" != after-backup-verification ]] || { echo "Injected failure after identity backup verification." >&2; exit 91; }

journal_marker "${journal_dir}" COMMITTED
rollback_armed=0
remove_durable_journal "${journal_dir}"
echo "Standalone Brio identity PostgreSQL target, rollback snapshot, HBA, bootstrap, local TLS policy, and encrypted backup verification passed."
echo "Release acceptance still requires the protected Keycloak-host Verify Brio Identity Database Path workflow for this PostgreSQL run ID."
