#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT="${repo_root}" python3 - <<'PY'
import os
from pathlib import Path

root=Path(os.environ["REPO_ROOT"])
workflow=(root/".github/workflows/verify-keycloak-cohort-restores.yml").read_text()
dispatch=(root/"scripts/keycloak-cohort-capture-dispatch.sh").read_text()
installer=(root/"scripts/install-keycloak-cohort-capture-host.sh").read_text()
restore=(root/"scripts/restore-keycloak-cohort-backups.sh").read_text()
cleaner=(root/"scripts/clean-keycloak-cohort-resources.sh").read_text()
timer=(root/"host/systemd/makepad-keycloak-cohort-cleaner.timer").read_text()

def require(condition, message):
    if not condition: raise SystemExit(message)

require("scp " not in workflow and "remote_script=" not in workflow, "cohort workflow must not copy or execute checked-out code on the database host")
probe=workflow.index('"probe ${helper_digest} ${cleaner_digest}"')
capture=workflow.index('"capture ${GITHUB_RUN_ID}')
require(probe < capture, "remote forced-command digest and TTL probe must precede capture")
for marker in ("SSH_ORIGINAL_COMMAND", "sha256sum", "systemctl is-enabled", "systemctl is-active", "--property=Result", "--property=ExecMainStatus", "probe)", "capture)", "fetch)", "cleanup)"):
    require(marker in dispatch, f"forced-command dispatcher is missing {marker}")
require('sha256sum "${cleaner}"' in dispatch and "cleaner_digest" in workflow, "forced commands must bind the exact installed cleaner digest")
require('restrict,command="/usr/local/libexec/makepad/keycloak-cohort-capture-dispatch"' in installer, "installer must bind the key to the forced command")
require("sshd -t" in installer and "DisableForwarding yes" in installer, "installer must validate and restrict sshd")
for marker in ("makepad.cleanup.contract", "makepad.cleanup.expires-epoch", "docker container ls -aq", "docker network ls -q"):
    require(marker in cleaner, f"cohort resource cleaner is missing {marker}")
require("Persistent=true" in timer and "OnUnitActiveSec=15min" in timer, "cohort cleanup timer must survive downtime and recur")
for category in ("realm", "authentication", "roles", "clients", "identity_providers", "components", "required_actions"):
    require(f"[{category}]" in restore, f"v2 fingerprint is missing {category}")
for table in ("realm_smtp_config", "authentication_execution", "role_attribute", "composite_role", "client_scope_role_mapping", "protocol_mapper_config", "identity_provider_config", "component_config", "required_action_provider"):
    require(table in restore, f"v2 fingerprint is missing table {table}")
require("to_regclass" in restore and "to_jsonb(value)::text" in restore, "fingerprint must fail closed on schema drift and serialize deterministically")
require("POSTGRES_PASSWORD=${" not in restore and "KC_DB_PASSWORD=${" not in restore, "test secrets must not enter Docker Config.Env")
require("POSTGRES_PASSWORD_FILE=/run/secrets/postgres-password" in restore and 'export KC_DB_PASSWORD="$(cat /run/secrets/postgres-password)"' in restore, "runtime passwords must originate in mounted files")
require("catwlk-custom-provider" in restore and "catwlk-keycloak-email-router.jar" in restore, "Catwlk restore must validate the checked-out custom runtime")
PY

test_image=$(awk -F= '$1 == "BRIO_BACKUP_IMAGE" { print $2 }' "${repo_root}/envs/canary/.env.db")
[[ "${test_image}" == *@sha256:* ]]
docker run --rm --network none --security-opt no-new-privileges:true \
  --volume "${repo_root}:/repo:ro" "${test_image}" \
  bash /repo/scripts/fixtures/keycloak-cohort-cleaner-fixture.sh
docker run --rm --network none --security-opt no-new-privileges:true \
  --volume "${repo_root}:/repo:ro" "${test_image}" \
  bash /repo/scripts/fixtures/keycloak-cohort-dispatch-fixture.sh

echo "Keycloak cohort capture, runtime, fingerprint, and cleanup hardening contracts passed."
