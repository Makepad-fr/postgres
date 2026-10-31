#!/usr/bin/env bash
# The official image's temporary init server listens only on a Unix socket.
# Wait for TCP so callers cannot race its shutdown and the final server startup.
wait_test_postgres() {
  local container=$1
  local attempt
  for attempt in $(seq 1 60); do
    if docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo 'PostgreSQL fixture did not finish initialization' >&2
  return 1
}
