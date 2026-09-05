#!/usr/bin/env bash
set -Eeuo pipefail

export PATH=/usr/bin:/bin
umask 077

readonly expected_command=shared-runtime-observe
readonly expected_container=postgres-postgres-1
readonly expected_project=postgres
readonly expected_service=postgres
readonly image_pattern='^postgres:16-alpine@sha256:[a-f0-9]{64}$'
readonly image_id_pattern='^sha256:[a-f0-9]{64}$'

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

docker_short() {
  timeout --signal=KILL 20s docker "$@"
}

(( EUID == 0 )) || die 'The Brio PostgreSQL runtime observer must run through its exact passwordless sudo rule.'
[[ "${SSH_ORIGINAL_COMMAND:-}" == "${expected_command}" ]] || \
  die 'The Brio PostgreSQL runtime observer accepts only shared-runtime-observe.'

record=$(docker_short inspect --type container --format \
  '{{.Id}}|{{.Name}}|{{.Config.Image}}|{{.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}|{{.State.StartedAt}}|{{.RestartCount}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.oneoff"}}|{{index .Config.Labels "com.docker.compose.config-hash"}}|{{.HostConfig.NetworkMode}}' \
  "${expected_container}") || die 'Cannot inspect the shared PostgreSQL container.'
IFS='|' read -r container_id container_name image runtime_image_id state health started_at restart_count \
  compose_project compose_service compose_oneoff config_hash network_mode <<< "${record}"

[[ "${container_id}" =~ ^[a-f0-9]{64}$ && "${container_name}" == "/${expected_container}" ]] || \
  die 'Shared PostgreSQL returned an invalid container identity.'
[[ "${image}" =~ ${image_pattern} && "${runtime_image_id}" =~ ${image_id_pattern} ]] || \
  die 'Shared PostgreSQL is not running an immutable reviewed image reference.'
[[ "${state}" == running && "${health}" == healthy ]] || die 'Shared PostgreSQL is not running and healthy.'
[[ "${compose_project}" == "${expected_project}" && "${compose_service}" == "${expected_service}" \
  && "${compose_oneoff}" == False && "${network_mode}" == host ]] || \
  die 'Shared PostgreSQL has unexpected Compose identity or network mode.'
[[ "${config_hash}" =~ ^[a-f0-9]{64}$ ]] || die 'Shared PostgreSQL has an invalid Compose configuration digest.'
[[ "${started_at}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+-]+Z$ && "${restart_count}" =~ ^[0-9]+$ ]] || \
  die 'Shared PostgreSQL returned invalid lifecycle identity.'

resolved_image_id=$(docker_short image inspect "${image}" --format '{{.Id}}') || \
  die 'Cannot resolve the shared PostgreSQL immutable image reference.'
[[ "${resolved_image_id}" == "${runtime_image_id}" ]] || \
  die 'Shared PostgreSQL container content does not match its immutable image reference.'
version_output=$(docker_short exec "${container_id}" postgres --version 2>&1) || \
  die 'Cannot read the running PostgreSQL version.'
[[ "${version_output}" =~ ^postgres\ \(PostgreSQL\)\ (16\.[0-9]+)(\.[0-9]+)?$ ]] || \
  die 'Shared PostgreSQL returned an unexpected runtime version.'
version=${BASH_REMATCH[1]}${BASH_REMATCH[2]:-}

python3 - "${image}" "${runtime_image_id}" "${version}" "${container_id}" \
  "${started_at}" "${restart_count}" "${config_hash}" <<'PY'
import json
import sys

image, image_id, version, container_id, started_at, restart_count, config_hash = sys.argv[1:]
payload = {
    "schema": "makepad.brio.runtime-host-observation.v1",
    "hostRole": "database",
    "components": [{
        "name": "postgres",
        "orchestrator": "compose",
        "unit": "postgres/postgres",
        "image": image,
        "runtimeImageID": image_id,
        "configDigest": f"sha256:{config_hash}",
        "version": version,
        "state": "running",
        "health": "healthy",
        "instanceID": f"sha256:{container_id}",
        "startedAt": started_at,
        "restartCount": int(restart_count),
    }],
}
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
