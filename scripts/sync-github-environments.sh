#!/usr/bin/env bash

# Reconcile reviewed Proton Pass fields into existing GitHub Environments.
# Repository/environment policy is a read-only invariant of this helper.
set +x
set -Eeuo pipefail
umask 077
IFS=$' \t\n'
export LANG=C
export LC_ALL=C
unset BASH_XTRACEFD DEBUG GH_DEBUG PASS_CLI_DEBUG

readonly repository=Makepad-fr/postgres
readonly vault=Makepad
readonly github_api_version=2022-11-28
readonly allowed_environments='canary production staging-brio-identity-db release-brio-identity-db keycloak-cohort-restore'
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly repo_root
readonly inventory=${repo_root}/deploy/credential-inventory.json
readonly max_value_bytes=49152

usage() {
  printf '%s\n' \
    'usage: sync-github-environments.sh [--check] [--environment NAME]' \
    '       sync-github-environments.sh --sync --environment NAME --confirm Makepad-fr/postgres:NAME' \
    '' \
    '  --check  Inspect policy and names only; never read Proton field values (default).' \
    '  --sync   Preflight and reconcile exactly one existing environment.'
}

die() {
  printf 'credential sync: %s\n' "$*" >&2
  exit 1
}

mode=check
mode_selected=0
selected_environment=
provided_confirmation=
while (( $# > 0 )); do
  case "$1" in
    --check|--sync)
      (( mode_selected == 0 )) || die 'select exactly one mode'
      mode=${1#--}
      mode_selected=1
      ;;
    --environment)
      (( $# >= 2 )) || die '--environment requires a value'
      [[ -z "${selected_environment}" ]] || die '--environment may be supplied only once'
      selected_environment=$2
      shift
      ;;
    --confirm)
      (( $# >= 2 )) || die '--confirm requires a value'
      [[ -z "${provided_confirmation}" ]] || die '--confirm may be supplied only once'
      provided_confirmation=$2
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unsupported argument: $1"
      ;;
  esac
  shift
done

case "${selected_environment:-all}" in
  all|canary|production|staging-brio-identity-db|release-brio-identity-db|keycloak-cohort-restore) ;;
  *) die 'environment is not in the reviewed PostgreSQL inventory' ;;
esac
if [[ "${mode}" == sync ]]; then
  [[ -n "${selected_environment}" ]] || die '--sync requires one explicit --environment'
  [[ "${provided_confirmation}" == "${repository}:${selected_environment}" ]] ||
    die '--sync requires the exact repository and environment confirmation'
elif [[ -n "${provided_confirmation}" ]]; then
  die '--confirm is accepted only with --sync'
fi

for command_name in pass-cli gh jq python3 sort grep awk mktemp find wc; do
  command -v "${command_name}" >/dev/null || die "${command_name} is required"
done
[[ -f "${inventory}" && ! -L "${inventory}" ]] || die 'credential inventory is missing or is a symbolic link'

tmp_base=${TMPDIR:-/tmp}
[[ -d "${tmp_base}" && ! -L "${tmp_base}" ]] || die 'temporary directory base is unsafe'
tmp_base=$(cd "${tmp_base}" && pwd -P)
readonly tmp_base
work_root=$(mktemp -d "${tmp_base}/postgres-credential-sync.XXXXXXXX")
[[ -d "${work_root}" && ! -L "${work_root}" ]] || die 'could not create a private work directory'
chmod 0700 "${work_root}"
readonly work_root
readonly entries_file=${work_root}/entries.tsv
readonly policy_file=${work_root}/policy.json
readonly preserved_file=${work_root}/preserved.tsv
readonly proton_items_file=${work_root}/proton-items.txt
readonly repository_secrets_file=${work_root}/repository-secrets.txt
readonly repository_variables_file=${work_root}/repository-variables.txt

declare -a entry_environment=()
declare -a entry_kind=()
declare -a entry_requirement=()
declare -a entry_destination=()
declare -a entry_item=()
declare -a entry_field=()
declare -a source_values=()
declare -a baseline_environment_id=()
declare -a baseline_branch_policy_id=()

cleanup() {
  local index
  for index in "${!source_values[@]}"; do
    unset 'source_values[index]'
  done
  if [[ "${work_root:-}" == "${tmp_base}/postgres-credential-sync."* &&
    -d "${work_root}" && ! -L "${work_root}" ]]; then
    find "${work_root}" -depth -mindepth 1 -delete
    rmdir -- "${work_root}"
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

python3 - "${inventory}" "${repository}" "${vault}" "${selected_environment}" \
  "${policy_file}" "${preserved_file}" >"${entries_file}" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
repository = sys.argv[2]
vault = sys.argv[3]
selected = sys.argv[4]
policy_path = pathlib.Path(sys.argv[5])
preserved_path = pathlib.Path(sys.argv[6])
raw_payload = path.read_text(encoding="utf-8")
payload = json.loads(raw_payload)
inventory_digest = hashlib.sha256(json.dumps(
    payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
).encode()).hexdigest()
if inventory_digest != "89350d300e9ed5d938e2d025fb3fa3cca6b65ae35aa57b7090975117f5c43652":
    raise SystemExit("credential inventory changed without review")

if set(payload) != {
    "schemaVersion", "repository", "vault", "repositoryPolicy",
    "operatorEntries", "preservedDestinations", "entries",
}:
    raise SystemExit("credential inventory has unexpected top-level keys")
if payload["schemaVersion"] != 3 or payload["repository"] != repository or payload["vault"] != vault:
    raise SystemExit("credential inventory identity is invalid")
if payload["operatorEntries"] != []:
    raise SystemExit("credential inventory must not manage operator, runner, or App authority")

expected_preserved = {
    "canary": {
        "secret": ["KEYCLOAK_BRIO_STAGING_BACKUP_DB_PASSWORD", "KEYCLOAK_BRIO_STAGING_DB_PASSWORD"],
        "variable": [],
    },
    "production": {
        "secret": [
            "DEPLOY_FASHION_DB_NAME", "DEPLOY_FASHION_DB_NETWORK",
            "DEPLOY_FASHION_DB_PASSWORD", "DEPLOY_FASHION_DB_USER",
            "DEPLOY_SCRAPING_DB_NAME", "DEPLOY_SCRAPING_DB_NETWORK",
            "DEPLOY_SCRAPING_DB_PASSWORD", "DEPLOY_SCRAPING_DB_USER",
        ],
        "variable": [],
    },
    "staging-brio-identity-db": {
        "secret": ["BRIO_STAGING_BACKUP_DB_PASSWORD", "BRIO_STAGING_DB_PASSWORD"],
        "variable": ["POSTGRES_HOST_COMPOSE_PROJECT"],
    },
    "release-brio-identity-db": {"secret": [], "variable": []},
    "keycloak-cohort-restore": {"secret": [], "variable": []},
}
if payload["preservedDestinations"] != expected_preserved:
    raise SystemExit("preserved destination boundary is invalid")

policy = payload["repositoryPolicy"]
if not isinstance(policy, dict) or set(policy) != {
    "repositoryId", "private", "visibility", "allowForking", "defaultBranch",
    "requiredChecks", "requiredCheckAppId", "mainProtection", "actionsPolicy", "environments",
}:
    raise SystemExit("repository policy has unexpected keys")
if (
    policy["repositoryId"] != 1200300784
    or policy["private"] is not False
    or policy["visibility"] != "public"
    or policy["allowForking"] is not True
    or policy["defaultBranch"] != "main"
    or policy["requiredChecks"] != ["policy-and-integration"]
    or policy["requiredCheckAppId"] != 15368
):
    raise SystemExit("repository identity or native status policy is invalid")
if policy["mainProtection"] != {
    "strictStatusChecks": True,
    "enforceAdmins": True,
    "dismissStaleReviews": True,
    "requireCodeOwnerReviews": True,
    "requiredApprovingReviewCount": 1,
    "requireLastPushApproval": True,
    "requiredSignatures": True,
    "requiredLinearHistory": True,
    "requiredConversationResolution": True,
    "allowForcePushes": False,
    "allowDeletions": False,
    "blockCreations": False,
    "lockBranch": False,
    "allowForkSyncing": False,
}:
    raise SystemExit("reviewed main protection is invalid")
if policy["actionsPolicy"] != {
    "defaultWorkflowPermissions": "read",
    "canApprovePullRequestReviews": False,
}:
    raise SystemExit("reviewed Actions token policy is invalid")
if policy["environments"] != {
    "canary": {"id": 21262761188, "branchPolicyId": 59128365, "reviewerId": None, "reviewerLogin": None},
    "production": {"id": 15050761884, "branchPolicyId": 59156955, "reviewerId": None, "reviewerLogin": None},
    "staging-brio-identity-db": {"id": 21278291993, "branchPolicyId": 59143916, "reviewerId": 39597780, "reviewerLogin": "idilsaglam"},
    "release-brio-identity-db": {"id": 21284627193, "branchPolicyId": 59149936, "reviewerId": 39597780, "reviewerLogin": "idilsaglam"},
    "keycloak-cohort-restore": {"id": 21284627918, "branchPolicyId": 59149937, "reviewerId": 39597780, "reviewerLogin": "idilsaglam"},
}:
    raise SystemExit("reviewed environment identities are invalid")

allowed_environments = set(policy["environments"])
entry_keys = {"environment", "kind", "requirement", "destination", "item", "field"}
destination_pattern = re.compile(r"^[A-Z][A-Z0-9_]{1,127}$")
field_pattern = re.compile(r"^[A-Za-z][A-Za-z0-9_ -]{0,127}$")
seen = set()
counts = {environment: 0 for environment in allowed_environments}
entries = payload["entries"]
if not isinstance(entries, list) or not entries:
    raise SystemExit("credential inventory entries are missing")
for offset, entry in enumerate(entries):
    if not isinstance(entry, dict) or set(entry) != entry_keys:
        raise SystemExit(f"credential inventory entry {offset} has unexpected keys")
    environment = entry["environment"]
    kind = entry["kind"]
    requirement = entry["requirement"]
    destination = entry["destination"]
    item = entry["item"]
    field = entry["field"]
    if environment not in allowed_environments or kind not in {"secret", "variable"}:
        raise SystemExit(f"credential inventory entry {offset} has an invalid scope")
    if requirement not in {"required", "optional"}:
        raise SystemExit(f"credential inventory entry {offset} has an invalid requirement")
    if not isinstance(destination, str) or not destination_pattern.fullmatch(destination):
        raise SystemExit(f"credential inventory entry {offset} has an invalid destination")
    if not isinstance(item, str) or not item or len(item) > 128 or any(c in item for c in "\t\r\n"):
        raise SystemExit(f"credential inventory entry {offset} has an invalid Proton item")
    if not isinstance(field, str) or not field_pattern.fullmatch(field):
        raise SystemExit(f"credential inventory entry {offset} has an invalid Proton field")
    identity = (environment, kind, destination)
    if identity in seen:
        raise SystemExit(f"duplicate GitHub destination: {environment}/{kind}/{destination}")
    seen.add(identity)
    counts[environment] += 1
    if not selected or selected == environment:
        print("\t".join((environment, kind, requirement, destination, item, field)))
if any(count == 0 for count in counts.values()):
    raise SystemExit("every approved environment must have at least one entry")
for environment, kinds in expected_preserved.items():
    for kind, destinations in kinds.items():
        for destination in destinations:
            if (environment, kind, destination) in seen:
                raise SystemExit("preserved destination overlaps a managed destination")

policy_path.write_text(json.dumps(policy, separators=(",", ":")), encoding="utf-8")
preserved_path.write_text("".join(
    f"{environment}\t{kind}\t{destination}\n"
    for environment in sorted(expected_preserved)
    if not selected or selected == environment
    for kind in ("secret", "variable")
    for destination in expected_preserved[environment][kind]
), encoding="utf-8")
PY

[[ -s "${entries_file}" ]] || die 'the selected inventory is empty'
while IFS=$'\t' read -r environment kind requirement destination item field; do
  index=${#entry_environment[@]}
  entry_environment[index]=${environment}
  entry_kind[index]=${kind}
  entry_requirement[index]=${requirement}
  entry_destination[index]=${destination}
  entry_item[index]=${item}
  entry_field[index]=${field}
done <"${entries_file}"

pass-cli test >/dev/null || die 'Proton Pass is not authenticated'
GH_PROMPT_DISABLED=1 gh auth status >/dev/null 2>&1 || die 'GitHub CLI is not authenticated'

environment_selected() {
  [[ -z "${selected_environment}" || "${selected_environment}" == "$1" ]]
}

destination_expected() {
  local environment=$1 kind=$2 destination=$3
  if awk -F '\t' -v environment="${environment}" -v kind="${kind}" -v destination="${destination}" \
    '$1 == environment && $2 == kind && $4 == destination { found = 1 } END { exit !found }' "${entries_file}"; then
    return 0
  fi
  awk -F '\t' -v environment="${environment}" -v kind="${kind}" -v destination="${destination}" \
    '$1 == environment && $2 == kind && $3 == destination { found = 1 } END { exit !found }' "${preserved_file}"
}

protection_errors=0
missing_required_sources=0
missing_required_destinations=0
missing_optional_sources=0
missing_optional_destinations=0
unexpected_destinations=0

load_names_and_policy() {
  local repository_json protection_json actions_json environment environment_json policies_json
  local expected_id expected_policy_id expected_reviewer_id expected_reviewer_login actual_id actual_policy_id
  local identity_index kind names_file

  protection_errors=0
  find "${work_root}" -maxdepth 1 -type f -name 'github-*.txt' -delete
  if ! pass-cli item list --vault-name "${vault}" --filter-state active --output json |
    jq -er '.items | if type == "array" then . else error("invalid item list") end | .[] | .title' |
    sort >"${proton_items_file}"; then
    die 'could not read Proton Pass item names'
  fi

  if ! repository_json=$(GH_PROMPT_DISABLED=1 gh api --header "X-GitHub-Api-Version: ${github_api_version}" "repos/${repository}") ||
    ! jq -e --arg repository "${repository}" --argjson policy "$(<"${policy_file}")" '
      .full_name == $repository and .id == $policy.repositoryId and
      .private == $policy.private and .visibility == $policy.visibility and
      .allow_forking == $policy.allowForking and .default_branch == $policy.defaultBranch and
      .archived == false and .disabled == false
    ' >/dev/null <<<"${repository_json}"; then
    printf 'REPOSITORY name=%s policy=identity-or-visibility-invalid\n' "${repository}"
    ((protection_errors += 1))
  elif ! protection_json=$(GH_PROMPT_DISABLED=1 gh api --header "X-GitHub-Api-Version: ${github_api_version}" "repos/${repository}/branches/main/protection") ||
    ! jq -e --argjson policy "$(<"${policy_file}")" '
      .required_status_checks.strict == $policy.mainProtection.strictStatusChecks and
      ([.required_status_checks.checks[]? | {context,app_id}] ==
        [{context:$policy.requiredChecks[0],app_id:$policy.requiredCheckAppId}]) and
      .enforce_admins.enabled == $policy.mainProtection.enforceAdmins and
      .required_pull_request_reviews.dismiss_stale_reviews == $policy.mainProtection.dismissStaleReviews and
      .required_pull_request_reviews.require_code_owner_reviews == $policy.mainProtection.requireCodeOwnerReviews and
      .required_pull_request_reviews.required_approving_review_count == $policy.mainProtection.requiredApprovingReviewCount and
      .required_pull_request_reviews.require_last_push_approval == $policy.mainProtection.requireLastPushApproval and
      .required_signatures.enabled == $policy.mainProtection.requiredSignatures and
      .required_linear_history.enabled == $policy.mainProtection.requiredLinearHistory and
      .required_conversation_resolution.enabled == $policy.mainProtection.requiredConversationResolution and
      .allow_force_pushes.enabled == $policy.mainProtection.allowForcePushes and
      .allow_deletions.enabled == $policy.mainProtection.allowDeletions and
      .block_creations.enabled == $policy.mainProtection.blockCreations and
      .lock_branch.enabled == $policy.mainProtection.lockBranch and
      .allow_fork_syncing.enabled == $policy.mainProtection.allowForkSyncing
    ' >/dev/null <<<"${protection_json}"; then
    printf 'REPOSITORY name=%s policy=main-protection-invalid\n' "${repository}"
    ((protection_errors += 1))
  elif ! actions_json=$(GH_PROMPT_DISABLED=1 gh api --header "X-GitHub-Api-Version: ${github_api_version}" "repos/${repository}/actions/permissions/workflow") ||
    ! jq -e --argjson policy "$(<"${policy_file}")" '
      .default_workflow_permissions == $policy.actionsPolicy.defaultWorkflowPermissions and
      .can_approve_pull_request_reviews == $policy.actionsPolicy.canApprovePullRequestReviews
    ' >/dev/null <<<"${actions_json}"; then
    printf 'REPOSITORY name=%s policy=actions-token-policy-invalid\n' "${repository}"
    ((protection_errors += 1))
  else
    printf 'REPOSITORY name=%s policy=reviewed-native-main-only identity=stable\n' "${repository}"
  fi

  GH_PROMPT_DISABLED=1 gh secret list --repo "${repository}" --json name --jq '.[].name' |
    sort >"${repository_secrets_file}" || die 'could not list repository secret names'
  GH_PROMPT_DISABLED=1 gh variable list --repo "${repository}" --json name --jq '.[].name' |
    sort >"${repository_variables_file}" || die 'could not list repository variable names'

  identity_index=0
  for environment in ${allowed_environments}; do
    environment_selected "${environment}" || continue
    expected_id=$(jq -er --arg environment "${environment}" '.environments[$environment].id' "${policy_file}")
    expected_policy_id=$(jq -er --arg environment "${environment}" '.environments[$environment].branchPolicyId' "${policy_file}")
    expected_reviewer_id=$(jq -r --arg environment "${environment}" '.environments[$environment].reviewerId // empty' "${policy_file}")
    expected_reviewer_login=$(jq -r --arg environment "${environment}" '.environments[$environment].reviewerLogin // empty' "${policy_file}")
    if ! environment_json=$(GH_PROMPT_DISABLED=1 gh api --header "X-GitHub-Api-Version: ${github_api_version}" "repos/${repository}/environments/${environment}") ||
      ! jq -e --arg environment "${environment}" --argjson expected_id "${expected_id}" \
        --arg reviewer_id "${expected_reviewer_id}" --arg reviewer_login "${expected_reviewer_login}" '
        .name == $environment and .id == $expected_id and .can_admins_bypass == true and
        .deployment_branch_policy.protected_branches == false and
        .deployment_branch_policy.custom_branch_policies == true and
        ([.protection_rules[] | select(.type == "branch_policy")] | length) == 1 and
        if $reviewer_id == "" then
          ([.protection_rules[] | select(.type != "branch_policy")] | length) == 0
        else
          ([.protection_rules[] | select(.type == "required_reviewers")] | length) == 1 and
          ([.protection_rules[] | select(.type == "required_reviewers")][0] |
            .prevent_self_review == true and (.reviewers | length) == 1 and
            .reviewers[0].type == "User" and
            (.reviewers[0].reviewer.id | tostring) == $reviewer_id and
            .reviewers[0].reviewer.login == $reviewer_login)
        end
      ' >/dev/null <<<"${environment_json}"; then
      printf 'ENVIRONMENT name=%s protection=invalid\n' "${environment}"
      ((protection_errors += 1))
      continue
    fi
    if ! policies_json=$(GH_PROMPT_DISABLED=1 gh api --header "X-GitHub-Api-Version: ${github_api_version}" \
      "repos/${repository}/environments/${environment}/deployment-branch-policies?per_page=100") ||
      ! jq -e --argjson expected_policy_id "${expected_policy_id}" '
        .total_count == 1 and (.branch_policies | length) == 1 and
        .branch_policies[0].id == $expected_policy_id and
        .branch_policies[0].name == "main" and .branch_policies[0].type == "branch"
      ' >/dev/null <<<"${policies_json}"; then
      printf 'ENVIRONMENT name=%s protection=invalid-branch-policy\n' "${environment}"
      ((protection_errors += 1))
      continue
    fi
    actual_id=$(jq -er '.id' <<<"${environment_json}")
    actual_policy_id=$(jq -er '.branch_policies[0].id' <<<"${policies_json}")
    if [[ "${mode}" == sync && ${#baseline_environment_id[@]} -gt identity_index ]]; then
      [[ "${baseline_environment_id[identity_index]}" == "${actual_id}" &&
        "${baseline_branch_policy_id[identity_index]}" == "${actual_policy_id}" ]] || {
        printf 'ENVIRONMENT name=%s protection=identity-changed\n' "${environment}"
        ((protection_errors += 1))
        continue
      }
    elif [[ "${mode}" == sync ]]; then
      baseline_environment_id[identity_index]=${actual_id}
      baseline_branch_policy_id[identity_index]=${actual_policy_id}
    fi
    ((identity_index += 1))
    printf 'ENVIRONMENT name=%s protection=exact-reviewed-matrix identity=stable\n' "${environment}"

    for kind in secret variable; do
      names_file=${work_root}/github-${environment}-${kind}.txt
      if [[ "${kind}" == secret ]]; then
        GH_PROMPT_DISABLED=1 gh secret list --repo "${repository}" --env "${environment}" \
          --json name --jq '.[].name' | sort >"${names_file}" || die "could not list ${environment} secret names"
      else
        GH_PROMPT_DISABLED=1 gh variable list --repo "${repository}" --env "${environment}" \
          --json name --jq '.[].name' | sort >"${names_file}" || die "could not list ${environment} variable names"
      fi
    done
  done
}

report_status() {
  local environment kind requirement destination item item_count destination_file status actual_name
  missing_required_sources=0
  missing_required_destinations=0
  missing_optional_sources=0
  missing_optional_destinations=0
  unexpected_destinations=0

  while IFS=$'\t' read -r item requirement; do
    item_count=$(grep -Fxc -- "${item}" "${proton_items_file}" || true)
    case "${item_count}" in
      1) status=present ;;
      0) status=missing ;;
      *) status=ambiguous ;;
    esac
    printf 'SOURCE_ITEM title=%s requirement=%s status=%s\n' "${item}" "${requirement}" "${status}"
    if [[ "${status}" != present ]]; then
      if [[ "${requirement}" == required ]]; then
        ((missing_required_sources += 1))
      else
        ((missing_optional_sources += 1))
      fi
    fi
  done < <(awk -F '\t' '{key=$5 FS $3; seen[key]=1} END {for (key in seen) print key}' "${entries_file}" | sort)

  for index in "${!entry_environment[@]}"; do
    environment=${entry_environment[index]}
    kind=${entry_kind[index]}
    requirement=${entry_requirement[index]}
    destination=${entry_destination[index]}
    destination_file=${work_root}/github-${environment}-${kind}.txt
    if [[ -f "${destination_file}" ]] && grep -Fqx -- "${destination}" "${destination_file}"; then
      status=present
    else
      status=missing
      if [[ "${requirement}" == required ]]; then
        ((missing_required_destinations += 1))
      else
        ((missing_optional_destinations += 1))
      fi
    fi
    printf 'DESTINATION environment=%s kind=%s name=%s requirement=%s status=%s\n' \
      "${environment}" "${kind}" "${destination}" "${requirement}" "${status}"
  done

  while IFS=$'\t' read -r environment kind destination; do
    destination_file=${work_root}/github-${environment}-${kind}.txt
    if [[ -f "${destination_file}" ]] && grep -Fqx -- "${destination}" "${destination_file}"; then
      status=preserved-existing
    else
      status=preserved-absent
    fi
    printf 'PRESERVED_DESTINATION environment=%s kind=%s name=%s status=%s\n' \
      "${environment}" "${kind}" "${destination}" "${status}"
  done <"${preserved_file}"

  for environment in ${allowed_environments}; do
    environment_selected "${environment}" || continue
    for kind in secret variable; do
      destination_file=${work_root}/github-${environment}-${kind}.txt
      [[ -f "${destination_file}" ]] || continue
      while IFS= read -r actual_name; do
        [[ -n "${actual_name}" ]] || continue
        if ! destination_expected "${environment}" "${kind}" "${actual_name}"; then
          printf 'UNEXPECTED_DESTINATION scope=environment environment=%s kind=%s name=%s status=legacy-or-unmanaged\n' \
            "${environment}" "${kind}" "${actual_name}"
          ((unexpected_destinations += 1))
        fi
      done <"${destination_file}"
    done
  done

  for kind in secret variable; do
    destination_file=${repository_secrets_file}
    [[ "${kind}" == secret ]] || destination_file=${repository_variables_file}
    while IFS= read -r actual_name; do
      [[ -n "${actual_name}" ]] || continue
      printf 'UNEXPECTED_DESTINATION scope=repository kind=%s name=%s status=forbidden\n' "${kind}" "${actual_name}"
      ((unexpected_destinations += 1))
    done <"${destination_file}"
  done

  printf 'SUMMARY required_source_issues=%d required_destination_missing=%d optional_source_issues=%d optional_destination_missing=%d unexpected_destinations=%d protection_errors=%d\n' \
    "${missing_required_sources}" "${missing_required_destinations}" \
    "${missing_optional_sources}" "${missing_optional_destinations}" \
    "${unexpected_destinations}" "${protection_errors}"
}

load_names_and_policy
report_status
if [[ "${mode}" == check ]]; then
  if (( protection_errors > 0 || missing_required_sources > 0 || missing_required_destinations > 0 )); then
    exit 1
  fi
  (( unexpected_destinations == 0 )) || exit 2
  exit 0
fi

(( protection_errors == 0 )) || die 'refusing to sync into an invalid repository or environment policy'
(( unexpected_destinations == 0 )) || die 'refusing to sync while forbidden or unmanaged GitHub names remain'
(( missing_required_sources == 0 )) || die 'required Proton Pass source items are missing or ambiguous'
ulimit -c 0 || die 'could not disable process core dumps before handling credential values'

for index in "${!entry_environment[@]}"; do
  item=${entry_item[index]}
  field=${entry_field[index]}
  if ! value=$(pass-cli item view --vault-name "${vault}" --item-title "${item}" --field "${field}" 2>/dev/null); then
    die "required Proton field is missing or unreadable: ${item}/${field}"
  fi
  [[ -n "${value}" ]] || die "required Proton field is empty: ${item}/${field}"
  (( ${#value} <= max_value_bytes )) || die "Proton field exceeds the bounded value size: ${item}/${field}"
  source_values[index]=${value}
  unset value
done

load_names_and_policy
report_status
(( protection_errors == 0 )) || die 'repository or environment protection changed during source preflight'
(( unexpected_destinations == 0 )) || die 'a forbidden or unmanaged GitHub name appeared during source preflight'
(( missing_required_sources == 0 )) || die 'a required Proton item disappeared during source preflight'

for index in "${!entry_environment[@]}"; do
  item=${entry_item[index]}
  field=${entry_field[index]}
  if ! value=$(pass-cli item view --vault-name "${vault}" --item-title "${item}" --field "${field}" 2>/dev/null); then
    die "required Proton field disappeared during preflight: ${item}/${field}"
  fi
  [[ "${value}" == "${source_values[index]}" ]] || die "Proton source changed during preflight: ${item}/${field}"
  unset value
done

for index in "${!entry_environment[@]}"; do
  environment=${entry_environment[index]}
  kind=${entry_kind[index]}
  destination=${entry_destination[index]}
  if [[ "${kind}" == secret ]]; then
    printf '%s' "${source_values[index]}" |
      GH_PROMPT_DISABLED=1 gh secret set "${destination}" --repo "${repository}" --env "${environment}" >/dev/null 2>&1 ||
      die "GitHub rejected ${environment}/${kind}/${destination}"
  else
    printf '%s' "${source_values[index]}" |
      GH_PROMPT_DISABLED=1 gh variable set "${destination}" --repo "${repository}" --env "${environment}" >/dev/null 2>&1 ||
      die "GitHub rejected ${environment}/${kind}/${destination}"
    readback=$(GH_PROMPT_DISABLED=1 gh variable get "${destination}" --repo "${repository}" --env "${environment}" \
      --json value --jq '.value' 2>/dev/null) || die "GitHub variable readback failed: ${destination}"
    [[ "${readback}" == "${source_values[index]}" ]] || die "GitHub variable readback differs from Proton: ${destination}"
    unset readback
  fi
  printf 'SYNCED environment=%s kind=%s name=%s\n' "${environment}" "${kind}" "${destination}"
done

load_names_and_policy
report_status
(( protection_errors == 0 && missing_required_destinations == 0 && unexpected_destinations == 0 )) ||
  die 'GitHub destination or policy readback did not match the reviewed inventory'
for index in "${!entry_environment[@]}"; do
  item=${entry_item[index]}
  field=${entry_field[index]}
  if ! value=$(pass-cli item view --vault-name "${vault}" --item-title "${item}" --field "${field}" 2>/dev/null); then
    die "required Proton field disappeared after write: ${item}/${field}"
  fi
  [[ "${value}" == "${source_values[index]}" ]] || die "Proton source changed during write: ${item}/${field}"
  unset value 'source_values[index]'
done
printf 'SYNC_COMPLETE repository=%s vault=%s environment=%s\n' "${repository}" "${vault}" "${selected_environment}"
