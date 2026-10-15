#!/bin/sh
set -eu

interval_seconds=${BETACREW_BACKUP_INTERVAL_SECONDS:-21600}
retry_seconds=${BETACREW_BACKUP_RETRY_SECONDS:-300}
backup_root=${BETACREW_BACKUP_ROOT:-/backups}

case "${interval_seconds}:${retry_seconds}" in
  *[!0-9:]*) echo "BetaCrew backup timing values must be positive integers." >&2; exit 1 ;;
esac
[ "${interval_seconds}" -ge 300 ] && [ "${retry_seconds}" -ge 30 ] || { echo "BetaCrew backup interval or retry delay is too short." >&2; exit 1; }

if [ "${1:-}" = healthcheck ]; then
  status_file=${backup_root}/last-success.json
  [ -s "${status_file}" ] || exit 1
  now=$(date +%s)
  if modified=$(stat -c %Y "${status_file}" 2>/dev/null); then :; else modified=$(stat -f %m "${status_file}"); fi
  [ $((now - modified)) -le $((interval_seconds * 2 + retry_seconds)) ]
  exit
fi

while :; do
  if /usr/local/bin/run-betacrew-backup.sh; then
    sleep "${interval_seconds}"
  else
    echo "BetaCrew PostgreSQL backup failed; retrying in ${retry_seconds} seconds." >&2
    sleep "${retry_seconds}"
  fi
done
