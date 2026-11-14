#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

# Scheduled Catwlk application backup on the existing standalone DB host.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
[[ $(id -u) == 0 && $(hostname -s) == db-server-1 ]] || exit 1
cd "$repo_root"
# shellcheck source=/dev/null
source "$repo_root/scripts/lib/catwlk-backup-contract.sh"

set -a
# shellcheck source=/dev/null
source "$repo_root/envs/production/.env.db"
# shellcheck source=/dev/null
source /etc/makepad/postgres/postgres.env
# shellcheck source=/dev/null
source /etc/makepad/backups/restic-postgres.env
set +a

backup_root=${MAKEPAD_POSTGRES_BACKUP_PATH:?Set the exact Catwlk backup directory}
[[ "$backup_root" == /var/backups/makepad/postgres && -d "$backup_root" && ! -L "$backup_root" ]] || exit 1
[[ "${MAKEPAD_CATWLK_PRODUCTION_DB:?}" == catwlk_production && "${MAKEPAD_CATWLK_CANARY_DB:?}" == catwlk_canary ]] || exit 1
[[ "${POSTGRES_USER:?}" == postgres ]] || exit 1
[[ -n "${POSTGRES_IMAGE:?}" ]] || exit 1
[[ "${RESTIC_REPOSITORY:?}" == sftp:* && -f "${RESTIC_PASSWORD_FILE:?}" && ! -L "$RESTIC_PASSWORD_FILE" ]] || exit 1
daily=${MAKEPAD_POSTGRES_RETENTION_DAILY:-30}
monthly=${MAKEPAD_POSTGRES_RETENTION_MONTHLY:-12}
[[ "$daily" =~ ^[1-9][0-9]*$ && "$monthly" =~ ^[1-9][0-9]*$ ]] || exit 1
((daily >= 30 && monthly >= 12)) || { echo 'Catwlk retention is below the reviewed minimum.' >&2; exit 1; }

catwlk_assert_source "$POSTGRES_IMAGE"
container=postgres-postgres-1

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
output_dir="$backup_root/$timestamp"
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || exit 1
install -d -m 0700 "$output_dir"
# shellcheck disable=SC2154 # assigned by the sourced contract
for database in "${catwlk_databases[@]}"; do
  file="$output_dir/$database.dump"
  docker exec "$container" sh -euc '
    export PGPASSWORD="$(cat /run/secrets/postgres_superuser_password)"
    exec pg_dump -h 127.0.0.1 -U postgres --format=custom --compress=6 \
      --no-owner --no-privileges --dbname "$1"
  ' sh "$database" > "$file"
  [[ -s "$file" && ! -L "$file" ]] || exit 1
  docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --mount "type=bind,src=${file},dst=/backup.dump,readonly" \
    "$POSTGRES_IMAGE" pg_restore --list /backup.dump > /dev/null
done
docker exec "$container" sh -euc '
  export PGPASSWORD="$(cat /run/secrets/postgres_superuser_password)"
  exec pg_dumpall -h 127.0.0.1 -U postgres --globals-only
' > "$output_dir/globals.sql"
[[ -s "$output_dir/globals.sql" && ! -L "$output_dir/globals.sql" ]] || exit 1
(cd "$output_dir" && sha256sum catwlk_production.dump catwlk_canary.dump globals.sql > SHA256SUMS)

# The tag limits retention to snapshots made by this scheduled job. The one-off
# Catwlk recovery point, older untagged Catwlk snapshots, and other services'
# snapshots remain outside the selection.
restic backup --tag catwlk-postgres-nightly "$output_dir"
catwlk_forget_scoped "$daily" "$monthly"
