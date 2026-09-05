#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
validator="${repo_root}/scripts/verify-keycloak-cohort-evidence.py"
work_dir=$(mktemp -d)
cleanup() {
  find "${work_dir}" -mindepth 1 -delete
  rmdir "${work_dir}"
}
trap cleanup EXIT

head_sha=$(printf 'a%.0s' {1..40})
release_sha=$(printf 'b%.0s' {1..40})
canonical="${work_dir}/keycloak-cohort-restore-evidence.json"

python3 - "${canonical}" "${head_sha}" "${release_sha}" <<'PY'
import hashlib
import json
import pathlib
import sys

databases = {
    "catwlk": "keycloak_catwlk",
    "makepad": "keycloak_makepad",
    "runtrace": "keycloak_runtrace",
    "vestiaire": "keycloak_vestiaire",
    "vif": "keycloak_vif",
}
payload = {
    "schema": "makepad.keycloak-cohort-restore-evidence.v2",
    "postgres_repository": "Makepad-fr/postgres",
    "postgres_workflow": ".github/workflows/verify-keycloak-cohort-restores.yml",
    "postgres_run_id": 101,
    "postgres_run_attempt": 2,
    "postgres_head_sha": sys.argv[2],
    "postgres_ref": "refs/heads/main",
    "keycloak_release_sha": sys.argv[3],
    "keycloak_base_image": "dhi.io/keycloak:26-debian13@sha256:fab1484b1762fd1269e63a40f068ec73ea75b498eaaa5d02f62f022a5d00ff0f",
    "catwlk_runtime_image_id": "sha256:" + "c" * 64,
    "fingerprint_schema": "makepad.keycloak-config-fingerprint.v2",
    "keycloak_upstream_version": "26.7.3",
    "result": "restored-databases-compatible",
    "instances": [],
}
categories = ["authentication", "clients", "components", "identity_providers", "realm", "required_actions", "roles"]
for index, (slug, database) in enumerate(sorted(databases.items())):
    fingerprints = {category: format((index + 1) * 10 + offset, "064x") for offset, category in enumerate(categories)}
    combined = hashlib.sha256("".join(f"{category}={fingerprints[category]}\n" for category in categories).encode()).hexdigest()
    payload["instances"].append({
            "slug": slug,
            "database": database,
            "backup_sha256": format(index + 1, "064x"),
            "runtime": "catwlk-custom-provider" if slug == "catwlk" else "keycloak-base",
            "runtime_image": "sha256:" + "c" * 64 if slug == "catwlk" else "dhi.io/keycloak:26-debian13@sha256:fab1484b1762fd1269e63a40f068ec73ea75b498eaaa5d02f62f022a5d00ff0f",
            "configuration_fingerprint": combined,
            "configuration_fingerprints": fingerprints,
            "restore": "passed",
            "keycloak_startup": "passed",
            "configuration_regression": "passed",
    })
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY

python3 "${validator}" "${canonical}" --run-id 101 --run-attempt 2 \
  --head-sha "${head_sha}" --keycloak-release-sha "${release_sha}"

expect_failure() {
  local name=$1 expression=$2 candidate
  candidate="${work_dir}/${name}.json"
  python3 - "${canonical}" "${candidate}" "${expression}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
exec(sys.argv[3], {"payload": payload})
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
  if python3 "${validator}" "${candidate}" >/dev/null 2>&1; then
    echo "Cohort evidence validator accepted ${name}." >&2
    exit 1
  fi
}

expect_failure wrong-schema 'payload["schema"] = "makepad.keycloak-cohort-restore-evidence.v1"'
expect_failure extra-field 'payload["unexpected"] = True'
expect_failure extra-instance-field 'payload["instances"][0]["unexpected"] = True'
expect_failure missing-instance 'payload["instances"].pop()'
expect_failure duplicate-instance 'payload["instances"][-1] = payload["instances"][0]'
expect_failure unsorted-instance 'payload["instances"][0], payload["instances"][1] = payload["instances"][1], payload["instances"][0]'
expect_failure wrong-database 'payload["instances"][0]["database"] = "keycloak_vif"'
expect_failure bad-digest 'payload["instances"][0]["backup_sha256"] = "A" * 64'
expect_failure failed-restore 'payload["instances"][0]["restore"] = "failed"'
expect_failure wrong-image 'payload["keycloak_base_image"] = "dhi.io/keycloak:latest"'
expect_failure wrong-catwlk-runtime 'next(value for value in payload["instances"] if value["slug"] == "catwlk")["runtime"] = "keycloak-base"'
expect_failure missing-fingerprint-category 'payload["instances"][0]["configuration_fingerprints"].pop("roles")'
expect_failure tampered-fingerprint 'payload["instances"][0]["configuration_fingerprints"]["roles"] = "f" * 64'
expect_failure mutable-release 'payload["keycloak_release_sha"] = "main"'

noncanonical="${work_dir}/noncanonical.json"
python3 - "${canonical}" "${noncanonical}" <<'PY'
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload, indent=2))
PY
if python3 "${validator}" "${noncanonical}" >/dev/null 2>&1; then
  echo "Cohort evidence validator accepted non-canonical JSON." >&2
  exit 1
fi

symlink="${work_dir}/symlink.json"
ln -s "${canonical}" "${symlink}"
if python3 "${validator}" "${symlink}" >/dev/null 2>&1; then
  echo "Cohort evidence validator accepted a symlink." >&2
  exit 1
fi

oversized="${work_dir}/oversized.json"
dd if=/dev/zero of="${oversized}" bs=65537 count=1 status=none
if python3 "${validator}" "${oversized}" >/dev/null 2>&1; then
  echo "Cohort evidence validator accepted an oversized file." >&2
  exit 1
fi

echo "Keycloak cohort evidence contract tests passed."
