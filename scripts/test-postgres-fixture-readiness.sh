#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/scripts/lib/wait-test-postgres.sh"
fixture=$(mktemp -d)
container="postgres-readiness-test-$$"
cleanup() { if [[ $? != 0 ]]; then docker logs "$container" >&2 || true; fi; docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$fixture"; }
trap cleanup EXIT
cat > "$fixture/hold-init.sh" <<'SH'
#!/usr/bin/env bash
touch /tmp/initializing
while [[ ! -f /tmp/release-init ]]; do sleep 0.1; done
SH
chmod 644 "$fixture/hold-init.sh"
docker create --name "$container" --network none \
  -e POSTGRES_PASSWORD=disposable-fixture-password \
  postgres:18-alpine@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2 >/dev/null
docker cp "$fixture/hold-init.sh" "$container:/docker-entrypoint-initdb.d/hold-init.sh"
docker start "$container" >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$container" test -f /tmp/initializing 2>/dev/null; then break; fi
  [[ $(docker inspect -f '{{.State.Running}}' "$container") == true ]] || exit 1
  sleep 1
done
docker exec "$container" test -f /tmp/initializing
# This is the false positive that the old readiness probe accepted.
docker exec "$container" pg_isready -U postgres -d postgres >/dev/null
wait_test_postgres "$container" &
waiter=$!
sleep 2
kill -0 "$waiter" || { echo 'Readiness accepted temporary init server' >&2; exit 1; }
docker exec "$container" touch /tmp/release-init
wait "$waiter"
docker exec -e PGPASSWORD=disposable-fixture-password "$container" \
  psql -h 127.0.0.1 -U postgres -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null
echo 'temporary-server rejection and final TCP readiness passed'
