#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ "$(id -u)" -eq 0 ]] || { echo "controller supervisor must run as root" >&2; exit 1; }
exec 9>/run/lock/postgres-ci-queue-controller.lock
flock -n 9 || { echo "another Postgres queue controller owns the hypervisor" >&2; exit 1; }
script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
exec node "${script_directory}/postgres-ci-queue-controller.mjs" "$@"
