#!/usr/bin/env bash
set -euo pipefail

clean_test_root() {
  local test_root=$1
  [[ "${test_root}" =~ ^/tmp/postgres-brio-cleaner-test-[A-Za-z0-9._-]+$ ]] || {
    echo "Test cleanup root must use /tmp/postgres-brio-cleaner-test-<suffix>." >&2
    exit 2
  }
  find "${test_root}" -mindepth 1 -maxdepth 1 -type d \
    \( -name 'postgres-brio-*' -o -name 'postgres-keycloak-cohort-*' \) -mmin +180 \
    -exec sh -euc 'for directory do
      [ ! -L "${directory}" ] || continue
      [ ! -f "${directory}/RECOVERY_REQUIRED" ] || continue
      find "${directory}" -depth -delete
    done' sh {} +
}

if (($# == 2)) && [[ "$1" == "test-clean-once" ]]; then
  clean_test_root "$2"
  exit 0
fi

if (($# == 3)) && [[ "$1" == "test-clean-production-ownership" ]]; then
  test_root=$2
  test_image=$3
  [[ "${test_root}" =~ ^/tmp/postgres-brio-cleaner-test-[A-Za-z0-9._-]+$ \
    && "${test_image}" == *@sha256:* ]] || { echo "Unsafe production-ownership cleaner test inputs." >&2; exit 2; }
  docker run --rm --read-only --cap-drop ALL --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --security-opt no-new-privileges --mount "type=bind,src=${test_root},dst=/host-tmp" \
    "${test_image}" sh -euc '
      find /host-tmp -mindepth 1 -maxdepth 1 -type d \
        \( -name "postgres-brio-*" -o -name "postgres-keycloak-cohort-*" \) -mmin +180 \
        -exec sh -euc '\''for directory do
          [ ! -L "$directory" ] || continue
          [ ! -f "$directory/RECOVERY_REQUIRED" ] || continue
          find "$directory" -depth -delete
        done'\'' sh {} +
    '
  exit 0
fi

if (($# != 1)); then
  echo "Usage: ensure-brio-tmp-cleaner.sh <database-env-file>" >&2
  exit 2
fi

db_env=$1
[[ -f "${db_env}" && ! -L "${db_env}" ]] || { echo "Database environment file is missing or a symlink." >&2; exit 2; }
postgres_image=$(grep '^POSTGRES_IMAGE=' "${db_env}" | tail -n 1 | cut -d= -f2-)
: "${postgres_image:?POSTGRES_IMAGE is missing from ${db_env}}"
[[ "${postgres_image}" == *@sha256:* ]] || { echo "The temporary-material cleaner requires a digest-pinned image." >&2; exit 1; }

cleaner_name=makepad-postgres-brio-tmp-cleaner
cleaner_contract=brio-tmp-cleaner-v5-exact-command
# shellcheck disable=SC2016 # The nested shell expands directory inside the container.
cleaner_command='while :; do
  find /host-tmp -mindepth 1 -maxdepth 1 -type d \
    \( -name "postgres-brio-*" -o -name "postgres-keycloak-cohort-*" \) -mmin +180 \
    -exec sh -euc '\''for directory do
      [ ! -L "${directory}" ] || continue
      [ ! -f "${directory}/RECOVERY_REQUIRED" ] || continue
      find "${directory}" -depth -delete
    done'\'' sh {} +
  sleep 900
done'

verify_running() {
  local state attempts=10 delay=1
  if [[ "${BRIO_DEPLOY_TEST_MODE:-}" == isolated-container ]]; then attempts=2; delay=0; fi
  for _ in $(seq 1 "${attempts}"); do
    state=$(docker container inspect "${cleaner_name}" --format '{{.State.Running}}|{{.State.Restarting}}' 2>/dev/null || true)
    [[ "${state}" != "true|false" ]] || return 0
    sleep "${delay}"
  done
  echo "${cleaner_name} did not remain running after startup." >&2
  return 1
}

if docker container inspect "${cleaner_name}" >/dev/null 2>&1; then
  image=$(docker container inspect "${cleaner_name}" --format '{{.Config.Image}}')
  contract=$(docker container inspect "${cleaner_name}" --format '{{index .Config.Labels "makepad.cleanup.contract"}}')
  restart_policy=$(docker container inspect "${cleaner_name}" --format '{{.HostConfig.RestartPolicy.Name}}')
  readonly_root=$(docker container inspect "${cleaner_name}" --format '{{.HostConfig.ReadonlyRootfs}}')
  mount_contract=$(docker container inspect "${cleaner_name}" --format '{{range .Mounts}}{{if eq .Destination "/host-tmp"}}{{printf "%s|%s|%t" .Type .Source .RW}}{{end}}{{end}}')
  cap_drop=$(docker container inspect "${cleaner_name}" --format '{{json .HostConfig.CapDrop}}')
  cap_add=$(docker container inspect "${cleaner_name}" --format '{{json .HostConfig.CapAdd}}')
  security_opt=$(docker container inspect "${cleaner_name}" --format '{{json .HostConfig.SecurityOpt}}')
  observed_command_length=$(docker container inspect "${cleaner_name}" --format '{{len .Config.Cmd}}')
  observed_shell=$(docker container inspect "${cleaner_name}" --format '{{index .Config.Cmd 0}}')
  observed_shell_flags=$(docker container inspect "${cleaner_name}" --format '{{index .Config.Cmd 1}}')
  observed_command=$(docker container inspect "${cleaner_name}" --format '{{index .Config.Cmd 2}}')
  if [[ "${image}" != "${postgres_image}" || "${contract}" != "${cleaner_contract}" \
    || "${restart_policy}" != "unless-stopped" || "${readonly_root}" != "true" \
    || "${mount_contract}" != "bind|/tmp|true" || "${cap_drop}" != '["ALL"]' \
    || "${cap_add}" != '["DAC_OVERRIDE","FOWNER"]' \
    || "${security_opt}" != *'no-new-privileges'* || "${observed_command_length}" != 3 \
    || "${observed_shell}" != sh || "${observed_shell_flags}" != -euc \
    || "${observed_command}" != "${cleaner_command}" ]]; then
    echo "Existing ${cleaner_name} does not match the fail-closed cleanup contract." >&2
    exit 1
  fi
  if [[ $(docker container inspect "${cleaner_name}" --format '{{.State.Running}}') != "true" ]]; then
    docker start "${cleaner_name}" >/dev/null
  fi
  verify_running
  exit $?
fi

docker run -d \
  --name "${cleaner_name}" \
  --restart unless-stopped \
  --read-only \
  --cap-drop ALL \
  --cap-add DAC_OVERRIDE \
  --cap-add FOWNER \
  --security-opt no-new-privileges \
  --label "makepad.cleanup.contract=${cleaner_contract}" \
  --mount type=bind,src=/tmp,dst=/host-tmp \
  "${postgres_image}" \
  sh -euc "${cleaner_command}" >/dev/null
verify_running
