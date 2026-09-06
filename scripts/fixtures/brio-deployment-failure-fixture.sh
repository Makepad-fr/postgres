#!/usr/bin/env bash
set -euo pipefail

repo=/repo
mock_bin=/tmp/brio-mock-bin
install -d -m 0700 "${mock_bin}"

cat > "${mock_bin}/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

remove_exact() {
  local target=$1
  if [[ -L "${target}" || -f "${target}" ]]; then
    rm -f -- "${target}"
  elif [[ -d "${target}" ]]; then
    find "${target}" -mindepth 1 -delete
    rmdir -- "${target}"
  elif [[ -e "${target}" ]]; then
    echo "Refusing unexpected mock path type: ${target}" >&2
    exit 1
  fi
}

map_mount() {
  local specification=$1 source= destination=
  IFS=',' read -r -a fields <<< "${specification}"
  for field in "${fields[@]}"; do
    case "${field}" in src=*|source=*) source=${field#*=} ;; dst=*|destination=*|target=*) destination=${field#*=} ;; esac
  done
  [[ -n "${source}" && -n "${destination}" ]] || return 0
  mock_mount_sources+=("${source}")
  mock_mount_destinations+=("${destination}")
  mkdir -p "$(dirname "${destination}")"
  remove_exact "${destination}"
  case "${destination}" in
    /managed/live|/managed/etc)
      mkdir -p "${destination}"
      cp -a "${source}/." "${destination}/"
      ;;
    *) ln -s "${source}" "${destination}" ;;
  esac
}

create_backup() {
  local database=$1 root timestamp directory recipient
  case "${database}" in
    brio_staging)
      root=/var/lib/makepad/postgres-backups/brio-staging
      recipient=/etc/makepad/tls/backups/brio-recipient.crt
      ;;
    keycloak_brio_staging)
      root=/var/lib/makepad/postgres-backups/keycloak-brio-staging
      recipient=/etc/makepad/tls/backups/brio-recipient.crt
      ;;
    *) return 1 ;;
  esac
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  directory="${root}/${timestamp}"
  mkdir -p "${directory}"
  printf 'mock-%s-backup\n' "${database}" | openssl cms -encrypt -binary -stream -outform DER -aes-256-gcm \
    -recip "${recipient}" -out "${directory}/${database}.dump.cms" 2>/dev/null
  (cd "${directory}" && sha256sum "${database}.dump.cms" > SHA256SUMS)
  ln -sfn "${timestamp}" "${root}/latest"
  printf '{"database":"%s","encrypted":true}\n' "${database}" > "${root}/last-success.json"
}

command_name=${1:-}
shift || true
case "${command_name}" in
  info)
    printf '%s\n' inactive
    ;;
  pull)
    ;;
  image)
    [[ "${1:-}" == inspect ]]
    ;;
  container)
    [[ "${1:-}" == inspect ]] || exit 1
    shift
    target=${1:-}
    shift || true
    format=
    while (($#)); do
      if [[ "$1" == --format ]]; then format=$2; shift 2; else shift; fi
    done
    if [[ "${target}" == makepad-postgres-brio-tmp-cleaner ]]; then
      cleaner_state=/tmp/mock-cleaner-state
      [[ -d "${cleaner_state}" ]] || exit 1
      case "${format}" in
        '') ;;
        *'.State.Running'*'.State.Restarting'*) printf '%s|false\n' "$(< "${cleaner_state}/running")" ;;
        *'.Config.Image'*) cat "${cleaner_state}/image" ;;
        *'makepad.cleanup.contract'*) printf '%s\n' brio-tmp-cleaner-v5-exact-command ;;
        *'.HostConfig.RestartPolicy.Name'*) printf '%s\n' unless-stopped ;;
        *'.HostConfig.ReadonlyRootfs'*) printf '%s\n' true ;;
        *'.Mounts'*) printf '%s\n' 'bind|/tmp|true' ;;
        *'.HostConfig.CapDrop'*) printf '%s\n' '["ALL"]' ;;
        *'.HostConfig.CapAdd'*) printf '%s\n' "${MOCK_CLEANER_CAP_ADD:-[\"CAP_DAC_OVERRIDE\",\"CAP_FOWNER\"]}" ;;
        *'.HostConfig.SecurityOpt'*) printf '%s\n' '["no-new-privileges"]' ;;
        *'len .Config.Cmd'*) printf '%s\n' 3 ;;
        *'index .Config.Cmd 0'*) printf '%s\n' sh ;;
        *'index .Config.Cmd 1'*) printf '%s\n' -euc ;;
        *'index .Config.Cmd 2'*) cat "${cleaner_state}/command" ;;
        *'.State.Running'*) cat "${cleaner_state}/running" ;;
        *) echo "Unhandled cleaner container format: ${format}" >&2; exit 1 ;;
      esac
      exit 0
    fi
    [[ "${target}" == postgres-postgres-1 || "${target}" == mock-container-id ]] || exit 1
    case "${format}" in
      *'.Id'*) printf '%s\n' mock-container-id ;;
      *'.Name'*) printf '%s\n' /postgres-postgres-1 ;;
      *'com.docker.compose.project'*) printf '%s\n' "${MOCK_COMPOSE_PROJECT:-postgres}" ;;
      *'com.docker.compose.service'*) printf '%s\n' postgres ;;
      *'com.docker.compose.oneoff'*) printf '%s\n' False ;;
      *'.HostConfig.NetworkMode'*) printf '%s\n' host ;;
      *'.Config.Image'*) printf '%s\n' "${MOCK_POSTGRES_IMAGE}" ;;
      *'.Mounts'*) printf '%s\n' 'bind|/var/lib/makepad/postgres|true' ;;
      *'.State.Running'*) printf '%s\n' true ;;
      *'.State.Health'*) printf '%s\n' healthy ;;
      *) echo "Unhandled container format: ${format}" >&2; exit 1 ;;
    esac
    ;;
  start)
    [[ "${1:-}" == makepad-postgres-brio-tmp-cleaner && -d /tmp/mock-cleaner-state ]] || exit 1
    if [[ ! -f /tmp/mock-cleaner-stop-after-start ]]; then printf '%s\n' true > /tmp/mock-cleaner-state/running; fi
    ;;
  compose)
    if printf '%s\n' "$@" | grep -Fxq config; then
      if [[ " ${*} " == *' --quiet '* ]]; then exit 0; fi
      cat <<'YAML'
services:
  postgres:
    network_mode: host
    volumes:
      - type: bind
        source: /var/lib/makepad/postgres
        target: /var/lib/postgresql/data
YAML
      exit 0
    fi
    if printf '%s\n' "$@" | grep -Fxq up; then
      counter_file=/tmp/mock-compose-up-count
      count=0
      [[ ! -f "${counter_file}" ]] || read -r count < "${counter_file}"
      count=$((count + 1))
      printf '%s\n' "${count}" > "${counter_file}"
      if [[ "${MOCK_COMPOSE_FAIL_FIRST:-0}" == 1 && "${count}" == 1 ]]; then exit 44; fi
      if [[ " ${*} " == *' keycloak_brio_staging_backup '* ]]; then
        create_backup keycloak_brio_staging
      fi
      exit 0
    fi
    echo "Unhandled docker compose invocation" >&2
    exit 1
    ;;
  config|secret|network)
    object_kind=${command_name}
    action=${1:-}
    shift || true
    state_root=/tmp/mock-docker-state
    case "${action}" in
      inspect)
        object_name=${1:-}
        state_file="${state_root}/${object_kind}/${object_name}"
        [[ -f "${state_file}" ]] || exit 1
        format=
        while (($#)); do
          if [[ "$1" == --format ]]; then format=$2; shift 2; else shift; fi
        done
        if [[ "${format}" == *makepad.brio.deployment-id* ]]; then
          sed -n 's/^deployment_id=//p' "${state_file}"
        elif [[ "${format}" == *content-sha256* ]]; then
          sed -n 's/^digest=//p' "${state_file}"
        elif [[ "${object_kind}" == config && "${format}" == *'.Spec.Data'* ]]; then
          cat "${state_root}/config-data/${object_name}"
        elif [[ "${object_kind}" == network && -n "${format}" ]]; then
          internal=$(sed -n 's/^internal=//p' "${state_file}")
          printf 'overlay swarm %s true true\n' "${internal:-false}"
        fi
        ;;
      create)
        mkdir -p "${state_root}/${object_kind}"
        declare -a values=("$@")
        object_name=${values[${#values[@]}-1]}
        [[ "${object_kind}" == network ]] || object_name=${values[${#values[@]}-2]}
        deployment_id=
        digest=
        internal=false
        for ((index=0; index<${#values[@]}; index++)); do
          if [[ "${values[index]}" == --label && $((index + 1)) -lt ${#values[@]} ]]; then
            case "${values[index+1]}" in
              makepad.brio.deployment-id=*) deployment_id=${values[index+1]#*=} ;;
              content-sha256=*) digest=${values[index+1]#*=} ;;
            esac
          elif [[ "${values[index]}" == --internal ]]; then
            internal=true
          fi
        done
        printf 'deployment_id=%s\ndigest=%s\ninternal=%s\n' "${deployment_id}" "${digest}" "${internal}" > "${state_root}/${object_kind}/${object_name}"
        if [[ "${object_kind}" == config ]]; then
          mkdir -p "${state_root}/config-data"
          cp "${values[${#values[@]}-1]}" "${state_root}/config-data/${object_name}"
        fi
        ;;
      rm)
        rm -f -- "${state_root}/${object_kind}/${1:-}"
        [[ "${object_kind}" != config ]] || rm -f -- "${state_root}/config-data/${1:-}"
        ;;
      ls)
        requested_owner=
        while (($#)); do
          case "$1" in
            --filter) requested_owner=${2#label=makepad.brio.deployment-id=}; shift 2 ;;
            --format) shift 2 ;;
            *) shift ;;
          esac
        done
        [[ -d "${state_root}/${object_kind}" ]] || exit 0
        for state_file in "${state_root}/${object_kind}"/*; do
          [[ -f "${state_file}" ]] || continue
          [[ -z "${requested_owner}" || $(sed -n 's/^deployment_id=//p' "${state_file}") == "${requested_owner}" ]] || continue
          basename "${state_file}"
        done
        ;;
      *) exit 1 ;;
    esac
    ;;
  stack)
    action=${1:-}
    case "${action}" in
      config|rm) exit 0 ;;
      services)
        stack_name=${2:-}
        [[ -d /tmp/mock-docker-state/service ]] || exit 1
        for state_file in /tmp/mock-docker-state/service/"${stack_name}"_*; do
          [[ -f "${state_file}" ]] || continue
          basename "${state_file}"
        done
        ;;
      *) exit 1 ;;
    esac
    ;;
  service)
    action=${1:-}
    shift || true
    state_root=/tmp/mock-docker-state/service
    case "${action}" in
      inspect)
        service_name=${1:-}; shift || true
        state_file="${state_root}/${service_name}"
        [[ -f "${state_file}" ]] || exit 1
        format=
        while (($#)); do if [[ "$1" == --format ]]; then format=$2; shift 2; else shift; fi; done
        current=$(sed -n 's/^current=//p' "${state_file}")
        previous=$(sed -n 's/^previous=//p' "${state_file}")
        namespace=$(sed -n 's/^namespace=//p' "${state_file}")
        case "${format}" in
          '') printf '[{"Spec":{"Name":"%s","Marker":"%s"}}]\n' "${service_name}" "${current}" ;;
          *'com.docker.stack.namespace'*) printf '%s\n' "${namespace}" ;;
          *'json .Spec'*) printf '{"Name":"%s","Marker":"%s"}\n' "${service_name}" "${current}" ;;
          *'.PreviousSpec'*) if [[ -n "${previous}" ]]; then printf '%s\n' present; else printf '%s\n' absent; fi ;;
          *) echo "Unhandled mock service format: ${format}" >&2; exit 1 ;;
        esac
        ;;
      rollback)
        while [[ "${1:-}" == --* ]]; do
          if [[ "$1" == --detach=false ]]; then shift; else shift 2; fi
        done
        service_name=${1:-}; state_file="${state_root}/${service_name}"
        [[ -f "${state_file}" ]] || exit 1
        current=$(sed -n 's/^current=//p' "${state_file}")
        previous=$(sed -n 's/^previous=//p' "${state_file}")
        [[ -n "${previous}" ]] || exit 1
        namespace=$(sed -n 's/^namespace=//p' "${state_file}")
        printf 'current=%s\nprevious=%s\nnamespace=%s\n' "${previous}" "${current}" "${namespace}" > "${state_file}"
        ;;
      rm) rm -f -- "${state_root}/${1:-}" ;;
      *) exit 1 ;;
    esac
    ;;
  run)
    if printf '%s\n' "$@" | grep -Fxq makepad-postgres-brio-tmp-cleaner; then
      cleaner_state=/tmp/mock-cleaner-state
      install -d -m 0700 "${cleaner_state}"
      declare -a cleaner_args=("$@")
      cleaner_image=
      cleaner_command=
      for ((cleaner_index=0; cleaner_index<${#cleaner_args[@]}; cleaner_index++)); do
        if [[ "${cleaner_args[cleaner_index]}" == sh && "${cleaner_args[cleaner_index+1]:-}" == -euc ]]; then
          cleaner_image=${cleaner_args[cleaner_index-1]}
          cleaner_command=${cleaner_args[cleaner_index+2]:-}
          break
        fi
      done
      [[ -n "${cleaner_image}" && -n "${cleaner_command}" ]] || exit 1
      printf '%s\n' "${cleaner_image}" > "${cleaner_state}/image"
      printf '%s\n' true > "${cleaner_state}/running"
      printf '%s\n' "${cleaner_command}" > "${cleaner_state}/command"
      exit 0
    fi
    declare -a environment=()
    declare -a mock_mount_sources=()
    declare -a mock_mount_destinations=()
    while (($#)); do
      case "$1" in
        --rm|-i|--read-only) shift ;;
        --mount) map_mount "$2"; shift 2 ;;
        -v|--volume)
          mount_value=$2
          source=${mount_value%%:*}
          remainder=${mount_value#*:}
          destination=${remainder%%:*}
          map_mount "src=${source},dst=${destination}"
          shift 2
          ;;
        -e|--env) environment+=("$2"); shift 2 ;;
        --network|--entrypoint|--tmpfs|--pids-limit|--memory|--cap-drop|--cap-add|--security-opt|--user) shift 2 ;;
        --*) shift ;;
        *) image=$1; shift; break ;;
      esac
    done
    : "${image:?missing mock image}"
    for assignment in "${environment[@]}"; do export "${assignment}"; done
    if [[ "${1:-}" == /usr/local/bin/brio-db-transaction.sh ]]; then
      operation=${2:-}
      scope=${3:-}
      destination=${4:-}
      case "${scope}" in brio|keycloak) ;; *) exit 1 ;; esac
      case "${operation}" in
        prepare)
          mkdir -p "${destination}"
          if [[ -f /tmp/mock-db-state ]]; then cp /tmp/mock-db-state "${destination}/mock-state"; else printf '%s\n' prior > "${destination}/mock-state"; fi
          printf '%s\n' '-- mock exact restore program' > "${destination}/restore.sql"
          printf '%s\n' mock-prestate-fingerprint > "${destination}/prestate.fingerprint"
          ;;
        restore)
          [[ -s "${destination}/mock-state" && -s "${destination}/restore.sql" && -s "${destination}/prestate.fingerprint" ]]
          cp "${destination}/mock-state" /tmp/mock-db-state
          ;;
        *) exit 1 ;;
      esac
      exit 0
    fi
    if [[ "${1:-}" == /usr/local/bin/run-brio-encrypted-backup.sh ]]; then
      create_backup "${BRIO_BACKUP_DATABASE:?}"
      exit 0
    fi
    if [[ "${1:-}" == getent && "${2:-}" == hosts ]]; then
      printf '%s %s\n' 10.44.0.2 "${3:-makepad-postgres-brio-staging}"
      exit 0
    fi
    if [[ "${1:-}" == sh && "${2:-}" == -euc && "${3:-}" == *'exec psql'* ]]; then
      script=${3}
      if [[ "${script}" == *'-f /tmp/bootstrap.sql'* ]]; then
        printf '%s\n' candidate > /tmp/mock-db-state
        exit 0
      fi
      role=${5:-}; database=${6:-}; sslmode=${7:-}; query=${8:-}
      [[ "${sslmode}" != disable ]] || exit 1
      [[ "${database}" != postgres ]] || exit 1
      if [[ "${query}" == *current_database* ]]; then printf '%s:%s\n' "${database}" "${role}"
      elif [[ "${query}" == *default_transaction_read_only* ]]; then printf '%s\n' on
      else printf '%s\n' 1; fi
      exit 0
    fi
    if [[ "${1:-}" == sh && "${2:-}" == -euc ]]; then
      script=${3}
      for ((mount_index=0; mount_index<${#mock_mount_sources[@]}; mount_index++)); do
        mount_source=${mock_mount_sources[mount_index]}
        mount_destination=${mock_mount_destinations[mount_index]}
        case "${mount_destination}" in
          /journal|/rollback|/managed-var-lib|/host/etc|/host/var/lib)
            script=${script//${mount_destination}/${mount_source}}
            ;;
        esac
      done
      script=${script//\/host\//\/}
      script=${script//\/host/\/}
      shift 3
      env "${environment[@]}" sh -euc "${script}" "$@"
      command_status=$?
      if [[ ${command_status} -eq 0 && "${script}" == *'tar --numeric-owner -xpf'* ]]; then
        for ((mount_index=0; mount_index<${#mock_mount_sources[@]}; mount_index++)); do
          mount_source=${mock_mount_sources[mount_index]}
          mount_destination=${mock_mount_destinations[mount_index]}
          case "${mount_destination}" in
            /managed/live|/managed/etc)
              find "${mount_source}" -mindepth 1 -delete
              cp -a "${mount_destination}/." "${mount_source}/"
              ;;
          esac
        done
      fi
      exit "${command_status}"
    fi
    env "${environment[@]}" "$@"
    ;;
  *)
    echo "Unhandled mock docker command: ${command_name} $*" >&2
    exit 1
    ;;
esac
MOCK
chmod 0755 "${mock_bin}/docker"
export PATH="${mock_bin}:${PATH}"

generate_certificates() {
  local destination=$1
  install -d -m 0700 "${destination}"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=Brio-Test-CA \
    -keyout "${destination}/ca.key" -out "${destination}/ca.crt" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -subj /CN=makepad-postgres-brio-staging \
    -keyout "${destination}/server.key" -out "${destination}/server.csr" >/dev/null 2>&1
  cat > "${destination}/server.ext" <<'EOF'
subjectAltName=DNS:makepad-postgres-brio-staging,IP:65.21.134.125
extendedKeyUsage=serverAuth
EOF
  openssl x509 -req -days 30 -in "${destination}/server.csr" \
    -CA "${destination}/ca.crt" -CAkey "${destination}/ca.key" -CAcreateserial \
    -extfile "${destination}/server.ext" -out "${destination}/server.crt" >/dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=Brio-Backup-Test \
    -keyout "${destination}/recipient.key" -out "${destination}/recipient.crt" >/dev/null 2>&1
}

pki=/tmp/brio-fixture-pki
generate_certificates "${pki}"
export MOCK_POSTGRES_IMAGE='postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777'
validation_image='postgres:16-bookworm@sha256:bb3e1a57e5407e0a5280b4211980a5e537f4abd234a87014ac979849a78dd825'

remove_exact() {
  local target=$1
  if [[ -L "${target}" || -f "${target}" ]]; then
    rm -f -- "${target}"
  elif [[ -d "${target}" ]]; then
    find "${target}" -mindepth 1 -delete
    rmdir -- "${target}"
  elif [[ -e "${target}" ]]; then
    echo "Refusing unexpected fixture path type: ${target}" >&2
    exit 1
  fi
}

reset_canary_host() {
  for target in /etc/makepad /var/lib/makepad /host /runtime /rollback /managed /tmp/mock-docker-state /tmp/mock-db-state; do remove_exact "${target}"; done
  install -d -m 0755 /etc/makepad/secrets /etc/makepad/tls/postgres /etc/makepad/tls/backups /var/lib/makepad/postgres-backups
  printf '%s\n' old-canary-superuser > /etc/makepad/secrets/postgres-canary-superuser-password
  printf '%s\n' old-canary-backup > /etc/makepad/secrets/postgres-brio-app-backup-password
  cp "${pki}/ca.crt" /etc/makepad/tls/postgres/ca.crt
  cp "${pki}/recipient.crt" /etc/makepad/tls/backups/brio-recipient.crt
  install -d -o 999 -g 999 -m 0700 /var/lib/makepad/postgres-backups/brio-staging
  printf '%s\n' preserve-me > /var/lib/makepad/postgres-backups/brio-staging/sentinel
  chmod 0600 /etc/makepad/secrets/postgres-canary-superuser-password
  chown 999:999 /etc/makepad/secrets/postgres-brio-app-backup-password
  chmod 0400 /etc/makepad/secrets/postgres-brio-app-backup-password
  chmod 0444 /etc/makepad/tls/postgres/ca.crt /etc/makepad/tls/backups/brio-recipient.crt
  install -d -m 0700 /tmp/mock-docker-state/service
  docker network create --driver overlay --attachable --opt encrypted=true makepad_canary_primary_db >/dev/null
  docker network create --driver overlay --attachable --opt encrypted=true makepad_canary_lpc_db >/dev/null
  printf 'current=prior-postgres\nprevious=\nnamespace=brio-canary\n' > /tmp/mock-docker-state/service/brio-canary_postgres
  printf 'current=prior-backup\nprevious=\nnamespace=brio-canary\n' > /tmp/mock-docker-state/service/brio-canary_brio_staging_backup
  printf '%s\n' prior > /tmp/mock-db-state
}

prepare_canary() {
  local id=$1
  canary_bundle="/srv/test/.deploy/postgres-${id}"
  canary_runtime="/tmp/postgres-brio-canary-runtime-${id}"
  remove_exact "${canary_bundle}"
  remove_exact "${canary_runtime}"
  install -d -m 0700 "${canary_bundle}/envs/canary" "${canary_bundle}/config" "${canary_bundle}/scripts" "${canary_bundle}/bootstrap" "${canary_runtime}"
  cat > "${canary_bundle}/envs/canary/.env.db" <<EOF
POSTGRES_IMAGE=${MOCK_POSTGRES_IMAGE}
BRIO_BACKUP_IMAGE=${validation_image}
POSTGRES_USER=postgres
MAKEPAD_POSTGRES_SUPERUSER_PASSWORD_FILE_HOST_PATH=/etc/makepad/secrets/postgres-canary-superuser-password
MAKEPAD_POSTGRES_CA_CERT_HOST_PATH=/etc/makepad/tls/postgres/ca.crt
MAKEPAD_POSTGRES_BRIO_APP_BACKUP_PASSWORD_FILE_HOST_PATH=/etc/makepad/secrets/postgres-brio-app-backup-password
MAKEPAD_POSTGRES_BRIO_BACKUP_RECIPIENT_CERT_HOST_PATH=/etc/makepad/tls/backups/brio-recipient.crt
MAKEPAD_POSTGRES_BRIO_APP_BACKUP_PATH=/var/lib/makepad/postgres-backups/brio-staging
MAKEPAD_POSTGRES_TLS_CERT_CONFIG=makepad_postgres_canary_tls_cert_v2
MAKEPAD_POSTGRES_TLS_KEY_SECRET=makepad_postgres_canary_tls_key_v2
MAKEPAD_POSTGRES_RUNTRACE_HBA_CONFIG=makepad_postgres_canary_runtrace_hba_v3
EOF
  cat > "${canary_bundle}/envs/canary/.env.deploy" <<'EOF'
MAKEPAD_POSTGRES_DB_NETWORK=makepad_canary_primary_db
MAKEPAD_POSTGRES_LE_PETIT_COIN_DB_NETWORK=makepad_canary_lpc_db
MAKEPAD_POSTGRES_BRIO_STAGING_DB_NETWORK=makepad_brio_staging_db
EOF
  printf '%s\n' 'services: {}' > "${canary_bundle}/compose.yml"
  printf '%s\n' 'services: {}' > "${canary_bundle}/envs/canary/compose.yml"
  printf '%s\n' 'host all all all scram-sha-256' > "${canary_bundle}/config/runtrace-pg_hba.conf"
  printf '%s\n' '# test' > "${canary_bundle}/bootstrap/brio-staging-app.sql"
  cat > "${canary_bundle}/scripts/deploy-postgres-stack.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${MOCK_STACK_RESULT:-success}" == success ]]
for state_file in /tmp/mock-docker-state/service/brio-canary_*; do
  [[ -f "${state_file}" ]] || continue
  current=$(sed -n 's/^current=//p' "${state_file}")
  namespace=$(sed -n 's/^namespace=//p' "${state_file}")
  printf 'current=candidate-%s\nprevious=%s\nnamespace=%s\n' "${state_file##*/}" "${current}" "${namespace}" > "${state_file}"
done
EOF
  chmod 0755 "${canary_bundle}/scripts/deploy-postgres-stack.sh"
  cp "${repo}/scripts/brio-db-transaction.sh" "${canary_bundle}/scripts/brio-db-transaction.sh"
  chmod 0755 "${canary_bundle}/scripts/brio-db-transaction.sh"
  printf '%s\n' new-superuser > "${canary_runtime}/postgres-superuser-password"
  printf '%s\n' new-app-password > "${canary_runtime}/brio-staging-app-password"
  printf '%s\n' new-backup-password > "${canary_runtime}/brio-staging-backup-password"
  cp "${pki}/ca.crt" "${canary_runtime}/postgres-ca.pem"
  cp "${pki}/server.crt" "${canary_runtime}/postgres-server-cert.pem"
  cp "${pki}/server.key" "${canary_runtime}/postgres-server-key.pem"
  cp "${pki}/recipient.crt" "${canary_runtime}/brio-backup-recipient-cert.pem"
  chmod 0600 "${canary_runtime}"/*
}

assert_canary_restored() {
  [[ $(< /etc/makepad/secrets/postgres-canary-superuser-password) == old-canary-superuser ]]
  [[ $(< /etc/makepad/secrets/postgres-brio-app-backup-password) == old-canary-backup ]]
  [[ $(< /var/lib/makepad/postgres-backups/brio-staging/sentinel) == preserve-me ]]
  [[ $(sed -n 's/^current=//p' /tmp/mock-docker-state/service/brio-canary_postgres) == prior-postgres ]]
  [[ $(sed -n 's/^current=//p' /tmp/mock-docker-state/service/brio-canary_brio_staging_backup) == prior-backup ]]
  [[ $(< /tmp/mock-db-state) == prior ]]
  [[ -f /tmp/mock-docker-state/network/makepad_canary_primary_db ]]
  [[ -f /tmp/mock-docker-state/network/makepad_canary_lpc_db ]]
  [[ ! -e /tmp/mock-docker-state/network/makepad_brio_staging_db ]]
  ! find /tmp/mock-docker-state/config /tmp/mock-docker-state/secret -type f -print -quit 2>/dev/null | grep -q .
}

run_canary_failure() {
  local id=$1 injection=$2 stack_result=${3:-success}
  reset_canary_host
  prepare_canary "${id}"
  set +e
  BRIO_DEPLOY_TEST_MODE=isolated-container BRIO_DEPLOY_FAILURE_INJECTION="${injection}" MOCK_STACK_RESULT="${stack_result}" \
    "${repo}/scripts/deploy-brio-canary-postgres.sh" "${canary_bundle}" brio-canary "${canary_runtime}" >/tmp/canary-output 2>&1
  status=$?
  set -e
  [[ ${status} -ne 0 ]]
}

run_canary_failure 101-1 after-managed-file-promotion
assert_canary_restored
[[ ! -e /tmp/postgres-brio-canary-runtime-101-1 ]]

run_canary_failure 102-1 term-after-managed-file-promotion
assert_canary_restored
[[ ! -e /tmp/postgres-brio-canary-runtime-102-1 ]]

run_canary_failure 103-1 after-stack-deploy success
assert_canary_restored
[[ ! -e /tmp/postgres-brio-canary-runtime-103-1 ]]

canary_injections=(after-bootstrap after-app-probe after-plaintext-probe after-nontarget-probe after-backup-role-probe after-backup-verification)
canary_case=110
for injection in "${canary_injections[@]}"; do
  run_canary_failure "${canary_case}-1" "${injection}"
  assert_canary_restored
  [[ ! -e "/var/lib/makepad/postgres-recovery/brio-canary/${canary_case}-1" ]]
  canary_case=$((canary_case + 1))
done

# A SIGKILL cannot execute traps. The next attempt must recover the durable
# transaction before taking its own snapshot, at both host and DB boundaries.
for kill_injection in kill-after-managed-file-promotion kill-after-bootstrap; do
  reset_canary_host
  prepare_canary 120-1
  set +e
  BRIO_DEPLOY_TEST_MODE=isolated-container BRIO_DEPLOY_FAILURE_INJECTION="${kill_injection}" \
    "${repo}/scripts/deploy-brio-canary-postgres.sh" "${canary_bundle}" brio-canary "${canary_runtime}" >/tmp/canary-kill-output 2>&1
  kill_status=$?
  set -e
  [[ ${kill_status} -eq 137 ]]
  [[ -f /var/lib/makepad/postgres-recovery/brio-canary/120-1/IN_PROGRESS ]]
  prepare_canary 120-2
  set +e
  BRIO_DEPLOY_TEST_MODE=isolated-container BRIO_DEPLOY_FAILURE_INJECTION=after-managed-file-promotion \
    "${repo}/scripts/deploy-brio-canary-postgres.sh" "${canary_bundle}" brio-canary "${canary_runtime}" >/tmp/canary-recovery-output 2>&1
  recovery_status=$?
  set -e
  [[ ${recovery_status} -ne 0 ]]
  assert_canary_restored
  [[ ! -e /var/lib/makepad/postgres-recovery/brio-canary/120-1 ]]
  remove_exact /tmp/postgres-brio-canary-runtime-120-1
done

# stack deploy has no implicit --prune. A stale legacy identity backup service
# is inventoried and blocks the release without mutating its exact prior Spec.
reset_canary_host
printf 'current=legacy-exact\nprevious=\nnamespace=brio-canary\n' > /tmp/mock-docker-state/service/brio-canary_keycloak_brio_staging_backup
legacy_before=$(docker service inspect brio-canary_keycloak_brio_staging_backup --format '{{json .Spec}}' | sha256sum | cut -d' ' -f1)
prepare_canary 121-1
set +e
BRIO_DEPLOY_TEST_MODE=isolated-container \
  "${repo}/scripts/deploy-brio-canary-postgres.sh" "${canary_bundle}" brio-canary "${canary_runtime}" >/tmp/canary-legacy-output 2>&1
legacy_status=$?
set -e
[[ ${legacy_status} -ne 0 ]]
grep -q 'Retire it through a separately reviewed operation' /tmp/canary-legacy-output
legacy_after=$(docker service inspect brio-canary_keycloak_brio_staging_backup --format '{{json .Spec}}' | sha256sum | cut -d' ' -f1)
[[ "${legacy_before}" == "${legacy_after}" && $(< /tmp/mock-db-state) == prior ]]

reset_canary_host
prepare_canary 103-2
remove_exact /var/lib/makepad/postgres-backups/brio-staging
set +e
BRIO_DEPLOY_TEST_MODE=isolated-container BRIO_DEPLOY_FAILURE_INJECTION=after-managed-file-promotion \
  "${repo}/scripts/deploy-brio-canary-postgres.sh" "${canary_bundle}" brio-canary "${canary_runtime}" >/tmp/canary-absent-output 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]]
[[ ! -e /var/lib/makepad/postgres-backups/brio-staging ]]

run_canary_failure 104-1 rollback-restore fail
[[ -f /tmp/postgres-brio-canary-runtime-104-1/RECOVERY_REQUIRED ]]
[[ -f /var/lib/makepad/postgres-recovery/brio-canary/104-1/rollback/managed.tar ]]
[[ $(stat -c '%u:%a' /var/lib/makepad/postgres-recovery/brio-canary/104-1) == 0:700 ]]
for secret in postgres-superuser-password brio-staging-app-password brio-staging-backup-password postgres-server-key.pem; do
  [[ ! -e "/tmp/postgres-brio-canary-runtime-104-1/${secret}" ]]
done

# Check every canary-controlled parent before the journal snapshot. No bind
# mount may hide a symlink in a mutable host path or touch its outside target.
canary_outside=/tmp/postgres-brio-canary-outside-sentinel
remove_exact "${canary_outside}"
install -d -m 0700 "${canary_outside}"
printf '%s\n' untouched > "${canary_outside}/sentinel"
for parent in \
  /etc/makepad /etc/makepad/secrets /etc/makepad/tls /etc/makepad/tls/postgres /etc/makepad/tls/backups \
  /var/lib/makepad /var/lib/makepad/postgres-backups /var/lib/makepad/postgres-recovery; do
  reset_canary_host
  prepare_canary 105-1
  remove_exact "${parent}"
  ln -s "${canary_outside}" "${parent}"
  set +e
  BRIO_DEPLOY_TEST_MODE=isolated-container BRIO_DEPLOY_FAILURE_INJECTION=after-managed-file-promotion \
    "${repo}/scripts/deploy-brio-canary-postgres.sh" "${canary_bundle}" brio-canary "${canary_runtime}" >/tmp/canary-symlink-output 2>&1
  status=$?
  set -e
  [[ ${status} -ne 0 ]]
  grep -Eq 'symlink component|missing, not a directory, or a symlink' /tmp/canary-symlink-output
  [[ $(< "${canary_outside}/sentinel") == untouched ]]
  remove_exact "${parent}"
done
remove_exact "${canary_outside}"

reset_identity_host() {
  for target in /srv/makepad/postgres /etc/makepad /var/lib/makepad /host /runtime /rollback /managed /managed-var-lib /tmp/mock-compose-up-count /tmp/mock-db-state; do remove_exact "${target}"; done
  install -d -m 0755 /srv/makepad/postgres/{bootstrap,config,envs/production,scripts} /etc/makepad/secrets /etc/makepad/tls/postgres /etc/makepad/tls/backups /var/lib/makepad/postgres /var/lib/makepad/postgres-backups
  printf '%s\n' old-live-compose > /srv/makepad/postgres/compose.host.yml
  printf '%s\n' old-live-env > /srv/makepad/postgres/envs/production/.env.db
  printf '%s\n' old-live-hba > /srv/makepad/postgres/config/runtrace-pg_hba.conf
  for script in run-runtrace-backup.sh run-runtrace-backup-loop.sh; do printf '%s\n' old > "/srv/makepad/postgres/scripts/${script}"; done
  printf '%s\n' old-superuser > /etc/makepad/secrets/postgres-superuser-password
  cp "${pki}/server.crt" /etc/makepad/tls/postgres/server.crt
  cp "${pki}/server.key" /etc/makepad/secrets/postgres-server.key
  cp "${pki}/ca.crt" /etc/makepad/tls/postgres/ca.crt
  chmod 0600 /etc/makepad/secrets/postgres-superuser-password
  chown 70:70 /etc/makepad/secrets/postgres-server.key
  chmod 0400 /etc/makepad/secrets/postgres-server.key
  chmod 0444 /etc/makepad/tls/postgres/server.crt /etc/makepad/tls/postgres/ca.crt
  install -d -o 999 -g 999 -m 0700 \
    /var/lib/makepad/postgres-backups/keycloak-brio-staging/20200101T000000Z
  printf '%s\n' preserved-encrypted-backup > \
    /var/lib/makepad/postgres-backups/keycloak-brio-staging/20200101T000000Z/sentinel
  ln -s 20200101T000000Z /var/lib/makepad/postgres-backups/keycloak-brio-staging/latest
  printf '%s\n' '{"database":"keycloak_brio_staging","encrypted":true,"backup":"20200101T000000Z"}' > \
    /var/lib/makepad/postgres-backups/keycloak-brio-staging/last-success.json
  chown -R 999:999 /var/lib/makepad/postgres-backups/keycloak-brio-staging
  printf '%s\n' prior > /tmp/mock-db-state
}

prepare_identity() {
  local id=$1
  identity_bundle="/tmp/postgres-brio-identity-bundle-${id}"
  identity_runtime="/tmp/postgres-brio-identity-runtime-${id}"
  remove_exact "${identity_bundle}"
  remove_exact "${identity_runtime}"
  install -d -m 0700 "${identity_bundle}/envs/production" "${identity_bundle}/config" "${identity_bundle}/bootstrap" "${identity_bundle}/scripts" "${identity_runtime}"
  cat > "${identity_bundle}/envs/production/.env.db" <<EOF
POSTGRES_IMAGE=${MOCK_POSTGRES_IMAGE}
BRIO_BACKUP_IMAGE=${validation_image}
POSTGRES_USER=postgres
MAKEPAD_POSTGRES_DATA_PATH=/var/lib/makepad/postgres
MAKEPAD_POSTGRES_SUPERUSER_PASSWORD_FILE_HOST_PATH=/etc/makepad/secrets/postgres-superuser-password
MAKEPAD_POSTGRES_TLS_CERT_HOST_PATH=/etc/makepad/tls/postgres/server.crt
MAKEPAD_POSTGRES_TLS_KEY_HOST_PATH=/etc/makepad/secrets/postgres-server.key
MAKEPAD_POSTGRES_CA_CERT_HOST_PATH=/etc/makepad/tls/postgres/ca.crt
MAKEPAD_POSTGRES_RUNTRACE_HBA_HOST_PATH=/srv/makepad/postgres/config/runtrace-pg_hba.conf
MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_PASSWORD_FILE_HOST_PATH=/etc/makepad/secrets/postgres-brio-identity-backup-password
MAKEPAD_POSTGRES_BRIO_BACKUP_RECIPIENT_CERT_HOST_PATH=/etc/makepad/tls/backups/brio-recipient.crt
MAKEPAD_POSTGRES_BRIO_IDENTITY_BACKUP_PATH=/var/lib/makepad/postgres-backups/keycloak-brio-staging
EOF
  cat > "${identity_bundle}/compose.host.yml" <<'EOF'
services:
  postgres:
    network_mode: host
    volumes:
      - "${MAKEPAD_POSTGRES_DATA_PATH:-/var/lib/makepad/postgres}:/var/lib/postgresql/data"
EOF
  cat > "${identity_bundle}/config/runtrace-pg_hba.conf" <<'EOF'
hostssl keycloak_brio_staging keycloak_brio_staging_app all scram-sha-256
hostssl keycloak_brio_staging keycloak_brio_staging_backup 127.0.0.1/32 scram-sha-256
host all keycloak_brio_staging_app all reject
host all keycloak_brio_staging_backup all reject
EOF
  printf '%s\n' '# bootstrap' > "${identity_bundle}/bootstrap/keycloak-brio-staging.sql"
  for script in run-runtrace-backup.sh run-runtrace-backup-loop.sh run-brio-encrypted-backup.sh run-brio-encrypted-backup-loop.sh; do
    printf '%s\n' '#!/bin/sh' 'exit 0' > "${identity_bundle}/scripts/${script}"
    chmod 0755 "${identity_bundle}/scripts/${script}"
  done
  cp "${repo}/scripts/brio-db-transaction.sh" "${identity_bundle}/scripts/brio-db-transaction.sh"
  chmod 0755 "${identity_bundle}/scripts/brio-db-transaction.sh"
  printf '%s\n' identity-app-new > "${identity_runtime}/keycloak-brio-staging-app-password"
  printf '%s\n' identity-backup-new > "${identity_runtime}/keycloak-brio-staging-backup-password"
  cp "${pki}/recipient.crt" "${identity_runtime}/brio-backup-recipient-cert.pem"
  chmod 0600 "${identity_runtime}"/*
}

assert_identity_restored() {
  [[ $(< /srv/makepad/postgres/compose.host.yml) == old-live-compose ]]
  [[ $(< /srv/makepad/postgres/config/runtrace-pg_hba.conf) == old-live-hba ]]
  [[ ! -e /etc/makepad/secrets/postgres-brio-identity-backup-password ]]
  [[ $(< /tmp/mock-db-state) == prior ]]
  [[ $(readlink /var/lib/makepad/postgres-backups/keycloak-brio-staging/latest) == 20200101T000000Z ]]
  [[ $(< /var/lib/makepad/postgres-backups/keycloak-brio-staging/20200101T000000Z/sentinel) == preserved-encrypted-backup ]]
  [[ $(< /var/lib/makepad/postgres-backups/keycloak-brio-staging/last-success.json) == '{"database":"keycloak_brio_staging","encrypted":true,"backup":"20200101T000000Z"}' ]]
  [[ $(find /var/lib/makepad/postgres-backups/keycloak-brio-staging -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ') == '20200101T000000Z last-success.json latest ' ]]
}

run_identity_failure() {
  local id=$1 injection=$2 fail_first=${3:-0}
  reset_identity_host
  prepare_identity "${id}"
  set +e
  BRIO_IDENTITY_DB_DEPLOY_CONFIRM=restart-standalone-postgres-for-brio-staging \
  BRIO_IDENTITY_DB_BACKUP_RESTORE_CONFIRMED=yes \
  BRIO_DEPLOY_TEST_MODE=isolated-container BRIO_DEPLOY_FAILURE_INJECTION="${injection}" \
  MOCK_COMPOSE_FAIL_FIRST="${fail_first}" \
    "${repo}/scripts/deploy-brio-identity-db-host.sh" "${identity_bundle}" "${identity_runtime}" 65.21.134.125 88.99.209.165/32 \
    >/tmp/identity-output 2>&1
  status=$?
  set -e
  [[ ${status} -ne 0 ]]
}

run_identity_failure 201-1 after-managed-file-promotion
assert_identity_restored
[[ ! -e /tmp/postgres-brio-identity-runtime-201-1 ]]

run_identity_failure 202-1 term-after-managed-file-promotion
assert_identity_restored
[[ ! -e /tmp/postgres-brio-identity-runtime-202-1 ]]

identity_injections=(after-bootstrap after-app-probe after-plaintext-probe after-nontarget-probe after-backup-role-probe after-backup-verification)
identity_case=210
for injection in "${identity_injections[@]}"; do
  run_identity_failure "${identity_case}-1" "${injection}"
  assert_identity_restored
  [[ ! -e "/var/lib/makepad/postgres-recovery/brio-identity/${identity_case}-1" ]]
  identity_case=$((identity_case + 1))
done

for kill_injection in kill-after-managed-file-promotion kill-after-bootstrap; do
  reset_identity_host
  prepare_identity 220-1
  set +e
  BRIO_IDENTITY_DB_DEPLOY_CONFIRM=restart-standalone-postgres-for-brio-staging \
  BRIO_IDENTITY_DB_BACKUP_RESTORE_CONFIRMED=yes BRIO_DEPLOY_TEST_MODE=isolated-container \
  BRIO_DEPLOY_FAILURE_INJECTION="${kill_injection}" \
    "${repo}/scripts/deploy-brio-identity-db-host.sh" "${identity_bundle}" "${identity_runtime}" 65.21.134.125 88.99.209.165/32 \
    >/tmp/identity-kill-output 2>&1
  kill_status=$?
  set -e
  [[ ${kill_status} -eq 137 ]]
  [[ -f /var/lib/makepad/postgres-recovery/brio-identity/220-1/IN_PROGRESS ]]
  prepare_identity 220-2
  set +e
  BRIO_IDENTITY_DB_DEPLOY_CONFIRM=restart-standalone-postgres-for-brio-staging \
  BRIO_IDENTITY_DB_BACKUP_RESTORE_CONFIRMED=yes BRIO_DEPLOY_TEST_MODE=isolated-container \
  BRIO_DEPLOY_FAILURE_INJECTION=after-managed-file-promotion \
    "${repo}/scripts/deploy-brio-identity-db-host.sh" "${identity_bundle}" "${identity_runtime}" 65.21.134.125 88.99.209.165/32 \
    >/tmp/identity-recovery-output 2>&1
  recovery_status=$?
  set -e
  [[ ${recovery_status} -ne 0 ]]
  assert_identity_restored
  [[ ! -e /var/lib/makepad/postgres-recovery/brio-identity/220-1 ]]
  remove_exact /tmp/postgres-brio-identity-runtime-220-1
done

run_identity_failure 203-1 rollback-restore 1
[[ -f /tmp/postgres-brio-identity-runtime-203-1/RECOVERY_REQUIRED ]]
[[ -f /var/lib/makepad/postgres-recovery/brio-identity/203-1/rollback/managed.tar ]]
[[ -f /var/lib/makepad/postgres-recovery/brio-identity/203-1/RECOVERY_REQUIRED ]]
[[ $(stat -c '%u:%a' /var/lib/makepad/postgres-recovery/brio-identity/203-1) == 0:700 ]]
for secret in keycloak-brio-staging-app-password keycloak-brio-staging-backup-password brio-backup-recipient-cert.pem; do
  [[ ! -e "/tmp/postgres-brio-identity-runtime-203-1/${secret}" ]]
done

run_identity_failure 204-1 rollback-recreate 1
assert_identity_restored
[[ -f /tmp/postgres-brio-identity-runtime-204-1/RECOVERY_REQUIRED ]]
[[ -f /var/lib/makepad/postgres-recovery/brio-identity/204-1/RECOVERY_REQUIRED ]]

reset_identity_host
prepare_identity 205-1
set +e
BRIO_IDENTITY_DB_DEPLOY_CONFIRM=restart-standalone-postgres-for-brio-staging \
BRIO_IDENTITY_DB_BACKUP_RESTORE_CONFIRMED=yes MOCK_COMPOSE_PROJECT=unexpected-project \
  "${repo}/scripts/deploy-brio-identity-db-host.sh" "${identity_bundle}" "${identity_runtime}" 65.21.134.125 88.99.209.165/32 \
  >/tmp/identity-target-output 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]]
grep -q 'exact Compose label' /tmp/identity-target-output
assert_identity_restored

# Every repository-controlled mutable parent is checked component-by-component
# both before snapshot and within promotion. Symlink targets remain untouched.
outside=/tmp/postgres-brio-outside-sentinel
remove_exact "${outside}"
install -d -m 0700 "${outside}"
printf '%s\n' untouched > "${outside}/sentinel"
for parent in \
  /srv/makepad /srv/makepad/postgres \
  /etc/makepad /etc/makepad/secrets /etc/makepad/tls /etc/makepad/tls/postgres /etc/makepad/tls/backups \
  /var/lib/makepad /var/lib/makepad/postgres-backups; do
  reset_identity_host
  prepare_identity 230-1
  remove_exact "${parent}"
  ln -s "${outside}" "${parent}"
  set +e
  BRIO_IDENTITY_DB_DEPLOY_CONFIRM=restart-standalone-postgres-for-brio-staging \
  BRIO_IDENTITY_DB_BACKUP_RESTORE_CONFIRMED=yes \
    "${repo}/scripts/deploy-brio-identity-db-host.sh" "${identity_bundle}" "${identity_runtime}" 65.21.134.125 88.99.209.165/32 \
    >/tmp/identity-parent-symlink-output 2>&1
  symlink_status=$?
  set -e
  [[ ${symlink_status} -ne 0 ]]
  grep -Eq 'symlink|missing|unavailable|unsafe' /tmp/identity-parent-symlink-output
  [[ $(< "${outside}/sentinel") == untouched ]]
  remove_exact "${parent}"
done
remove_exact "${outside}"

cleaner_root=/tmp/postgres-brio-cleaner-test-failures
remove_exact "${cleaner_root}"
install -d "${cleaner_root}/postgres-brio-delete" "${cleaner_root}/postgres-brio-preserve"
printf '%s\n' recovery > "${cleaner_root}/postgres-brio-preserve/RECOVERY_REQUIRED"
touch -t 202001010000 "${cleaner_root}/postgres-brio-delete" "${cleaner_root}/postgres-brio-preserve"
"${repo}/scripts/ensure-brio-tmp-cleaner.sh" test-clean-once "${cleaner_root}"
[[ ! -e "${cleaner_root}/postgres-brio-delete" ]]
[[ -f "${cleaner_root}/postgres-brio-preserve/RECOVERY_REQUIRED" ]]

# Existing host cleaners are trusted only when their entire command contract
# matches, and a stopped instance must remain running after an attempted start.
cleaner_env=/tmp/postgres-brio-cleaner-test-failures.env
printf 'POSTGRES_IMAGE=%s\n' "${MOCK_POSTGRES_IMAGE}" > "${cleaner_env}"
remove_exact /tmp/mock-cleaner-state
remove_exact /tmp/mock-cleaner-stop-after-start
BRIO_DEPLOY_TEST_MODE=isolated-container "${repo}/scripts/ensure-brio-tmp-cleaner.sh" "${cleaner_env}"
[[ $(< /tmp/mock-cleaner-state/running) == true ]]
# Docker Engine may canonicalize capability names with the CAP_ prefix.
# Both spellings must survive a retry; additional privileges must still fail.
BRIO_DEPLOY_TEST_MODE=isolated-container "${repo}/scripts/ensure-brio-tmp-cleaner.sh" "${cleaner_env}"
MOCK_CLEANER_CAP_ADD='["DAC_OVERRIDE","FOWNER"]' BRIO_DEPLOY_TEST_MODE=isolated-container \
  "${repo}/scripts/ensure-brio-tmp-cleaner.sh" "${cleaner_env}"
if MOCK_CLEANER_CAP_ADD='["CAP_DAC_OVERRIDE","CAP_FOWNER","CAP_SYS_ADMIN"]' BRIO_DEPLOY_TEST_MODE=isolated-container \
  "${repo}/scripts/ensure-brio-tmp-cleaner.sh" "${cleaner_env}" >/tmp/cleaner-capabilities-output 2>&1; then
  echo "Cleaner accepted additional capabilities." >&2
  exit 1
fi
grep -q 'does not match the fail-closed cleanup contract' /tmp/cleaner-capabilities-output
printf '%s\n' 'unexpected cleaner command' > /tmp/mock-cleaner-state/command
set +e
BRIO_DEPLOY_TEST_MODE=isolated-container "${repo}/scripts/ensure-brio-tmp-cleaner.sh" "${cleaner_env}" >/tmp/cleaner-command-output 2>&1
cleaner_command_status=$?
set -e
[[ ${cleaner_command_status} -ne 0 ]]
grep -q 'does not match the fail-closed cleanup contract' /tmp/cleaner-command-output
remove_exact /tmp/mock-cleaner-state
BRIO_DEPLOY_TEST_MODE=isolated-container "${repo}/scripts/ensure-brio-tmp-cleaner.sh" "${cleaner_env}"
printf '%s\n' false > /tmp/mock-cleaner-state/running
touch /tmp/mock-cleaner-stop-after-start
set +e
BRIO_DEPLOY_TEST_MODE=isolated-container "${repo}/scripts/ensure-brio-tmp-cleaner.sh" "${cleaner_env}" >/tmp/cleaner-running-output 2>&1
cleaner_running_status=$?
set -e
[[ ${cleaner_running_status} -ne 0 ]]
grep -q 'did not remain running after startup' /tmp/cleaner-running-output
remove_exact /tmp/mock-cleaner-stop-after-start

echo "Brio deployment failure-injection tests passed."
