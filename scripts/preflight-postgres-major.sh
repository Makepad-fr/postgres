#!/usr/bin/env bash
set -euo pipefail

data_path=${1:?Usage: preflight-postgres-major.sh <data-path> [expected-major]}
expected_major=${2:-18}

if [[ "${data_path}" != /* || "${data_path}" == / || "${data_path}" == /var || "${data_path}" == /var/lib ]]; then
  echo "PostgreSQL data path must be a narrow absolute path." >&2
  exit 1
fi
if [[ ! "${expected_major}" =~ ^[0-9]+$ ]]; then
  echo "Expected PostgreSQL major must be numeric." >&2
  exit 1
fi
if [[ -L "${data_path}" ]]; then
  echo "PostgreSQL data path must not be a symlink: ${data_path}" >&2
  exit 1
fi
if [[ -e "${data_path}" && ! -d "${data_path}" ]]; then
  echo "PostgreSQL data path is not a directory: ${data_path}" >&2
  exit 1
fi

version_file=${data_path}/PG_VERSION
if [[ ! -e "${version_file}" ]]; then
  # A missing directory or genuinely empty/new data directory is initialized by
  # the pinned image. Non-empty unrecognized directories are never accepted.
  if [[ -d "${data_path}" && -n "$(find "${data_path}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Non-empty PostgreSQL data path has no PG_VERSION marker: ${data_path}" >&2
    exit 1
  fi
  exit 0
fi
if [[ ! -f "${version_file}" || -L "${version_file}" ]]; then
  echo "PostgreSQL PG_VERSION must be a regular non-symlink file." >&2
  exit 1
fi

actual_major=$(tr -d '[:space:]' < "${version_file}")
if [[ "${actual_major}" != "${expected_major}" ]]; then
  echo "Refusing PostgreSQL ${expected_major} against data initialized by PostgreSQL ${actual_major}. Complete docs/postgresql-18-upgrade.md first." >&2
  exit 1
fi
