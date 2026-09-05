#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

[[ "$(id -u)" -eq 0 ]] || { echo "The cohort resource cleaner must run as root." >&2; exit 1; }
for command_name in date docker find; do command -v "${command_name}" >/dev/null || { echo "${command_name} is required." >&2; exit 1; }; done

now=$(date +%s)
contract=makepad-keycloak-cohort-restore-v1

remove_expired_container() {
  local identifier=$1 details name observed_contract expires
  details=$(docker container inspect "${identifier}" --format '{{.Name}}|{{index .Config.Labels "makepad.cleanup.contract"}}|{{index .Config.Labels "makepad.cleanup.expires-epoch"}}')
  IFS='|' read -r name observed_contract expires <<<"${details}"
  name=${name#/}
  [[ "${name}" =~ ^pg-kc-(db|app)-[1-9][0-9]*-[1-9][0-9]*-(catwlk|makepad|runtrace|vestiaire|vif)$ \
    && "${observed_contract}" == "${contract}" && "${expires}" =~ ^[1-9][0-9]*$ ]] || {
    echo "Refusing malformed labeled cohort container ${identifier}." >&2
    return 1
  }
  ((expires > now)) || docker rm -f "${identifier}" >/dev/null
}

remove_expired_network() {
  local identifier=$1 details name observed_contract expires
  details=$(docker network inspect "${identifier}" --format '{{.Name}}|{{index .Labels "makepad.cleanup.contract"}}|{{index .Labels "makepad.cleanup.expires-epoch"}}')
  IFS='|' read -r name observed_contract expires <<<"${details}"
  [[ "${name}" =~ ^pg-kc-[1-9][0-9]*-[1-9][0-9]*-(catwlk|makepad|runtrace|vestiaire|vif)$ \
    && "${observed_contract}" == "${contract}" && "${expires}" =~ ^[1-9][0-9]*$ ]] || {
    echo "Refusing malformed labeled cohort network ${identifier}." >&2
    return 1
  }
  ((expires > now)) || docker network rm "${identifier}" >/dev/null
}

while IFS= read -r identifier; do [[ -z "${identifier}" ]] || remove_expired_container "${identifier}"; done \
  < <(docker container ls -aq --filter "label=makepad.cleanup.contract=${contract}")
while IFS= read -r identifier; do [[ -z "${identifier}" ]] || remove_expired_network "${identifier}"; done \
  < <(docker network ls -q --filter "label=makepad.cleanup.contract=${contract}")

find /tmp -mindepth 1 -maxdepth 1 -type d -name 'postgres-keycloak-cohort-*' -mmin +180 \
  -exec sh -euc 'for directory do
    [ ! -L "$directory" ] || continue
    [ ! -f "$directory/RECOVERY_REQUIRED" ] || continue
    find "$directory" -depth -delete
  done' sh {} +
