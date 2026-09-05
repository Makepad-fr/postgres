#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
observer=${repo_root}/scripts/brio-runtime-observe.sh
installer=${repo_root}/scripts/install-brio-runtime-observer.sh
control_helper=${repo_root}/scripts/brio-postgres-control-receipt.py

for path in "${observer}" "${installer}" "${control_helper}"; do
  [[ -f "${path}" && ! -L "${path}" ]] || { echo "missing runtime observer artifact: ${path}" >&2; exit 1; }
done
bash -n "${observer}"
bash -n "${installer}"
python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), filename=sys.argv[1])' "${control_helper}"
PYTHONDONTWRITEBYTECODE=1 python3 "${repo_root}/scripts/test-brio-postgres-control-receipt.py"

for marker in \
  'export PATH=/usr/bin:/bin' \
  'SSH_ORIGINAL_COMMAND:-' \
  'shared-runtime-observe' \
  'timeout --signal=KILL 20s docker' \
  'readonly expected_container=postgres-postgres-1' \
  'postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777' \
  'com.docker.compose.project' \
  'com.docker.compose.service' \
  'com.docker.compose.config-hash' \
  'configDigest' \
  'runtimeImageID' \
  'postgres --version' \
  'readonly expected_version=16.14' \
  'brio-postgres-control-receipt' \
  'controlReceipts' \
  'makepad.brio.runtime-controls.v1' \
  'makepad.brio.runtime-host-observation.v1'; do
  grep -Fq -- "${marker}" "${observer}" || { echo "observer is missing ${marker}" >&2; exit 1; }
done

for forbidden in 'Config.Env' 'Mounts' 'docker logs'; do
  ! grep -Fq -- "${forbidden}" "${observer}" || { echo "observer contains forbidden inspection: ${forbidden}" >&2; exit 1; }
done

for marker in \
  'readonly observer_user=brio-runtime-observer' \
  'restrict,command="/usr/bin/sudo -n %s"' \
  'env_keep += "SSH_ORIGINAL_COMMAND"' \
  'NOPASSWD:' \
  'visudo -cf' \
  'passwd --lock' \
  'readonly control_command=/usr/local/libexec/makepad/brio-postgres-control-receipt'; do
  grep -Fq -- "${marker}" "${installer}" || { echo "installer is missing ${marker}" >&2; exit 1; }
done

for marker in \
  'BEGIN TRANSACTION READ ONLY' \
  'pg_hba_file_rules' \
  'ssl.create_default_context' \
  'server_hostname=server_name' \
  'EXPECTED_APPLICATION_ALIAS = "makepad-postgres-brio-staging"' \
  'applicationAliasVerified' \
  'identityEndpointVerified' \
  'sslmode=disable' \
  'makepad.brio.runtime-controls.v1'; do
  grep -Fq -- "${marker}" "${control_helper}" || { echo "control helper is missing ${marker}" >&2; exit 1; }
done
for forbidden in 'PGPASSWORD' 'POSTGRES_PASSWORD' 'Config.Env' 'Mounts' 'docker logs'; do
  ! grep -Fq -- "${forbidden}" "${control_helper}" || { echo "control helper contains forbidden credential/runtime access: ${forbidden}" >&2; exit 1; }
done

echo 'Brio PostgreSQL runtime observer contract passed.'
