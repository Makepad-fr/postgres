#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly repo_root
readonly helper=${repo_root}/scripts/sync-github-environments.sh
readonly inventory=${repo_root}/deploy/credential-inventory.json

test_root=$(mktemp -d "${TMPDIR:-/tmp}/postgres-credential-sync-test.XXXXXXXX")
[[ -d "${test_root}" && ! -L "${test_root}" ]]
readonly test_root
readonly fake_bin=${test_root}/bin
readonly audit_log=${test_root}/audit.log
install -d -m 0700 "${fake_bin}"

cleanup() {
  if [[ "${test_root}" == "${TMPDIR:-/tmp}/postgres-credential-sync-test."* && -d "${test_root}" && ! -L "${test_root}" ]]; then
    find "${test_root}" -depth -mindepth 1 -delete
    rmdir -- "${test_root}"
  fi
}
trap cleanup EXIT

cat >"${fake_bin}/pass-cli" <<'FAKE_PASS'
#!/usr/bin/env bash
set -euo pipefail
printf 'pass-cli' >>"${FAKE_AUDIT_LOG}"
printf ' %q' "$@" >>"${FAKE_AUDIT_LOG}"
printf '\n' >>"${FAKE_AUDIT_LOG}"

if [[ "${1:-} ${2:-}" == 'item list' ]]; then
  jq --arg missing "${FAKE_MISSING_ITEM:-}" '
    {items: ([.githubEntries[].item, .repositoryVariables[].item, .nonGitHubEntries[].item]
      | unique | map(select(. != $missing) | {title: .}))}
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
  [[ -n "${field}" ]]
  [[ "${field}" != "${FAKE_MISSING_FIELD:-}" ]] || exit 1
  if [[ "${field}" == "${FAKE_EMPTY_FIELD:-}" ]]; then
    exit 0
  fi
  if [[ "${field}" == "${FAKE_OVERSIZED_FIELD:-}" ]]; then
    printf '%050000d' 0
    exit 0
  fi
  printf 'HIGHLY_SECRET_%s' "${field}"
  exit 0
fi
if [[ "${1:-}" == test ]]; then
  exit 0
fi
exit 97
FAKE_PASS

cat >"${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

printf 'gh' >>"${FAKE_AUDIT_LOG}"
printf ' %q' "$@" >>"${FAKE_AUDIT_LOG}"
printf '\n' >>"${FAKE_AUDIT_LOG}"
if printf '%s\n' "$*" | grep -Fq 'HIGHLY_SECRET_'; then
  echo 'a synthetic credential reached gh argv' >&2
  exit 95
fi
if env | grep -Fq 'HIGHLY_SECRET_'; then
  echo 'a synthetic credential reached the exported environment' >&2
  exit 94
fi

if [[ "${1:-} ${2:-}" == 'auth status' ]]; then
  exit 0
fi
if [[ "${1:-}" == api ]]; then
  path=${*: -1}
  if [[ "${path}" == repos/Makepad-fr/postgres ]]; then
    if [[ "${FAKE_INVALID_REPOSITORY:-0}" == 1 ]]; then
      printf '%s\n' '{"full_name":"Makepad-fr/postgres","private":true,"visibility":"private","default_branch":"main","allow_forking":false,"archived":false,"disabled":false}'
    else
      printf '%s\n' '{"full_name":"Makepad-fr/postgres","private":false,"visibility":"public","default_branch":"main","allow_forking":true,"archived":false,"disabled":false}'
    fi
    exit 0
  fi
  if [[ "${path}" == */deployment-branch-policies\?per_page=100\&page=1 ]]; then
    case "${FAKE_INVALID_PROTECTION:-0}" in
      1) printf '%s\n' '{"total_count":2,"branch_policies":[{"name":"main","type":"branch"},{"name":"release/*","type":"branch"}]}' ;;
      tag) printf '%s\n' '{"total_count":1,"branch_policies":[{"name":"main","type":"tag"}]}' ;;
      *) printf '%s\n' '{"total_count":1,"branch_policies":[{"name":"main","type":"branch"}]}' ;;
    esac
    exit 0
  fi
  environment=${path##*/}
  if [[ "${FAKE_INVALID_PROTECTION:-0}" == mode ]]; then
    printf '{"name":"%s","deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}\n' "${environment}"
  else
    printf '{"name":"%s","deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}\n' "${environment}"
  fi
  exit 0
fi

kind=${1:-}
operation=${2:-}
if [[ "${kind}" != secret && "${kind}" != variable ]]; then
  exit 96
fi
shift 2
environment=
destination=
if [[ "${operation}" == set ]]; then
  destination=${1:-}
  shift
fi
while (( $# > 0 )); do
  case "$1" in
    --env)
      environment=$2
      shift 2
      ;;
    *) shift ;;
  esac
done

if [[ "${operation}" == list ]]; then
  if [[ -z "${environment}" ]]; then
    if [[ "${kind}" == variable ]]; then
      jq -r --arg missing "${FAKE_MISSING_REPOSITORY_VARIABLE:-}" '
        .repositoryVariables[] | select(.destination != $missing) | .destination
      ' "${FAKE_INVENTORY}"
    fi
    if [[ "${kind}" == "${FAKE_REPOSITORY_LEGACY_KIND:-}" && -n "${FAKE_REPOSITORY_LEGACY:-}" ]]; then
      printf '%s\n' "${FAKE_REPOSITORY_LEGACY}"
    fi
    exit 0
  fi
  jq -r --arg environment "${environment}" --arg kind "${kind}" --arg missing "${FAKE_MISSING_DESTINATION:-}" '
    .githubEntries[] |
    select(.environment == $environment and .kind == $kind and .destination != $missing) |
    .destination
  ' "${FAKE_INVENTORY}"
  if [[ -n "${FAKE_UNEXPECTED_DESTINATION:-}" && "${FAKE_UNEXPECTED_ENVIRONMENT:-canary}" == "${environment}" && "${FAKE_UNEXPECTED_KIND:-secret}" == "${kind}" ]]; then
    printf '%s\n' "${FAKE_UNEXPECTED_DESTINATION}"
  fi
  exit 0
fi

[[ "${operation}" == set && -n "${environment}" && -n "${destination}" ]]
bytes=$(wc -c | tr -d '[:space:]')
[[ "${bytes}" =~ ^[1-9][0-9]*$ ]]
printf 'gh-set environment=%s kind=%s name=%s bytes=%s\n' \
  "${environment}" "${kind}" "${destination}" "${bytes}" >>"${FAKE_AUDIT_LOG}"
FAKE_GH

chmod 0755 "${fake_bin}/pass-cli" "${fake_bin}/gh"

run_helper() {
  local expected_status=$1
  shift
  set +e
  output=$(PATH="${fake_bin}:${PATH}" FAKE_INVENTORY="${inventory}" FAKE_AUDIT_LOG="${audit_log}" "$@" 2>&1)
  status=$?
  set -e
  if (( status != expected_status )); then
    printf 'unexpected status %d (wanted %d):\n%s\n' "${status}" "${expected_status}" "${output}" >&2
    exit 1
  fi
}

assert_no_value_read_or_write() {
  if grep -Fq 'pass-cli item view' "${audit_log}" || grep -Fq 'gh-set ' "${audit_log}"; then
    echo 'provider field read or destination write occurred before a failing preflight' >&2
    exit 1
  fi
}

# The machine-readable inventory encodes the exact workflow-backed PKI split.
jq -e '
  ([.githubEntries[] | select(.item == "Brio Staging - PKI and Backup Keys" and (.destination | endswith("_PEM"))) | [.environment, .destination]] | sort) ==
  ([
    ["canary", "BRIO_BACKUP_RECIPIENT_CERT_PEM"],
    ["canary", "POSTGRES_CA_PEM"],
    ["canary", "POSTGRES_SERVER_CERT_PEM"],
    ["canary", "POSTGRES_SERVER_KEY_PEM"],
    ["staging-brio-identity-db", "BRIO_BACKUP_RECIPIENT_CERT_PEM"]
  ] | sort) and
  ([.repositoryVariables[].destination] | sort) == ([
    "POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256",
    "POSTGRES_CI_ATTESTATION_PUBLIC_KEY",
    "POSTGRES_CI_LAUNCHER_APP_SENDER_ID",
    "POSTGRES_PR_CHECK_APP_ID"
  ] | sort) and
  ([.githubEntries[] | select(.destination | test("PASSWORD|TOKEN|PRIVATE_KEY|SERVER_KEY")) | .kind] | all(. == "secret")) and
  ([.nonGitHubEntries[] | select(.destination | test("controller.env|private-key|HOST_ALERT"))] | length >= 5)
' "${inventory}" >/dev/null

: >"${audit_log}"
run_helper 0 "${helper}" --check
grep -Fq 'NON_GITHUB_DESTINATION boundary=host-root-file' <<<"${output}"
grep -Fq 'SUMMARY required_source_issues=0 required_destination_missing=0' <<<"${output}"
if grep -Fq 'item view' "${audit_log}" || grep -Fq 'HIGHLY_SECRET_' <<<"${output}"; then
  echo 'check mode read or printed a Proton field value' >&2
  exit 1
fi

run_helper 1 "${helper}" --check --sync
grep -Fq 'select exactly one mode' <<<"${output}"
run_helper 1 "${helper}" --sync
grep -Fq -- '--sync requires one explicit --environment' <<<"${output}"
run_helper 1 "${helper}" --check --environment arbitrary-environment
grep -Fq 'environment is not in the immutable PostgreSQL inventory' <<<"${output}"

: >"${audit_log}"
run_helper 1 env FAKE_MISSING_DESTINATION=KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN \
  "${helper}" --check --environment release-brio-identity-db
grep -Fq 'name=KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN requirement=required status=missing' <<<"${output}"
assert_no_value_read_or_write

: >"${audit_log}"
run_helper 1 env FAKE_MISSING_ITEM='PostgreSQL · shared Swarm deployment' \
  "${helper}" --check --environment production
grep -Fq 'title=PostgreSQL · shared Swarm deployment requirement=required status=missing' <<<"${output}"
assert_no_value_read_or_write

# A selected environment does not inspect unrelated root-only item fields.
: >"${audit_log}"
run_helper 0 env FAKE_MISSING_ITEM='PostgreSQL · CI hypervisor alert' \
  "${helper}" --check --environment staging-brio-identity-db
assert_no_value_read_or_write

: >"${audit_log}"
run_helper 2 env FAKE_UNEXPECTED_DESTINATION=LEGACY_KEYCLOAK_PASSWORD \
  "${helper}" --check --environment canary
grep -Fq 'scope=environment environment=canary kind=secret name=LEGACY_KEYCLOAK_PASSWORD status=legacy-or-unmanaged' <<<"${output}"
assert_no_value_read_or_write

: >"${audit_log}"
run_helper 2 env FAKE_REPOSITORY_LEGACY=LEGACY_REPOSITORY_TOKEN FAKE_REPOSITORY_LEGACY_KIND=secret \
  "${helper}" --check --environment canary
grep -Fq 'scope=repository kind=secret name=LEGACY_REPOSITORY_TOKEN status=forbidden' <<<"${output}"
assert_no_value_read_or_write

: >"${audit_log}"
run_helper 2 env FAKE_REPOSITORY_LEGACY=LEGACY_POLICY_ID FAKE_REPOSITORY_LEGACY_KIND=variable \
  "${helper}" --check --environment canary
grep -Fq 'scope=repository kind=variable name=LEGACY_POLICY_ID status=legacy-or-unmanaged' <<<"${output}"
assert_no_value_read_or_write

: >"${audit_log}"
run_helper 1 env FAKE_INVALID_REPOSITORY=1 "${helper}" --sync --environment canary
grep -Fq 'REPOSITORY name=Makepad-fr/postgres policy=invalid' <<<"${output}"
assert_no_value_read_or_write

for invalid_policy in 1 tag mode; do
  : >"${audit_log}"
  run_helper 1 env FAKE_INVALID_PROTECTION="${invalid_policy}" \
    "${helper}" --sync --environment release-brio-identity-db
  grep -Eq 'protection=(invalid|invalid-branch-policy)' <<<"${output}"
  assert_no_value_read_or_write
done

: >"${audit_log}"
run_helper 1 env FAKE_MISSING_REPOSITORY_VARIABLE=POSTGRES_CI_ATTESTATION_PUBLIC_KEY \
  "${helper}" --sync --environment postgres-ci-attestation
grep -Fq 'required_repository_variable_missing=1' <<<"${output}"
assert_no_value_read_or_write

: >"${audit_log}"
run_helper 1 env FAKE_MISSING_FIELD=KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN \
  "${helper}" --sync --environment release-brio-identity-db
grep -Fq 'required Proton field is missing or unreadable' <<<"${output}"
if grep -Fq 'gh-set ' "${audit_log}" || grep -Fq 'HIGHLY_SECRET_' <<<"${output}"; then
  echo 'failed source preflight wrote a destination or printed a value' >&2
  exit 1
fi

: >"${audit_log}"
run_helper 1 env FAKE_EMPTY_FIELD=KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN \
  "${helper}" --sync --environment release-brio-identity-db
grep -Fq 'required Proton field is empty' <<<"${output}"
if grep -Fq 'gh-set ' "${audit_log}"; then
  echo 'empty source field reached GitHub' >&2
  exit 1
fi

: >"${audit_log}"
run_helper 1 env FAKE_OVERSIZED_FIELD=KEYCLOAK_RELEASE_ORCHESTRATOR_TOKEN \
  "${helper}" --sync --environment release-brio-identity-db
grep -Fq "Proton field exceeds GitHub's bounded value size" <<<"${output}"
if grep -Fq 'gh-set ' "${audit_log}"; then
  echo 'oversized source field reached GitHub' >&2
  exit 1
fi

: >"${audit_log}"
run_helper 1 env FAKE_UNEXPECTED_DESTINATION=LEGACY_KEYCLOAK_PASSWORD \
  "${helper}" --sync --environment canary
grep -Fq 'refusing to sync while forbidden, legacy, or unmanaged GitHub names remain' <<<"${output}"
assert_no_value_read_or_write

: >"${audit_log}"
run_helper 0 "${helper}" --sync --environment staging-brio-identity-db
grep -Fq 'SYNC_COMPLETE repository=Makepad-fr/postgres vault=Makepad environment=staging-brio-identity-db' <<<"${output}"
if grep -Fq 'HIGHLY_SECRET_' <<<"${output}"; then
  echo 'successful sync printed a field value' >&2
  exit 1
fi
expected_syncs=$(jq '[.githubEntries[] | select(.environment == "staging-brio-identity-db")] | length' "${inventory}")
actual_syncs=$(grep -Fc 'gh-set ' "${audit_log}")
[[ "${actual_syncs}" == "${expected_syncs}" ]]
last_source_read=$(grep -n 'pass-cli item view' "${audit_log}" | tail -n 1 | cut -d: -f1)
first_destination_write=$(grep -n 'gh-set ' "${audit_log}" | head -n 1 | cut -d: -f1)
[[ "${last_source_read}" =~ ^[1-9][0-9]*$ && "${first_destination_write}" =~ ^[1-9][0-9]*$ ]]
(( last_source_read < first_destination_write ))

# Malformed or reclassified inventories fail before any provider call.
candidate_root=${test_root}/candidate
install -d -m 0700 "${candidate_root}/scripts" "${candidate_root}/deploy"
cp "${helper}" "${candidate_root}/scripts/sync-github-environments.sh"
chmod 0755 "${candidate_root}/scripts/sync-github-environments.sh"

jq '(.githubEntries[] | select(.destination == "BRIO_IDENTITY_DB_HOSTNAME")).kind = "secret"' \
  "${inventory}" >"${candidate_root}/deploy/credential-inventory.json"
: >"${audit_log}"
run_helper 1 "${candidate_root}/scripts/sync-github-environments.sh" --check --environment staging-brio-identity-db
grep -Fq 'wrong public/secret classification' <<<"${output}"
[[ ! -s "${audit_log}" ]]

jq '.githubEntries += [{"environment":"staging-brio-identity-db","kind":"secret","requirement":"required","destination":"POSTGRES_SERVER_CERT_PEM","item":"Brio Staging - PKI and Backup Keys","field":"POSTGRES_SERVER_CERT_PEM"}]' \
  "${inventory}" >"${candidate_root}/deploy/credential-inventory.json"
: >"${audit_log}"
run_helper 1 "${candidate_root}/scripts/sync-github-environments.sh" --check --environment staging-brio-identity-db
grep -Fq 'PKI destinations do not match' <<<"${output}"
[[ ! -s "${audit_log}" ]]

printf '%s\n' 'PostgreSQL Proton-to-GitHub credential sync tests passed.'
