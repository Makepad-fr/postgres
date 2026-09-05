#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if (($# != 1)); then
  echo "usage: capture-keycloak-cohort-backups.sh /tmp/postgres-keycloak-cohort-<run>-<attempt>" >&2
  exit 2
fi

output_dir=$1
run_id=${COHORT_CAPTURE_RUN_ID:-}
run_attempt=${COHORT_CAPTURE_RUN_ATTEMPT:-}
postgres_image='postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777'
container=postgres-postgres-1
[[ "${run_id}" =~ ^[1-9][0-9]*$ && "${run_attempt}" =~ ^[1-9][0-9]*$ ]] || {
  echo "Exact positive workflow run and attempt are required." >&2
  exit 2
}
[[ "${output_dir}" == "/tmp/postgres-keycloak-cohort-${run_id}-${run_attempt}" ]] || {
  echo "Backup output must be the exact run-scoped /tmp path." >&2
  exit 2
}
[[ -d /tmp && ! -L /tmp && ! -e "${output_dir}" && ! -L "${output_dir}" ]] || {
  echo "Refusing an unsafe or reused cohort backup output path." >&2
  exit 1
}
for command_name in docker sha256sum; do
  command -v "${command_name}" >/dev/null || { echo "${command_name} is required." >&2; exit 1; }
done

cleanup_on_failure() {
  local status=$?
  trap - EXIT HUP INT TERM
  if ((status != 0)) && [[ -d "${output_dir}" && ! -L "${output_dir}" ]]; then
    find "${output_dir}" -mindepth 1 -delete
    rmdir "${output_dir}"
  fi
  exit "${status}"
}
trap cleanup_on_failure EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
install -d -m 0700 "${output_dir}"

inspect=$(docker inspect "${container}" --format '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}')
IFS='|' read -r compose_project compose_service observed_image state health <<<"${inspect}"
[[ "${compose_project}" == postgres && "${compose_service}" == postgres && "${observed_image}" == "${postgres_image}" \
  && "${state}" == running && "${health}" == healthy ]] || {
  echo "The exact healthy production PostgreSQL container is not present." >&2
  exit 1
}

databases=(
  keycloak_betacrew
  keycloak_catwlk
  keycloak_makepad
  keycloak_runtrace
  keycloak_vestiaire
  keycloak_vif
)
for database in "${databases[@]}"; do
  exists=$(docker exec "${container}" sh -euc '
    export PGPASSWORD="$(cat /run/secrets/postgres_superuser_password)"
    exec psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc \
      "SELECT count(*) FROM pg_database WHERE datname = '\''$1'\'' AND datallowconn"
  ' sh "${database}")
  [[ "${exists}" == 1 ]] || { echo "Required database ${database} is missing or disallows connections." >&2; exit 1; }
  partial="${output_dir}/.${database}.dump.partial"
  final="${output_dir}/${database}.dump"
  docker exec "${container}" sh -euc '
    export PGPASSWORD="$(cat /run/secrets/postgres_superuser_password)"
    exec pg_dump -h 127.0.0.1 -U postgres --format=custom --compress=6 \
      --no-owner --no-privileges --dbname "$1"
  ' sh "${database}" >"${partial}"
  [[ -s "${partial}" && ! -L "${partial}" ]] || { echo "Empty backup for ${database}." >&2; exit 1; }
  docker run --rm --read-only --network none --cap-drop ALL --security-opt no-new-privileges:true \
    --mount "type=bind,src=${partial},dst=/backup.dump,readonly" \
    "${postgres_image}" pg_restore --list /backup.dump >/dev/null
  chmod 0600 "${partial}"
  mv -T "${partial}" "${final}"
done

expected=$(printf '%s\n' "${databases[@]/%/.dump}" | sort)
observed=$(find "${output_dir}" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "${observed}" == "${expected}" ]] || { echo "Cohort backup directory has an unexpected entry set." >&2; exit 1; }
sha256sum "${output_dir}"/*.dump >/dev/null
trap - EXIT HUP INT TERM
echo "Captured and structurally validated the exact six Keycloak databases."
