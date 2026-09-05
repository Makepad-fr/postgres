#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if (($# != 4)); then
  echo "usage: restore-keycloak-cohort-backups.sh <six-dump-directory> <result-directory> <keycloak-release-source> <catwlk-runtime-image>" >&2
  exit 2
fi

backup_dir=$1
result_dir=$2
keycloak_source=$3
catwlk_image=$4
keycloak_image='dhi.io/keycloak:26-debian13@sha256:fab1484b1762fd1269e63a40f068ec73ea75b498eaaa5d02f62f022a5d00ff0f'
postgres_image='postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777'
run_id=${GITHUB_RUN_ID:-1}
run_attempt=${GITHUB_RUN_ATTEMPT:-1}
[[ "${run_id}" =~ ^[1-9][0-9]*$ && "${run_attempt}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid run identity." >&2; exit 2; }
[[ -d "${backup_dir}" && ! -L "${backup_dir}" && ! -e "${result_dir}" && ! -L "${result_dir}" \
  && -d "${keycloak_source}" && ! -L "${keycloak_source}" ]] || {
  echo "Backup/source inputs must be real directories and result output must be new." >&2
  exit 1
}
[[ "${catwlk_image}" == "makepad/keycloak-catwlk-cohort:"* ]] || { echo "Catwlk runtime tag is outside the reviewed namespace." >&2; exit 2; }
for command_name in docker git python3 sha256sum; do command -v "${command_name}" >/dev/null || { echo "${command_name} is required." >&2; exit 1; }; done

declare -A databases=(
  [betacrew]=keycloak_betacrew
  [catwlk]=keycloak_catwlk
  [makepad]=keycloak_makepad
  [runtrace]=keycloak_runtrace
  [vestiaire]=keycloak_vestiaire
  [vif]=keycloak_vif
)
declare -A category_tables=(
  [realm]='realm realm_attribute realm_default_groups realm_enabled_event_types realm_events_listeners realm_localizations realm_required_credential realm_smtp_config realm_supported_locales'
  [authentication]='authentication_flow authentication_execution authenticator_config authenticator_config_entry'
  [roles]='keycloak_role role_attribute composite_role scope_mapping'
  [clients]='client client_attributes client_auth_flow_bindings redirect_uris web_origins client_scope client_scope_attributes client_scope_client client_scope_role_mapping default_client_scope protocol_mapper protocol_mapper_config'
  [identity_providers]='identity_provider identity_provider_config identity_provider_mapper idp_mapper_config'
  [components]='component component_config'
  [required_actions]='required_action_provider'
)
expected=$(for slug in "${!databases[@]}"; do printf '%s.dump\n' "${databases[$slug]}"; done | sort)
observed=$(find "${backup_dir}" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "${observed}" == "${expected}" ]] || { echo "Backup input is not the exact six-database cohort." >&2; exit 1; }
if find "${backup_dir}" -mindepth 1 -maxdepth 1 -type l -print -quit | grep -q .; then echo "Backup input contains a symlink." >&2; exit 1; fi

release_sha=$(git -C "${keycloak_source}" rev-parse HEAD)
[[ "${release_sha}" =~ ^[a-f0-9]{40}$ ]] || { echo "Checked-out Keycloak release SHA is invalid." >&2; exit 1; }
python3 - "${keycloak_source}/instances/catwlk/manifest.json" <<'PY'
import json, pathlib, sys
value=json.loads(pathlib.Path(sys.argv[1]).read_text())["runtime"]
expected={"source_dir":"providers/catwlk-email-router","dockerfile":"providers/catwlk-email-router/Dockerfile","image":"makepad/keycloak-catwlk"}
if value != expected: raise SystemExit("Catwlk manifest does not select the reviewed custom runtime")
PY
grep -Fxq 'com.makepad.catwlk.keycloak.email.RoutingEmailSenderProviderFactory' \
  "${keycloak_source}/providers/catwlk-email-router/src/main/resources/META-INF/services/org.keycloak.email.EmailSenderProviderFactory"
grep -Fxq 'com.makepad.catwlk.keycloak.apple.CatwlkAppleIdentityProviderFactory' \
  "${keycloak_source}/providers/catwlk-email-router/src/main/resources/META-INF/services/org.keycloak.broker.provider.IdentityProviderFactory"
catwlk_image_id=$(docker image inspect "${catwlk_image}" --format '{{.Id}}')
catwlk_base=$(docker image inspect "${catwlk_image}" --format '{{index .Config.Labels "org.makepad.keycloak.base-image"}}')
catwlk_source_sha=$(docker image inspect "${catwlk_image}" --format '{{index .Config.Labels "org.makepad.keycloak.source-sha"}}')
catwlk_runtime=$(docker image inspect "${catwlk_image}" --format '{{index .Config.Labels "org.makepad.keycloak.runtime"}}')
[[ "${catwlk_image_id}" =~ ^sha256:[a-f0-9]{64}$ && "${catwlk_base}" == "${keycloak_image}" \
  && "${catwlk_source_sha}" == "${release_sha}" && "${catwlk_runtime}" == catwlk-custom-provider ]] || {
  echo "Catwlk image is not the exact custom-provider runtime from the checked-out release." >&2
  exit 1
}
docker run --rm --network none --read-only --entrypoint sh "${catwlk_image}" -euc \
  'test -s /opt/keycloak/providers/catwlk-keycloak-email-router.jar'

umask 077
install -d -m 0700 "${result_dir}" "${result_dir}/.runtime"
records="${result_dir}/.instances.jsonl"
: >"${records}"
active_network=
active_database_container=
active_keycloak_container=
cleanup_active() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  [[ -z "${active_keycloak_container}" ]] || docker rm -f "${active_keycloak_container}" >/dev/null 2>&1
  [[ -z "${active_database_container}" ]] || docker rm -f "${active_database_container}" >/dev/null 2>&1
  [[ -z "${active_network}" ]] || docker network rm "${active_network}" >/dev/null 2>&1
  if ((status != 0)) && [[ -d "${result_dir}" && ! -L "${result_dir}" ]]; then find "${result_dir}" -depth -delete; fi
  exit "${status}"
}
trap cleanup_active EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

db_query() {
  local sql=$1
  docker exec "${active_database_container}" sh -euc '
    export PGPASSWORD="$(cat /run/secrets/postgres-password)"
    exec psql -X -v ON_ERROR_STOP=1 -U keycloak -d keycloak -At -c "$1"
  ' sh "${sql}"
}

fingerprint_configuration() {
  local destination_name=$1 category table exists digest
  local -n destination="${destination_name}"
  for category in $(printf '%s\n' "${!category_tables[@]}" | sort); do
    for table in ${category_tables[$category]}; do
      exists=$(db_query "SELECT CASE WHEN to_regclass('public.${table}') IS NULL THEN 0 ELSE 1 END")
      [[ "${exists}" == 1 ]] || { echo "Keycloak configuration fingerprint schema is missing required table ${table}." >&2; return 1; }
    done
    digest=$(
      {
        for table in ${category_tables[$category]}; do
          printf 'table\t%s\n' "${table}"
          db_query "SELECT to_jsonb(value)::text FROM ${table} AS value ORDER BY to_jsonb(value)::text"
        done
      } | sha256sum | cut -d' ' -f1
    )
    [[ "${digest}" =~ ^[a-f0-9]{64}$ ]] || return 1
    # shellcheck disable=SC2034 # destination is an associative nameref output.
    destination["${category}"]=${digest}
  done
}

for slug in $(printf '%s\n' "${!databases[@]}" | sort); do
  database=${databases[$slug]}
  dump="${backup_dir}/${database}.dump"
  [[ -s "${dump}" && -f "${dump}" && ! -L "${dump}" ]] || { echo "Invalid dump for ${slug}." >&2; exit 1; }
  docker run --rm --read-only --network none --cap-drop ALL --security-opt no-new-privileges:true \
    --mount "type=bind,src=${dump},dst=/backup.dump,readonly" "${postgres_image}" pg_restore --list /backup.dump >/dev/null
  backup_sha=$(sha256sum "${dump}" | cut -d' ' -f1)
  suffix="${run_id}-${run_attempt}-${slug}"
  active_network="pg-kc-${suffix}"
  active_database_container="pg-kc-db-${suffix}"
  active_keycloak_container="pg-kc-app-${suffix}"
  secret_file="${result_dir}/.runtime/${slug}-postgres-password"
  python3 - "${secret_file}" <<'PY'
import pathlib, secrets, sys
pathlib.Path(sys.argv[1]).write_text(secrets.token_urlsafe(48) + "\n")
PY
  chmod 0600 "${secret_file}"
  expires_epoch=$(( $(date +%s) + 10800 ))
  labels=(--label makepad.cleanup.contract=makepad-keycloak-cohort-restore-v1 \
    --label "makepad.cleanup.run=${run_id}-${run_attempt}" --label "makepad.cleanup.expires-epoch=${expires_epoch}")
  docker network create --internal "${labels[@]}" "${active_network}" >/dev/null
  docker run -d --name "${active_database_container}" --network "${active_network}" --network-alias db \
    "${labels[@]}" --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m --tmpfs /run/postgresql:rw,noexec,nosuid,size=16m \
    --tmpfs /var/lib/postgresql/data:rw,nosuid,size=2g --cap-drop ALL --security-opt no-new-privileges:true \
    --mount "type=bind,src=${secret_file},dst=/run/secrets/postgres-password,readonly" \
    -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres-password -e POSTGRES_DB=postgres \
    "${postgres_image}" >/dev/null
  ready=0
  for _ in $(seq 1 60); do
    if docker exec "${active_database_container}" pg_isready -U postgres -d postgres >/dev/null 2>&1; then ready=1; break; fi
    [[ $(docker inspect "${active_database_container}" --format '{{.State.Running}}') == true ]] || break
    sleep 1
  done
  [[ "${ready}" == 1 ]] || { docker logs "${active_database_container}" >&2; echo "Disposable PostgreSQL did not become ready." >&2; exit 1; }
  docker exec "${active_database_container}" sh -euc '
    export PGPASSWORD="$(cat /run/secrets/postgres-password)"
    export KEYCLOAK_PASSWORD="$PGPASSWORD"
    { printf "%s\n" "\\getenv keycloak_password KEYCLOAK_PASSWORD"; printf "%s\n" "SELECT format('\''CREATE ROLE keycloak LOGIN PASSWORD %L'\'', :'\''keycloak_password'\'') \\gexec" "CREATE DATABASE keycloak OWNER keycloak;"; } |
      psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null
  '
  docker run --rm --network "${active_network}" --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --mount "type=bind,src=${dump},dst=/backup.dump,readonly" \
    --mount "type=bind,src=${secret_file},dst=/run/secrets/postgres-password,readonly" \
    "${postgres_image}" sh -euc 'export PGPASSWORD="$(cat /run/secrets/postgres-password)"; exec pg_restore -h db -U keycloak -d keycloak --no-owner --no-privileges --exit-on-error /backup.dump' >/dev/null
  realm_count=$(db_query 'SELECT count(*) FROM realm')
  [[ "${realm_count}" =~ ^[1-9][0-9]*$ ]] || { echo "Restored ${slug} database has no realm." >&2; exit 1; }
  declare -A before=() after=()
  fingerprint_configuration before
  runtime_image=${keycloak_image}
  runtime_kind=keycloak-base
  runtime_evidence_image=${keycloak_image}
  if [[ "${slug}" == catwlk ]]; then runtime_image=${catwlk_image}; runtime_evidence_image=${catwlk_image_id}; runtime_kind=catwlk-custom-provider; fi
  keycloak_uid=$(docker run --rm --network none --entrypoint id "${runtime_image}" -u)
  [[ "${keycloak_uid}" =~ ^[1-9][0-9]*$ ]] || { echo "Keycloak runtime must use a non-root numeric user." >&2; exit 1; }
  docker run --rm --network none --cap-drop ALL --cap-add CHOWN --security-opt no-new-privileges:true \
    --mount "type=bind,src=${secret_file},dst=/secret" "${postgres_image}" chown "${keycloak_uid}:0" /secret
  chmod 0400 "${secret_file}"
  docker run -d --name "${active_keycloak_container}" --network "${active_network}" --network-alias keycloak \
    "${labels[@]}" --read-only --tmpfs /tmp:rw,noexec,nosuid,size=256m \
    --tmpfs "/opt/keycloak/data:rw,nosuid,size=256m,uid=${keycloak_uid},gid=0,mode=0770" \
    --cap-drop ALL --security-opt no-new-privileges:true --entrypoint sh \
    --mount "type=bind,src=${secret_file},dst=/run/secrets/postgres-password,readonly" \
    -e KC_DB=postgres -e KC_DB_URL=jdbc:postgresql://db:5432/keycloak -e KC_DB_USERNAME=keycloak \
    -e KC_HEALTH_ENABLED=true -e KC_HTTP_ENABLED=true -e KC_HOSTNAME_STRICT=false \
    "${runtime_image}" -euc 'export KC_DB_PASSWORD="$(cat /run/secrets/postgres-password)"; exec /opt/keycloak/bin/kc.sh start-dev' >/dev/null
  ready=0
  for _ in $(seq 1 180); do
    if docker run --rm --network "${active_network}" --read-only --cap-drop ALL --security-opt no-new-privileges:true \
      "${postgres_image}" sh -euc 'wget -qO- http://keycloak:9000/health/ready' 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"UP"'; then ready=1; break; fi
    [[ $(docker inspect "${active_keycloak_container}" --format '{{.State.Running}}') == true ]] || break
    sleep 1
  done
  [[ "${ready}" == 1 ]] || { docker logs "${active_keycloak_container}" >&2; echo "Keycloak 26.7.3 did not become ready for restored ${slug}." >&2; exit 1; }
  fingerprint_configuration after
  fingerprints=()
  for category in $(printf '%s\n' "${!category_tables[@]}" | sort); do
    [[ "${after[$category]}" == "${before[$category]}" ]] || { echo "Keycloak ${category} configuration regression detected for ${slug}." >&2; exit 1; }
    fingerprints+=("${category}=${after[$category]}")
  done
  combined=$(printf '%s\n' "${fingerprints[@]}" | sha256sum | cut -d' ' -f1)
  python3 - "${records}" "${slug}" "${database}" "${backup_sha}" "${runtime_kind}" "${runtime_evidence_image}" "${combined}" "${fingerprints[@]}" <<'PY'
import json, pathlib, sys
fingerprints=dict(item.split("=", 1) for item in sys.argv[8:])
record={"slug":sys.argv[2],"database":sys.argv[3],"backup_sha256":sys.argv[4],"runtime":sys.argv[5],"runtime_image":sys.argv[6],"configuration_fingerprint":sys.argv[7],"configuration_fingerprints":fingerprints,"restore":"passed","keycloak_startup":"passed","configuration_regression":"passed"}
with pathlib.Path(sys.argv[1]).open("a", encoding="utf-8") as target: target.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
  docker rm -f "${active_keycloak_container}" "${active_database_container}" >/dev/null
  active_keycloak_container=
  active_database_container=
  docker network rm "${active_network}" >/dev/null
  active_network=
  rm -f "${secret_file}"
  unset before after
done

python3 - "${records}" "${result_dir}/instances.json" "${catwlk_image_id}" <<'PY'
import json, pathlib, sys
instances=[json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
payload={"catwlk_runtime_image_id":sys.argv[3],"instances":instances}
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
rm -f "${records}"
rmdir "${result_dir}/.runtime"
chmod 0600 "${result_dir}/instances.json"
trap - EXIT HUP INT TERM
echo "Restored all six Keycloak databases with exact runtimes and verified complete configuration fingerprints."
