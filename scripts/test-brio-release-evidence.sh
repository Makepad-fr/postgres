#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
validator="${script_dir}/verify-brio-release-evidence.py"
fixture=$(mktemp -d /tmp/postgres-brio-release-evidence-XXXXXX)
cleanup() {
  [[ "${fixture}" =~ ^/tmp/postgres-brio-release-evidence-[A-Za-z0-9]+$ ]] || return 1
  find "${fixture}" -depth -delete
}
trap cleanup EXIT

pg_run=123
pg_attempt=2
pg_sha=1111111111111111111111111111111111111111
kc_run=456
kc_attempt=1
kc_sha=2222222222222222222222222222222222222222

python3 - "${fixture}" <<'PY'
import json
import pathlib
import stat
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
pg_sha = "1" * 40
kc_sha = "2" * 40

def dump(name, value):
    (root / name).write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")

def archive(name, entry, value, *, mode=None, extra=None):
    with zipfile.ZipFile(root / name, "w", compression=zipfile.ZIP_DEFLATED) as target:
        info = zipfile.ZipInfo(entry)
        if mode is not None:
            info.create_system = 3
            info.external_attr = mode << 16
        target.writestr(info, json.dumps(value, separators=(",", ":")))
        if extra:
            target.writestr(extra, "unexpected")

pg_evidence = {
    "schema": "makepad.brio-db-deployment-evidence.v1",
    "postgres_repository": "Makepad-fr/postgres",
    "postgres_workflow": ".github/workflows/deploy-brio-identity-db.yml",
    "postgres_run_id": 123,
    "postgres_run_attempt": 2,
    "postgres_head_sha": pg_sha,
    "postgres_ref": "refs/heads/main",
    "deployment": "brio-db-host-ready",
    "database": "keycloak_brio_staging",
    "role": "keycloak_brio_staging_app",
    "tls_host": "65.21.134.125",
    "keycloak_source_cidr": "88.99.209.165/32",
}
attestation = {
    "schema": "makepad.brio-db-path-attestation.v1",
    "postgres_repository": "Makepad-fr/postgres",
    "postgres_workflow": ".github/workflows/deploy-brio-identity-db.yml",
    "postgres_run_id": 123,
    "postgres_run_attempt": 2,
    "postgres_head_sha": pg_sha,
    "keycloak_repository": "Makepad-fr/keycloak",
    "keycloak_workflow": ".github/workflows/verify-brio-database.yml",
    "keycloak_verifier_run_id": 456,
    "keycloak_verifier_run_attempt": 1,
    "keycloak_release_sha": kc_sha,
    "probe": "brio-db-path-ok",
    "database": "keycloak_brio_staging",
    "role": "keycloak_brio_staging_app",
    "tls_host": "65.21.134.125",
    "keycloak_source_cidr": "88.99.209.165/32",
}
dump("pg-run.json", {
    "id": 123, "run_attempt": 2, "name": "Deploy Brio Identity Database",
    "path": ".github/workflows/deploy-brio-identity-db.yml", "event": "workflow_dispatch",
    "head_branch": "main", "head_sha": pg_sha, "status": "completed", "conclusion": "success",
    "repository": {"full_name": "Makepad-fr/postgres"},
})
dump("pg-workflow.json", {
    "name": "Deploy Brio Identity Database",
    "path": ".github/workflows/deploy-brio-identity-db.yml", "state": "active",
})
dump("pg-artifacts.json", {"total_count": 1, "artifacts": [{
    "id": 789, "name": "brio-db-deployment-evidence-123-2", "expired": False, "size_in_bytes": 1024,
}]})
archive("pg.zip", "brio-db-deployment-evidence.json", pg_evidence)
dump("kc-main.json", {"object": {"sha": kc_sha}})
kc_run_value = {
    "id": 456, "run_attempt": 1, "name": "Verify Brio Identity Database Path",
    "display_title": f"Verify Brio DB path for PostgreSQL run 123/2 at Keycloak {kc_sha}",
    "path": ".github/workflows/verify-brio-database.yml", "event": "workflow_dispatch",
    "head_branch": "main", "head_sha": kc_sha, "status": "completed", "conclusion": "success",
    "created_at": "2026-09-05T10:00:05Z", "repository": {"full_name": "Makepad-fr/keycloak"},
}
dump("kc-run.json", kc_run_value)
dump("kc-runs.json", {"total_count": 1, "workflow_runs": [kc_run_value]})
dump("kc-artifacts.json", {"total_count": 1, "artifacts": [{
    "id": 987, "name": "brio-db-path-attestation-456-1", "expired": False, "size_in_bytes": 1024,
}]})
archive("kc.zip", "brio-db-path-attestation.json", attestation)

bad = dict(pg_evidence); bad["schema"] = "wrong"; archive("wrong-schema.zip", "brio-db-deployment-evidence.json", bad)
bad = dict(pg_evidence); bad["extra"] = True; archive("extra-field.zip", "brio-db-deployment-evidence.json", bad)
archive("extra-entry.zip", "brio-db-deployment-evidence.json", pg_evidence, extra="extra")
archive("symlink-entry.zip", "brio-db-deployment-evidence.json", pg_evidence, mode=stat.S_IFLNK | 0o777)
with zipfile.ZipFile(root / "oversized-entry.zip", "w", compression=zipfile.ZIP_STORED) as target:
    target.writestr("brio-db-deployment-evidence.json", b"x" * 65537)
bad = dict(attestation); bad["postgres_run_id"] = 999; archive("wrong-binding.zip", "brio-db-path-attestation.json", bad)
PY

expect_failure() {
  local label=$1
  shift
  if "$@" >"${fixture}/${label}.out" 2>&1; then
    echo "Expected ${label} to fail closed." >&2
    exit 1
  fi
}

[[ $(python3 "${validator}" postgres-run "${fixture}/pg-run.json" "${fixture}/pg-workflow.json" "${fixture}/pg-artifacts.json" "${pg_run}" "${pg_attempt}") == "789 ${pg_sha}" ]]
python3 "${validator}" postgres-evidence "${fixture}/pg.zip" "${pg_run}" "${pg_attempt}" "${pg_sha}"
[[ $(python3 "${validator}" keycloak-main "${fixture}/kc-main.json") == "${kc_sha}" ]]
[[ $(python3 "${validator}" verifier-run-select "${fixture}/kc-runs.json" "${pg_run}" "${pg_attempt}" "${kc_sha}" 2026-09-05T10:00:00Z) == "${kc_run}" ]]
python3 "${validator}" verifier-run "${fixture}/kc-run.json" "${pg_run}" "${pg_attempt}" "${kc_sha}" "${kc_run}"
[[ $(python3 "${validator}" attestation-artifact "${fixture}/kc-artifacts.json" "${kc_run}" "${kc_attempt}") == 987 ]]
python3 "${validator}" attestation "${fixture}/kc.zip" "${pg_run}" "${pg_attempt}" "${pg_sha}" "${kc_run}" "${kc_attempt}" "${kc_sha}"

python3 - "${fixture}/pg-run.json" "${fixture}/in-progress.json" <<'PY'
import json, sys
value=json.load(open(sys.argv[1], encoding="utf-8")); value["status"]="in_progress"; value["conclusion"]=None
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
PY
expect_failure in-progress python3 "${validator}" postgres-run "${fixture}/in-progress.json" "${fixture}/pg-workflow.json" "${fixture}/pg-artifacts.json" "${pg_run}" "${pg_attempt}"

python3 - "${fixture}/pg-artifacts.json" "${fixture}/duplicate-artifacts.json" "${fixture}/oversized-artifact.json" "${fixture}/truncated-artifacts.json" <<'PY'
import copy, json, sys
value=json.load(open(sys.argv[1], encoding="utf-8"))
duplicate=copy.deepcopy(value); duplicate["artifacts"].append(copy.deepcopy(duplicate["artifacts"][0])); duplicate["total_count"]=2; json.dump(duplicate, open(sys.argv[2], "w", encoding="utf-8"))
oversized=copy.deepcopy(value); oversized["artifacts"][0]["size_in_bytes"]=131073; json.dump(oversized, open(sys.argv[3], "w", encoding="utf-8"))
truncated=copy.deepcopy(value); truncated["total_count"]=2; json.dump(truncated, open(sys.argv[4], "w", encoding="utf-8"))
PY
expect_failure duplicate-artifact python3 "${validator}" postgres-run "${fixture}/pg-run.json" "${fixture}/pg-workflow.json" "${fixture}/duplicate-artifacts.json" "${pg_run}" "${pg_attempt}"
expect_failure oversized-artifact python3 "${validator}" postgres-run "${fixture}/pg-run.json" "${fixture}/pg-workflow.json" "${fixture}/oversized-artifact.json" "${pg_run}" "${pg_attempt}"
expect_failure truncated-artifact-page python3 "${validator}" postgres-run "${fixture}/pg-run.json" "${fixture}/pg-workflow.json" "${fixture}/truncated-artifacts.json" "${pg_run}" "${pg_attempt}"
expect_failure wrong-schema python3 "${validator}" postgres-evidence "${fixture}/wrong-schema.zip" "${pg_run}" "${pg_attempt}" "${pg_sha}"
expect_failure extra-field python3 "${validator}" postgres-evidence "${fixture}/extra-field.zip" "${pg_run}" "${pg_attempt}" "${pg_sha}"
expect_failure extra-entry python3 "${validator}" postgres-evidence "${fixture}/extra-entry.zip" "${pg_run}" "${pg_attempt}" "${pg_sha}"
expect_failure symlink-entry python3 "${validator}" postgres-evidence "${fixture}/symlink-entry.zip" "${pg_run}" "${pg_attempt}" "${pg_sha}"
expect_failure oversized-entry python3 "${validator}" postgres-evidence "${fixture}/oversized-entry.zip" "${pg_run}" "${pg_attempt}" "${pg_sha}"
ln -s "${fixture}/pg.zip" "${fixture}/symlink-archive.zip"
expect_failure symlink-archive python3 "${validator}" postgres-evidence "${fixture}/symlink-archive.zip" "${pg_run}" "${pg_attempt}" "${pg_sha}"
expect_failure wrong-attestation-binding python3 "${validator}" attestation "${fixture}/wrong-binding.zip" "${pg_run}" "${pg_attempt}" "${pg_sha}" "${kc_run}" "${kc_attempt}" "${kc_sha}"

python3 - "${fixture}/kc-runs.json" "${fixture}/duplicate-runs.json" <<'PY'
import copy, json, sys
value=json.load(open(sys.argv[1], encoding="utf-8")); value["workflow_runs"].append(copy.deepcopy(value["workflow_runs"][0])); value["total_count"] = 2
json.dump(value, open(sys.argv[2], "w", encoding="utf-8"))
PY
expect_failure duplicate-verifier-run python3 "${validator}" verifier-run-select "${fixture}/duplicate-runs.json" "${pg_run}" "${pg_attempt}" "${kc_sha}" 2026-09-05T10:00:00Z

python3 - "${fixture}/kc-runs.json" "${fixture}/truncated-runs.json" "${fixture}/kc-artifacts.json" "${fixture}/truncated-kc-artifacts.json" <<'PY'
import json, sys
runs=json.load(open(sys.argv[1], encoding="utf-8")); runs["total_count"]=2; json.dump(runs, open(sys.argv[2], "w", encoding="utf-8"))
artifacts=json.load(open(sys.argv[3], encoding="utf-8")); artifacts["total_count"]=2; json.dump(artifacts, open(sys.argv[4], "w", encoding="utf-8"))
PY
expect_failure truncated-verifier-page python3 "${validator}" verifier-run-select "${fixture}/truncated-runs.json" "${pg_run}" "${pg_attempt}" "${kc_sha}" 2026-09-05T10:00:00Z
expect_failure truncated-keycloak-artifact-page python3 "${validator}" attestation-artifact "${fixture}/truncated-kc-artifacts.json" "${kc_run}" "${kc_attempt}"

echo "Brio two-phase release evidence validation tests passed."
