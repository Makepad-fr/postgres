#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work_dir=$(mktemp -d)
cleanup() {
  find "${work_dir}" -mindepth 1 -delete
  rmdir "${work_dir}"
}
trap cleanup EXIT

source_sha=$(printf 'a%.0s' {1..40})
workflow_sha=$(printf 'b%.0s' {1..40})
run_file="${work_dir}/run.json"
jobs_file="${work_dir}/jobs.json"
python3 - "${run_file}" "${jobs_file}" "${source_sha}" "${workflow_sha}" <<'PY'
import json
import pathlib
import sys

run = {
    "id": 101,
    "run_attempt": 2,
    "event": "pull_request_target",
    "head_sha": sys.argv[4],
    "head_branch": "main",
    "name": "CI",
    "path": ".github/workflows/ci.yml",
    "status": "completed",
    "conclusion": "success",
    "repository": {"id": 77, "full_name": "Makepad-fr/postgres"},
    "pull_requests": [{
        "number": 9,
        "head": {"sha": sys.argv[3], "repo": {"id": 77}},
        "base": {"ref": "main", "sha": sys.argv[4], "repo": {"id": 77}},
    }],
}
job = {
    "id": 202,
    "run_id": 101,
    "head_sha": sys.argv[4],
    "workflow_name": "CI",
    "runner_id": 303,
    "runner_name": "postgres-ci-jit-j202-1111111111111111",
    "runner_group_id": 404,
    "runner_group_name": "Postgres PR Ephemeral",
    "name": "policy-and-integration",
    "status": "completed",
    "conclusion": "success",
    "labels": ["self-hosted", "Linux", "X64", "makepad-postgres-pr-ephemeral"],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(run))
pathlib.Path(sys.argv[2]).write_text(json.dumps({"total_count": 1, "jobs": [job]}))
PY

result=$(python3 "${script_dir}/verify-postgres-ci-jit-result.py" \
  "${run_file}" "${jobs_file}" 101 2 202 pull_request_target \
  "${source_sha}" "${workflow_sha}" 303 postgres-ci-jit-j202-1111111111111111 404)
[[ "${result}" == success ]]

python3 - "${run_file}" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["pull_requests"][0]["base"]["sha"] = "c" * 40
path.write_text(json.dumps(value))
PY
if python3 "${script_dir}/verify-postgres-ci-jit-result.py" \
  "${run_file}" "${jobs_file}" 101 2 202 pull_request_target \
  "${source_sha}" "${workflow_sha}" 303 postgres-ci-jit-j202-1111111111111111 404 >/dev/null 2>&1; then
  echo "JIT result verifier accepted a PR association with the wrong base SHA." >&2
  exit 1
fi

echo "Postgres JIT authoritative-result tests passed."
