#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${PGSERVICEFILE:?root-owned libpq service file required}"
: "${VISITAKI_BACKUP_ROOT:?encrypted backup destination required}"
[[ -f "$PGSERVICEFILE" && ! -L "$PGSERVICEFILE" ]]
[[ -d "$VISITAKI_BACKUP_ROOT" && ! -L "$VISITAKI_BACKUP_ROOT" ]]
stamp=$(date -u +%Y%m%dT%H%M%SZ)
destination="$VISITAKI_BACKUP_ROOT/$stamp"
mkdir -m 700 "$destination"
for database in visitaki keycloak_visitaki; do
  service="${database}_backup"
  actual=$(psql -XAt "service=$service" -c 'SELECT current_database()')
  [[ "$actual" == "$database" ]] || { echo 'Backup service points to unexpected database' >&2; exit 1; }
  pg_dump --format=custom --no-password "service=$service" > "$destination/$database.dump.partial"
  pg_restore --list "$destination/$database.dump.partial" >/dev/null
  mv "$destination/$database.dump.partial" "$destination/$database.dump"
done
(cd "$destination" && sha256sum visitaki.dump keycloak_visitaki.dump > SHA256SUMS)
printf '{"timestamp":"%s","databases":["visitaki","keycloak_visitaki"]}\n' "$stamp" > "$destination/metadata.json"
echo "Visitaki backup completed: $stamp"
