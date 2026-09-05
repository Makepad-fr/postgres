#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
test_image=$(grep '^BRIO_BACKUP_IMAGE=' "${repo_root}/envs/canary/.env.db" | cut -d= -f2-)
: "${test_image:?BRIO_BACKUP_IMAGE is required for isolated failure testing}"
[[ "${test_image}" == *@sha256:* ]] || { echo "Failure tests require a digest-pinned container image." >&2; exit 1; }

docker run --rm \
  --security-opt no-new-privileges:true \
  --volume "${repo_root}:/repo:ro" \
  "${test_image}" bash /repo/scripts/fixtures/brio-deployment-failure-fixture.sh
