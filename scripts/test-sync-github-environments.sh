#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
helper=${repo_root}/scripts/sync-github-environments.sh
inventory=${repo_root}/deploy/credential-inventory.json
test_root=$(mktemp -d "${TMPDIR:-/tmp}/postgres-credential-sync-test.XXXXXXXX")
fake_bin=${test_root}/bin
audit_log=${test_root}/audit.log
provider_state=${test_root}/provider
mkdir -m 0700 "${fake_bin}" "${provider_state}"

cleanup() {
  find "${test_root}" -depth -mindepth 1 -delete
  rmdir -- "${test_root}"
}
trap cleanup EXIT

cat >"${fake_bin}/pass-cli" <<'FAKE_PASS'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'pass-cli' >>"${FAKE_AUDIT_LOG}"
printf ' %q' "$@" >>"${FAKE_AUDIT_LOG}"
printf '\n' >>"${FAKE_AUDIT_LOG}"

if [[ "${1:-}" == test ]]; then
  exit 0
fi
if [[ "${1:-} ${2:-}" == 'item list' ]]; then
  jq -c --arg missing "${FAKE_MISSING_ITEM:-}" --arg duplicate "${FAKE_DUPLICATE_ITEM:-}" '
    ([.entries[].item] | unique | map(select(. != $missing) | {title:.})) as $items |
    {items: ($items + (if $duplicate == "" then [] else [{title:$duplicate}] end))}
  ' "${FAKE_INVENTORY}"
  exit 0
fi
if [[ "${1:-} ${2:-}" == 'item view' ]]; then
  field=
  while (( $# > 0 )); do
    if [[ "$1" == --field ]]; then
      field=$2
      break
    fi
    shift
  done
  [[ -n "${field}" && "${field}" != "${FAKE_MISSING_FIELD:-}" ]] || exit 1
  count_file=${FAKE_PROVIDER_STATE}/field-${field}.count
  count=0
  [[ ! -f "${count_file}" ]] || read -r count <"${count_file}"
  ((count += 1))
  printf '%s\n' "${count}" >"${count_file}"
  if [[ "${field}" == "${FAKE_DRIFT_FIELD:-}" && "${count}" -ge "${FAKE_DRIFT_ON_CALL:-2}" ]]; then
    printf 'ROTATED_%s' "${field}"
  elif [[ "${field}" == DEPLOY_SSH_PRIVATE_KEY || "${field}" == private_key ]]; then
    printf '%s' 'HIGHLY_SECRET_PRIVATE_KEY'
  else
    printf 'HIGHLY_SECRET_%s' "${field}"
  fi
  exit 0
fi
exit 97
FAKE_PASS

cat >"${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'gh' >>"${FAKE_AUDIT_LOG}"
printf ' %q' "$@" >>"${FAKE_AUDIT_LOG}"
printf '\n' >>"${FAKE_AUDIT_LOG}"
raw_arguments=$*
if env | grep -Eq 'HIGHLY_SECRET_|ROTATED_'; then
  echo 'credential leaked through the process environment' >&2
  exit 95
fi

if [[ "${1:-} ${2:-}" == 'auth status' ]]; then
  exit 0
fi

api_count() {
  local label=$1
  local file=${FAKE_PROVIDER_STATE}/api-${label}.count
  local count=0
  [[ ! -f "${file}" ]] || read -r count <"${file}"
  ((count += 1))
  printf '%s\n' "${count}" >"${file}"
  printf '%s' "${count}"
}

if [[ "${1:-}" == api ]]; then
  path=${*: -1}
  if [[ "${path}" == repos/Makepad-fr/postgres ]]; then
    count=$(api_count repository)
    repository_id=1200300784
    if [[ "${FAKE_REPOSITORY_INVALID:-0}" == 1 || "${FAKE_REPOSITORY_DRIFT_ON_CALL:-0}" == "${count}" ]]; then
      ((repository_id += 1))
    fi
    printf '{"id":%s,"full_name":"Makepad-fr/postgres","private":false,"visibility":"public","allow_forking":true,"default_branch":"main","archived":false,"disabled":false}\n' "${repository_id}"
    exit 0
  fi
  if [[ "${path}" == repos/Makepad-fr/postgres/branches/main/protection ]]; then
    strict=true
    [[ "${FAKE_MAIN_POLICY_INVALID:-0}" != 1 ]] || strict=false
    printf '{"required_status_checks":{"strict":%s,"checks":[{"context":"policy-and-integration","app_id":15368}]},"enforce_admins":{"enabled":true},"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"required_approving_review_count":1,"require_last_push_approval":true},"required_signatures":{"enabled":true},"required_linear_history":{"enabled":true},"required_conversation_resolution":{"enabled":true},"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false},"block_creations":{"enabled":false},"lock_branch":{"enabled":false},"allow_fork_syncing":{"enabled":false}}\n' "${strict}"
    exit 0
  fi
  if [[ "${path}" == repos/Makepad-fr/postgres/actions/permissions/workflow ]]; then
    if [[ "${FAKE_ACTIONS_POLICY_INVALID:-0}" == 1 ]]; then
      printf '%s\n' '{"default_workflow_permissions":"write","can_approve_pull_request_reviews":true}'
    else
      printf '%s\n' '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
    fi
    exit 0
  fi
  if [[ "${path}" == */deployment-branch-policies* ]]; then
    environment_path=${path%/deployment-branch-policies*}
    environment=${environment_path##*/}
    policy_id=$(jq -er --arg environment "${environment}" '.repositoryPolicy.environments[$environment].branchPolicyId' "${FAKE_INVENTORY}")
    if [[ "${FAKE_BRANCH_POLICY_INVALID:-0}" == 1 ]]; then
      ((policy_id += 1))
    fi
    printf '{"total_count":1,"branch_policies":[{"id":%s,"name":"main","type":"branch"}]}\n' "${policy_id}"
    exit 0
  fi
  environment=${path##*/}
  environment_id=$(jq -er --arg environment "${environment}" '.repositoryPolicy.environments[$environment].id' "${FAKE_INVENTORY}")
  reviewer_id=$(jq -r --arg environment "${environment}" '.repositoryPolicy.environments[$environment].reviewerId // empty' "${FAKE_INVENTORY}")
  reviewer_login=$(jq -r --arg environment "${environment}" '.repositoryPolicy.environments[$environment].reviewerLogin // empty' "${FAKE_INVENTORY}")
  count=$(api_count environment-${environment})
  if [[ "${FAKE_ENVIRONMENT_ID_DRIFT_ON_CALL:-0}" == "${count}" ]]; then
    ((environment_id += 1))
  fi
  if [[ "${FAKE_ENVIRONMENT_POLICY_INVALID:-0}" == reviewer ]]; then
    reviewer_id=77
  elif [[ "${FAKE_ENVIRONMENT_POLICY_INVALID:-0}" == bypass ]]; then
    can_bypass=false
  else
    can_bypass=true
  fi
  if [[ -n "${reviewer_id}" ]]; then
    rules='[{"id":1,"type":"required_reviewers","prevent_self_review":true,"reviewers":[{"type":"User","reviewer":{"type":"User","id":'"${reviewer_id}"',"login":"'"${reviewer_login}"'"}}]},{"id":2,"type":"branch_policy"}]'
  else
    rules='[{"id":2,"type":"branch_policy"}]'
  fi
  printf '{"id":%s,"name":"%s","can_admins_bypass":%s,"protection_rules":%s,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}\n' \
    "${environment_id}" "${environment}" "${can_bypass}" "${rules}"
  exit 0
fi

kind=${1:-}
operation=${2:-}
[[ "${kind}" == secret || "${kind}" == variable ]] || exit 96
shift 2
destination=
if [[ "${operation}" == set || "${operation}" == get ]]; then
  destination=${1:-}
  shift
fi
environment=
while (( $# > 0 )); do
  case "$1" in
    --env) environment=$2; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "${environment}" ]]; then
  if [[ "${operation}" == list && -n "${FAKE_REPOSITORY_DESTINATION:-}" && "${FAKE_REPOSITORY_KIND:-secret}" == "${kind}" ]]; then
    printf '%s\n' "${FAKE_REPOSITORY_DESTINATION}"
  fi
  exit 0
fi

marker_for() {
  printf '%s/%s-%s-%s' "${FAKE_PROVIDER_STATE}" "${environment}" "${kind}" "$1"
}

names() {
  while IFS= read -r name; do
    marker=$(marker_for "${name}")
    if [[ "${name}" == "${FAKE_MISSING_DESTINATION:-}" && ! -f "${marker}" ]]; then
      continue
    fi
    printf '%s\n' "${name}"
  done < <(jq -r --arg environment "${environment}" --arg kind "${kind}" '
    (.entries[] | select(.environment == $environment and .kind == $kind) | .destination),
    (.preservedDestinations[$environment][$kind][]?)
  ' "${FAKE_INVENTORY}")
  if [[ -n "${FAKE_UNEXPECTED_DESTINATION:-}" &&
    "${FAKE_UNEXPECTED_ENVIRONMENT:-staging-brio-identity-db}" == "${environment}" &&
    "${FAKE_UNEXPECTED_KIND:-secret}" == "${kind}" ]]; then
    printf '%s\n' "${FAKE_UNEXPECTED_DESTINATION}"
  fi
}

if [[ "${operation}" == list ]]; then
  if printf '%s\n' "${raw_arguments}" | grep -Fq -- '--jq'; then
    names
  elif [[ "${kind}" == secret ]]; then
    names | jq -Rn '[inputs | {name:.,updatedAt:"2026-09-05T00:00:00Z"}]'
  else
    names | jq -Rn '[inputs | {name:.,value:"not-disclosed"}]'
  fi
  exit 0
fi

if [[ "${operation}" == get && "${kind}" == variable ]]; then
  field=$(jq -er --arg environment "${environment}" --arg destination "${destination}" '
    .entries[] | select(.environment == $environment and .kind == "variable" and .destination == $destination) | .field
  ' "${FAKE_INVENTORY}")
  if [[ "${destination}" == "${FAKE_STALE_VARIABLE:-}" ]]; then
    printf 'STALE_%s' "${field}"
  else
    printf 'HIGHLY_SECRET_%s' "${field}"
  fi
  exit 0
fi

[[ "${operation}" == set && -n "${destination}" ]]
bytes=$(wc -c | tr -d '[:space:]')
[[ "${bytes}" =~ ^[1-9][0-9]*$ ]]
printf 'gh-set environment=%s kind=%s name=%s bytes=%s\n' "${environment}" "${kind}" "${destination}" "${bytes}" >>"${FAKE_AUDIT_LOG}"
touch "$(marker_for "${destination}")"
FAKE_GH

chmod 0755 "${fake_bin}/pass-cli" "${fake_bin}/gh"

inventory_digest=$(python3 - "${inventory}" <<'PY'
import hashlib
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest())
PY
)
expected_inventory_digest=912ae075075aa0843909af003619081b5d183e4e20c72e8e260dcd067cd665bd
[[ "${inventory_digest}" == "${expected_inventory_digest}" ]] || {
  echo "credential inventory changed without review: ${inventory_digest}" >&2
  exit 1
}

run_helper() {
  local expected_exit=$1
  shift
  find "${provider_state}" -mindepth 1 -maxdepth 1 -delete
  : >"${audit_log}"
  set +e
  output=$(PATH="${fake_bin}:${PATH}" FAKE_INVENTORY="${inventory}" FAKE_AUDIT_LOG="${audit_log}" \
    FAKE_PROVIDER_STATE="${provider_state}" "$@" 2>&1)
  helper_exit=$?
  set -e
  if (( helper_exit != expected_exit )); then
    printf 'unexpected exit %d, wanted %d:\n%s\n' "${helper_exit}" "${expected_exit}" "${output}" >&2
    exit 1
  fi
  if grep -Eq 'HIGHLY_SECRET_|ROTATED_' <<<"${output}"; then
    echo 'credential value leaked to helper output' >&2
    exit 1
  fi
}

run_helper 0 "${helper}" --check
grep -Fq 'SUMMARY required_source_issues=0 required_destination_missing=0' <<<"${output}"
grep -Fq 'name=DEPLOY_FASHION_DB_NAME status=preserved-existing' <<<"${output}"
if grep -Fq 'pass-cli item view' "${audit_log}"; then
  echo 'check mode read Proton field values' >&2
  exit 1
fi

run_helper 1 "${helper}" --check --sync
grep -Fq 'select exactly one mode' <<<"${output}"
run_helper 1 "${helper}" --sync
grep -Fq -- '--sync requires one explicit --environment' <<<"${output}"
run_helper 1 "${helper}" --sync --environment staging-brio-identity-db
grep -Fq -- '--sync requires the exact repository and environment confirmation' <<<"${output}"
run_helper 1 "${helper}" --check --confirm Makepad-fr/postgres:staging-brio-identity-db
grep -Fq -- '--confirm is accepted only with --sync' <<<"${output}"

run_helper 1 env FAKE_MISSING_ITEM='Brio Staging - PostgreSQL' "${helper}" --check --environment staging-brio-identity-db
grep -Fq 'status=missing' <<<"${output}"
run_helper 1 env FAKE_MISSING_DESTINATION=KEYCLOAK_BRIO_STAGING_DB_PASSWORD \
  "${helper}" --check --environment staging-brio-identity-db
grep -Fq 'name=KEYCLOAK_BRIO_STAGING_DB_PASSWORD requirement=required status=missing' <<<"${output}"
run_helper 2 env FAKE_UNEXPECTED_DESTINATION=LEGACY_POSTGRES_SECRET \
  "${helper}" --check --environment staging-brio-identity-db
grep -Fq 'status=legacy-or-unmanaged' <<<"${output}"
run_helper 2 env FAKE_REPOSITORY_DESTINATION=LEGACY_RUNNER_SECRET \
  "${helper}" --check --environment staging-brio-identity-db
grep -Fq 'scope=repository kind=secret' <<<"${output}"

run_helper 1 env FAKE_REPOSITORY_INVALID=1 "${helper}" --check --environment canary
grep -Fq 'policy=identity-or-visibility-invalid' <<<"${output}"
run_helper 1 env FAKE_MAIN_POLICY_INVALID=1 "${helper}" --check --environment canary
grep -Fq 'policy=main-protection-invalid' <<<"${output}"
run_helper 1 env FAKE_ACTIONS_POLICY_INVALID=1 "${helper}" --check --environment canary
grep -Fq 'policy=actions-token-policy-invalid' <<<"${output}"
run_helper 1 env FAKE_ENVIRONMENT_POLICY_INVALID=reviewer \
  "${helper}" --check --environment staging-brio-identity-db
grep -Fq 'protection=invalid' <<<"${output}"
run_helper 1 env FAKE_BRANCH_POLICY_INVALID=1 "${helper}" --check --environment canary
grep -Fq 'protection=invalid-branch-policy' <<<"${output}"

run_helper 1 env FAKE_MISSING_FIELD=KEYCLOAK_BRIO_STAGING_DB_PASSWORD "${helper}" --sync \
  --environment staging-brio-identity-db --confirm Makepad-fr/postgres:staging-brio-identity-db
grep -Fq 'required Proton field is missing or unreadable' <<<"${output}"
if grep -Fq 'gh-set ' "${audit_log}"; then
  echo 'sync wrote before source preflight completed' >&2
  exit 1
fi

run_helper 1 env FAKE_DRIFT_FIELD=KEYCLOAK_BRIO_STAGING_DB_PASSWORD FAKE_DRIFT_ON_CALL=2 \
  "${helper}" --sync --environment staging-brio-identity-db \
  --confirm Makepad-fr/postgres:staging-brio-identity-db
grep -Fq 'Proton source changed during preflight' <<<"${output}"
if grep -Fq 'gh-set ' "${audit_log}"; then
  echo 'sync wrote after source drift' >&2
  exit 1
fi

run_helper 1 env FAKE_ENVIRONMENT_ID_DRIFT_ON_CALL=2 "${helper}" --sync \
  --environment staging-brio-identity-db --confirm Makepad-fr/postgres:staging-brio-identity-db
grep -Fq 'protection=invalid' <<<"${output}"
if grep -Fq 'gh-set ' "${audit_log}"; then
  echo 'sync wrote after environment identity drift' >&2
  exit 1
fi

run_helper 0 env FAKE_MISSING_DESTINATION=KEYCLOAK_BRIO_STAGING_DB_PASSWORD "${helper}" --sync \
  --environment staging-brio-identity-db --confirm Makepad-fr/postgres:staging-brio-identity-db
grep -Fq 'SYNC_COMPLETE repository=Makepad-fr/postgres vault=Makepad environment=staging-brio-identity-db' <<<"${output}"
expected_writes=$(jq '[.entries[] | select(.environment == "staging-brio-identity-db")] | length' "${inventory}")
actual_writes=$(grep -Fc 'gh-set ' "${audit_log}")
[[ "${actual_writes}" == "${expected_writes}" ]]

run_helper 1 env FAKE_STALE_VARIABLE=BRIO_IDENTITY_DB_HOSTNAME "${helper}" --sync \
  --environment staging-brio-identity-db --confirm Makepad-fr/postgres:staging-brio-identity-db
grep -Fq 'GitHub variable readback differs from Proton' <<<"${output}"
if grep -Fq 'SYNC_COMPLETE' <<<"${output}"; then
  echo 'failed variable readback claimed completion' >&2
  exit 1
fi

candidate_root=${test_root}/candidate
mkdir -m 0700 "${candidate_root}"
mkdir -m 0700 "${candidate_root}/deploy" "${candidate_root}/scripts"
cp "${inventory}" "${candidate_root}/deploy/credential-inventory.json"
cp "${helper}" "${candidate_root}/scripts/sync-github-environments.sh"
chmod 0755 "${candidate_root}/scripts/sync-github-environments.sh"
jq '.operatorEntries = [{"boundary":"runner"}]' "${inventory}" >"${candidate_root}/deploy/credential-inventory.json"
run_helper 1 "${candidate_root}/scripts/sync-github-environments.sh" --check --environment canary
grep -Fq 'credential inventory changed without review' <<<"${output}"
jq '(.repositoryPolicy.repositoryId) += 1' "${inventory}" >"${candidate_root}/deploy/credential-inventory.json"
run_helper 1 "${candidate_root}/scripts/sync-github-environments.sh" --check --environment canary
grep -Fq 'credential inventory changed without review' <<<"${output}"
jq '(.entries[0].destination) = "ADVERSARIAL_SECRET"' "${inventory}" >"${candidate_root}/deploy/credential-inventory.json"
run_helper 1 "${candidate_root}/scripts/sync-github-environments.sh" --check --environment canary
grep -Fq 'credential inventory changed without review' <<<"${output}"

if rg -n 'JIT|just-in-time|ephemeral runner|runner group|GitHub App|OAuth App|POSTGRES_PR_CHECK|POSTGRES_CI_LAUNCHER' \
  "${inventory}" "${helper}"; then
  echo 'credential sync regained runner or App authority' >&2
  exit 1
fi

echo 'PostgreSQL Proton-to-GitHub credential sync tests passed.'
