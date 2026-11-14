#!/usr/bin/env bash
# shellcheck disable=SC2154 # contract variables are assigned by the sourced library
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=/dev/null
source "$repo_root/scripts/lib/catwlk-backup-contract.sh"
[[ "${catwlk_databases[*]}" == 'catwlk_production catwlk_canary' ]]

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
cat > "$test_dir/docker" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == inspect && "${2:-}" == postgres-postgres-1 && "${3:-}" == --format ]] || exit 1
printf '%s\n' "$MOCK_INSPECTION"
SH
cat > "$test_dir/restic" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$MOCK_RESTIC_ARGS"
SH
chmod +x "$test_dir/docker" "$test_dir/restic"
export PATH="$test_dir:$PATH"
export MOCK_RESTIC_ARGS="$test_dir/restic-args"

export MOCK_INSPECTION="postgres|postgres|${catwlk_postgres_image}|${catwlk_postgres_image_id}|running|healthy"
catwlk_assert_source "$catwlk_postgres_image"
if catwlk_assert_source 'postgres:16-alpine' >/dev/null 2>&1; then exit 1; fi
for drift in \
  'other|postgres' \
  'postgres|other' \
  'postgres|postgres|postgres:16-alpine|wrong' \
  'postgres|postgres|postgres:16-alpine|wrong|exited|unhealthy'; do
  MOCK_INSPECTION=$drift
  if catwlk_assert_source "$catwlk_postgres_image" >/dev/null 2>&1; then exit 1; fi
done

catwlk_forget_scoped 30 12
mapfile -d '' -t observed < "$MOCK_RESTIC_ARGS"
expected=(forget --tag catwlk-postgres-nightly --group-by 'host,tags' --keep-daily 30 --keep-monthly 12 --prune)
[[ "${#observed[@]}" == "${#expected[@]}" ]]
for index in "${!expected[@]}"; do [[ "${observed[$index]}" == "${expected[$index]}" ]]; done
echo 'Catwlk source identity and scoped retention contract passed.'
