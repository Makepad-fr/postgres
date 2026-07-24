#!/bin/sh
set -eu

interval_seconds=${RUNTRACE_BACKUP_INTERVAL_SECONDS:-21600}
retry_seconds=${RUNTRACE_BACKUP_RETRY_SECONDS:-300}
backup_root=${RUNTRACE_BACKUP_ROOT:-/backups}

validate_timing_value() {
  case "$2" in
    ''|*[!0-9]*)
      echo "$1 must be a positive integer." >&2
      exit 1
      ;;
  esac
}
validate_timing_value RUNTRACE_BACKUP_INTERVAL_SECONDS "${interval_seconds}"
validate_timing_value RUNTRACE_BACKUP_RETRY_SECONDS "${retry_seconds}"
if [ "${interval_seconds}" -lt 300 ] || [ "${retry_seconds}" -lt 30 ]; then
  echo "Runtrace backup interval must be at least 300 seconds and retry delay at least 30 seconds." >&2
  exit 1
fi

if [ "${1:-}" = "healthcheck" ]; then
  status_file=${backup_root}/last-success.json
  [ -s "${status_file}" ] || exit 1
  now=$(date +%s)
  if modified=$(stat -c %Y "${status_file}" 2>/dev/null); then
    :
  else
    modified=$(stat -f %m "${status_file}")
  fi
  max_age=$((interval_seconds * 2 + retry_seconds))
  [ $((now - modified)) -le "${max_age}" ]
  exit
fi

while :; do
  if /usr/local/bin/run-runtrace-backup.sh; then
    sleep "${interval_seconds}"
  else
    echo "Runtrace PostgreSQL backup failed; retrying in ${retry_seconds} seconds." >&2
    sleep "${retry_seconds}"
  fi
done
