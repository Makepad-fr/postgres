#!/usr/bin/env bash

# Never inherit tracing while values are held in memory. Selected values are
# sent to gh only on standard input and are never exported or written to disk.
set +x
set -Eeuo pipefail
umask 077
IFS=$' \t\n'
export LANG=C
export LC_ALL=C
unset GH_DEBUG DEBUG PASS_CLI_DEBUG BASH_XTRACEFD

readonly repository=Makepad-fr/postgres
readonly vault=Makepad
readonly allowed_environments='canary production staging-brio-identity-db release-brio-identity-db keycloak-cohort-restore postgres-ci-attestation'
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly repo_root
readonly inventory=${repo_root}/deploy/credential-inventory.json
readonly inventory_contract_validator=${repo_root}/scripts/validate-credential-inventory-contract.py
readonly repository_anchor_validator=${repo_root}/scripts/validate-repository-trust-anchor.py
readonly environment_policy_reconciler=${repo_root}/scripts/reconcile-github-environment-main-policy.py
readonly max_value_bytes=49152

usage() {
  printf '%s\n' \
    'usage: sync-github-environments.sh [--check|--sync] [--environment NAME]' \
    '       sync-github-environments.sh --sync-repository-variables --confirm Makepad-fr/postgres:repository-variables' \
    '' \
    '  --check  Read names and policy only; never read Proton field values (default).' \
    '  --sync   Preflight every selected field, then stream one environment to GitHub.' \
    '  --sync-repository-variables' \
    '           Reconcile exactly the four public CI trust anchors and verify exact read-back.'
}

die() {
  printf 'credential sync: %s\n' "$*" >&2
  exit 1
}

mode=check
mode_selected=0
selected_environment=
confirmation=
while (( $# > 0 )); do
  case "$1" in
    --check|--sync|--sync-repository-variables)
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
      [[ -z "${confirmation}" ]] || die '--confirm may be supplied only once'
      confirmation=$2
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

case "${selected_environment}" in
  ''|canary|production|staging-brio-identity-db|release-brio-identity-db|keycloak-cohort-restore|postgres-ci-attestation) ;;
  *) die 'environment is not in the immutable PostgreSQL inventory' ;;
esac
if [[ "${mode}" == sync && -z "${selected_environment}" ]]; then
  die '--sync requires one explicit --environment to bound the write scope'
fi
if [[ "${mode}" == sync-repository-variables ]]; then
  [[ -z "${selected_environment}" ]] || die '--sync-repository-variables does not accept --environment'
  [[ "${confirmation}" == "${repository}:repository-variables" ]] || \
    die '--sync-repository-variables requires --confirm Makepad-fr/postgres:repository-variables'
elif [[ -n "${confirmation}" ]]; then
  die '--confirm is accepted only with --sync-repository-variables'
fi

for command_name in pass-cli gh jq python3 sort grep awk mktemp find wc tr; do
  command -v "${command_name}" >/dev/null || die "${command_name} is required"
done
[[ -f "${inventory}" && ! -L "${inventory}" ]] || die 'credential inventory is missing or is a symbolic link'
[[ -f "${inventory_contract_validator}" && ! -L "${inventory_contract_validator}" ]] || \
  die 'credential inventory contract validator is missing or is a symbolic link'
[[ -f "${repository_anchor_validator}" && ! -L "${repository_anchor_validator}" ]] || \
  die 'repository trust-anchor validator is missing or is a symbolic link'
[[ -f "${environment_policy_reconciler}" && ! -L "${environment_policy_reconciler}" ]] || \
  die 'environment protection reconciler is missing or is a symbolic link'
PYTHONDONTWRITEBYTECODE=1 python3 "${inventory_contract_validator}" "${inventory}" || \
  die 'credential inventory does not match the immutable reviewed contract'

tmp_base=${TMPDIR:-/tmp}
[[ -d "${tmp_base}" && ! -L "${tmp_base}" ]] || die 'temporary directory base is unsafe'
tmp_base=$(cd "${tmp_base}" && pwd -P)
readonly tmp_base
status_root=$(mktemp -d "${tmp_base}/postgres-credential-sync.XXXXXXXX")
[[ -d "${status_root}" && ! -L "${status_root}" ]] || die 'could not create a private status directory'
chmod 0700 "${status_root}"
readonly status_root
readonly github_entries_file=${status_root}/github-entries.tsv
readonly repository_entries_file=${status_root}/repository-entries.tsv
readonly non_github_entries_file=${status_root}/non-github-entries.tsv
readonly selected_sources_file=${status_root}/selected-sources.tsv
readonly proton_items_file=${status_root}/proton-items.txt
readonly repository_secrets_file=${status_root}/github-repository-secrets.txt
readonly repository_variables_file=${status_root}/github-repository-variables.txt

declare -a entry_environment=()
declare -a entry_kind=()
declare -a entry_requirement=()
declare -a entry_destination=()
declare -a entry_item=()
declare -a entry_field=()
declare -a source_values=()
declare -a source_available=()
declare -a repository_requirement=()
declare -a repository_destination=()
declare -a repository_item=()
declare -a repository_field=()
declare -a repository_source_values=()

cleanup() {
  local index
  for index in "${!source_values[@]}"; do
    unset 'source_values[index]'
  done
  for index in "${!repository_source_values[@]}"; do
    unset 'repository_source_values[index]'
  done
  if [[ -n "${status_root:-}" && "${status_root}" == "${tmp_base}/postgres-credential-sync."* && -d "${status_root}" && ! -L "${status_root}" ]]; then
    find "${status_root}" -depth -mindepth 1 -delete
    rmdir -- "${status_root}"
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

python3 - "${inventory}" "${repository}" "${vault}" "${selected_environment}" "${mode}" \
  "${github_entries_file}" "${repository_entries_file}" "${non_github_entries_file}" "${selected_sources_file}" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
expected_repository = sys.argv[2]
expected_vault = sys.argv[3]
selected_environment = sys.argv[4]
mode = sys.argv[5]
github_output = pathlib.Path(sys.argv[6])
repository_output = pathlib.Path(sys.argv[7])
non_github_output = pathlib.Path(sys.argv[8])
sources_output = pathlib.Path(sys.argv[9])
repository_sync = mode == "sync-repository-variables"
payload = json.loads(path.read_text(encoding="utf-8"))

expected_top_level = {
    "schemaVersion", "repository", "vault", "githubEntries",
    "repositoryVariables", "nonGitHubEntries",
}
if set(payload) != expected_top_level:
    raise SystemExit("credential inventory has unexpected top-level keys")
if payload["schemaVersion"] != 1:
    raise SystemExit("unsupported credential inventory schema")
if payload["repository"] != expected_repository or payload["vault"] != expected_vault:
    raise SystemExit("credential inventory targets an unexpected repository or vault")

allowed_environments = {
    "canary", "production", "staging-brio-identity-db",
    "release-brio-identity-db", "keycloak-cohort-restore",
    "postgres-ci-attestation",
}
allowed_kinds = {"secret", "variable"}
allowed_requirements = {"required", "optional"}
allowed_boundaries = {
    "host-root-file", "host-root-setting", "operator-stdin",
    "operator-verification",
}
public_environment_destinations = {
    "BRIO_IDENTITY_DB_HOSTNAME", "BRIO_KEYCLOAK_DB_SOURCE_CIDR",
}
expected_repository_variables = {
    "POSTGRES_CI_LAUNCHER_APP_SENDER_ID",
    "POSTGRES_CI_APPROVED_BASE_IMAGE_SHA256",
    "POSTGRES_CI_ATTESTATION_PUBLIC_KEY",
    "POSTGRES_PR_CHECK_APP_ID",
}
destination_pattern = re.compile(r"^[A-Z][A-Z0-9_]{1,127}$")
field_pattern = re.compile(r"^[A-Za-z][A-Za-z0-9_ -]{0,127}$")

def valid_text(value, limit=256):
    return (
        isinstance(value, str) and 0 < len(value) <= limit
        and not any(character in value for character in "\t\r\n")
    )

github_entries = payload["githubEntries"]
repository_entries = payload["repositoryVariables"]
non_github_entries = payload["nonGitHubEntries"]
if not all(isinstance(entries, list) and entries for entries in (github_entries, repository_entries, non_github_entries)):
    raise SystemExit("every credential inventory section must be a non-empty list")

github_lines = []
repository_lines = []
non_github_lines = []
selected_source_requirements = {}
seen_github = set()
seen_repository = set()
seen_non_github = set()
environment_counts = {environment: 0 for environment in allowed_environments}
pki_destinations = set()

for offset, entry in enumerate(github_entries):
    expected_keys = {"environment", "kind", "requirement", "destination", "item", "field"}
    if not isinstance(entry, dict) or set(entry) != expected_keys:
        raise SystemExit(f"GitHub inventory entry {offset} has unexpected keys")
    environment = entry["environment"]
    kind = entry["kind"]
    requirement = entry["requirement"]
    destination = entry["destination"]
    item = entry["item"]
    field = entry["field"]
    if environment not in allowed_environments or kind not in allowed_kinds or requirement not in allowed_requirements:
        raise SystemExit(f"GitHub inventory entry {offset} has an invalid classification")
    if not isinstance(destination, str) or not destination_pattern.fullmatch(destination):
        raise SystemExit(f"GitHub inventory entry {offset} has an invalid destination")
    if not valid_text(item, 128) or not isinstance(field, str) or not field_pattern.fullmatch(field):
        raise SystemExit(f"GitHub inventory entry {offset} has an invalid Proton source")
    if (destination in public_environment_destinations) != (kind == "variable"):
        raise SystemExit(f"GitHub inventory entry {offset} has the wrong public/secret classification")
    identity = (environment, kind, destination)
    if identity in seen_github:
        raise SystemExit(f"duplicate GitHub destination: {environment}/{kind}/{destination}")
    seen_github.add(identity)
    environment_counts[environment] += 1
    if item == "Brio Staging - PKI and Backup Keys" and destination.endswith("_PEM"):
        pki_destinations.add((environment, destination))
    if not selected_environment or environment == selected_environment or (
        repository_sync and environment == "postgres-ci-attestation"
    ):
        github_lines.append("\t".join((environment, kind, requirement, destination, item, field)))
        if not repository_sync:
            prior = selected_source_requirements.get(item)
            selected_source_requirements[item] = "required" if requirement == "required" or prior == "required" else "optional"

if any(count == 0 for count in environment_counts.values()):
    raise SystemExit("every approved GitHub environment must have at least one inventory entry")
expected_pki_destinations = {
    ("canary", "POSTGRES_CA_PEM"),
    ("canary", "POSTGRES_SERVER_CERT_PEM"),
    ("canary", "POSTGRES_SERVER_KEY_PEM"),
    ("canary", "BRIO_BACKUP_RECIPIENT_CERT_PEM"),
    ("staging-brio-identity-db", "BRIO_BACKUP_RECIPIENT_CERT_PEM"),
}
if pki_destinations != expected_pki_destinations:
    raise SystemExit("Brio PKI destinations do not match the reviewed workflow split")

for offset, entry in enumerate(repository_entries):
    expected_keys = {"requirement", "destination", "item", "field"}
    if not isinstance(entry, dict) or set(entry) != expected_keys:
        raise SystemExit(f"repository-variable entry {offset} has unexpected keys")
    requirement = entry["requirement"]
    destination = entry["destination"]
    item = entry["item"]
    field = entry["field"]
    if requirement not in allowed_requirements or destination not in expected_repository_variables:
        raise SystemExit(f"repository-variable entry {offset} has an invalid classification")
    if not valid_text(item, 128) or not isinstance(field, str) or not field_pattern.fullmatch(field):
        raise SystemExit(f"repository-variable entry {offset} has an invalid Proton source")
    if destination in seen_repository:
        raise SystemExit(f"duplicate repository variable: {destination}")
    seen_repository.add(destination)
    repository_lines.append("\t".join((requirement, destination, item, field)))
    if repository_sync or not selected_environment or selected_environment == "postgres-ci-attestation":
        prior = selected_source_requirements.get(item)
        selected_source_requirements[item] = "required" if requirement == "required" or prior == "required" else "optional"
if seen_repository != expected_repository_variables:
    raise SystemExit("repository policy variable set is incomplete")

for offset, entry in enumerate(non_github_entries):
    expected_keys = {"boundary", "requirement", "destination", "item", "field"}
    if not isinstance(entry, dict) or set(entry) != expected_keys:
        raise SystemExit(f"non-GitHub inventory entry {offset} has unexpected keys")
    boundary = entry["boundary"]
    requirement = entry["requirement"]
    destination = entry["destination"]
    item = entry["item"]
    field = entry["field"]
    if boundary not in allowed_boundaries or requirement not in allowed_requirements:
        raise SystemExit(f"non-GitHub inventory entry {offset} has an invalid classification")
    if not valid_text(destination) or not valid_text(item, 128) or not isinstance(field, str) or not field_pattern.fullmatch(field):
        raise SystemExit(f"non-GitHub inventory entry {offset} has invalid text")
    identity = (boundary, destination)
    if identity in seen_non_github:
        raise SystemExit(f"duplicate non-GitHub destination: {boundary}/{destination}")
    seen_non_github.add(identity)
    non_github_lines.append("\t".join((boundary, requirement, destination, item, field)))
    if not selected_environment and not repository_sync:
        prior = selected_source_requirements.get(item)
        selected_source_requirements[item] = "required" if requirement == "required" or prior == "required" else "optional"

github_output.write_text("\n".join(github_lines) + "\n", encoding="utf-8")
repository_output.write_text("\n".join(repository_lines) + "\n", encoding="utf-8")
non_github_output.write_text("\n".join(non_github_lines) + "\n", encoding="utf-8")
sources_output.write_text(
    "\n".join(f"{item}\t{requirement}" for item, requirement in sorted(selected_source_requirements.items())) + "\n",
    encoding="utf-8",
)
PY

[[ -s "${github_entries_file}" && -s "${repository_entries_file}" && -s "${selected_sources_file}" ]] || die 'the selected inventory is empty'

while IFS=$'\t' read -r environment kind requirement destination item field; do
  index=${#entry_environment[@]}
  entry_environment[index]=${environment}
  entry_kind[index]=${kind}
  entry_requirement[index]=${requirement}
  entry_destination[index]=${destination}
  entry_item[index]=${item}
  entry_field[index]=${field}
done <"${github_entries_file}"

while IFS=$'\t' read -r requirement destination item field; do
  index=${#repository_destination[@]}
  repository_requirement[index]=${requirement}
  repository_destination[index]=${destination}
  repository_item[index]=${item}
  repository_field[index]=${field}
done <"${repository_entries_file}"

pass-cli test >/dev/null || die 'Proton Pass is not authenticated'
GH_PROMPT_DISABLED=1 gh auth status >/dev/null 2>&1 || die 'GitHub CLI is not authenticated'

missing_required_sources=0
missing_required_destinations=0
missing_required_repository_variables=0
missing_optional_sources=0
missing_optional_destinations=0
unexpected_destinations=0
protection_errors=0

environment_selected() {
  local environment=$1
  if [[ "${mode}" == sync-repository-variables ]]; then
    [[ "${environment}" == postgres-ci-attestation ]]
    return
  fi
  [[ -z "${selected_environment}" || "${selected_environment}" == "${environment}" ]]
}

environment_destinations_in_scope() {
  [[ "${mode}" != sync-repository-variables ]]
}

repository_variables_in_scope() {
  [[ "${mode}" == sync-repository-variables || -z "${selected_environment}" || "${selected_environment}" == postgres-ci-attestation ]]
}

destination_expected() {
  local environment=$1 kind=$2 destination=$3
  awk -F '\t' -v environment="${environment}" -v kind="${kind}" -v destination="${destination}" \
    '$1 == environment && $2 == kind && $4 == destination { found = 1 } END { exit !found }' "${github_entries_file}"
}

repository_variable_expected() {
  local destination=$1
  awk -F '\t' -v destination="${destination}" \
    '$2 == destination { found = 1 } END { exit !found }' "${repository_entries_file}"
}

load_names_and_policy() {
  local repository_json environment kind output_file

  protection_errors=0
  find "${status_root}" -maxdepth 1 -type f -name 'github-environment-*.txt' -delete

  pass-cli item list --vault-name "${vault}" --filter-state active --output json |
    jq -er '.items | if type == "array" then . else error("invalid Proton item list") end | .[] | .title' |
    sort >"${proton_items_file}" || die 'could not read the Proton Pass item-name inventory'

  if ! repository_json=$(GH_PROMPT_DISABLED=1 gh api "repos/${repository}" 2>/dev/null) ||
    ! jq -e --arg repository "${repository}" '
      .full_name == $repository and .private == false and
      .visibility == "public" and .default_branch == "main" and
      .allow_forking == true and .archived == false and .disabled == false
    ' >/dev/null <<<"${repository_json}"; then
    printf 'REPOSITORY name=%s policy=invalid\n' "${repository}"
    ((protection_errors += 1))
  else
    printf 'REPOSITORY name=%s policy=public-active-main\n' "${repository}"
  fi

  GH_PROMPT_DISABLED=1 gh secret list --repo "${repository}" --json name --jq '.[].name' |
    sort >"${repository_secrets_file}" || die 'could not list repository-level secret names'
  GH_PROMPT_DISABLED=1 gh variable list --repo "${repository}" --json name --jq '.[].name' |
    sort >"${repository_variables_file}" || die 'could not list repository-level variable names'

  for environment in ${allowed_environments}; do
    environment_selected "${environment}" || continue
    if ! PYTHONDONTWRITEBYTECODE=1 GH_PROMPT_DISABLED=1 \
      python3 "${environment_policy_reconciler}" audit --environment "${environment}" >/dev/null 2>&1; then
      printf 'ENVIRONMENT name=%s protection=invalid-matrix\n' "${environment}"
      ((protection_errors += 1))
      continue
    fi
    printf 'ENVIRONMENT name=%s protection=exact-reviewed-matrix\n' "${environment}"

    for kind in secret variable; do
      output_file=${status_root}/github-environment-${environment}-${kind}.txt
      if [[ "${kind}" == secret ]]; then
        GH_PROMPT_DISABLED=1 gh secret list --repo "${repository}" --env "${environment}" \
          --json name --jq '.[].name' | sort >"${output_file}" || die "could not list ${environment} secret names"
      else
        GH_PROMPT_DISABLED=1 gh variable list --repo "${repository}" --env "${environment}" \
          --json name --jq '.[].name' | sort >"${output_file}" || die "could not list ${environment} variable names"
      fi
    done
  done
}

report_status() {
  local environment kind requirement destination item item_count destination_file status actual_name boundary field
  missing_required_sources=0
  missing_required_destinations=0
  missing_required_repository_variables=0
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
  done <"${selected_sources_file}"

  if environment_destinations_in_scope; then
    for index in "${!entry_environment[@]}"; do
      environment=${entry_environment[index]}
      kind=${entry_kind[index]}
      requirement=${entry_requirement[index]}
      destination=${entry_destination[index]}
      destination_file=${status_root}/github-environment-${environment}-${kind}.txt
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
  fi

  if environment_destinations_in_scope; then
    for environment in ${allowed_environments}; do
      environment_selected "${environment}" || continue
      for kind in secret variable; do
        destination_file=${status_root}/github-environment-${environment}-${kind}.txt
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
  fi

  if repository_variables_in_scope; then
    while IFS=$'\t' read -r requirement destination item field; do
      if grep -Fqx -- "${destination}" "${repository_variables_file}"; then
        status=present
      else
        status=missing
        if [[ "${requirement}" == required ]]; then
          ((missing_required_destinations += 1))
          ((missing_required_repository_variables += 1))
        else
          ((missing_optional_destinations += 1))
        fi
      fi
      printf 'REPOSITORY_DESTINATION kind=variable name=%s source=%s/%s requirement=%s status=%s\n' \
        "${destination}" "${item}" "${field}" "${requirement}" "${status}"
    done <"${repository_entries_file}"
  fi

  while IFS= read -r actual_name; do
    [[ -n "${actual_name}" ]] || continue
    printf 'UNEXPECTED_DESTINATION scope=repository kind=secret name=%s status=forbidden\n' "${actual_name}"
    ((unexpected_destinations += 1))
  done <"${repository_secrets_file}"

  while IFS= read -r actual_name; do
    [[ -n "${actual_name}" ]] || continue
    if ! repository_variable_expected "${actual_name}"; then
      printf 'UNEXPECTED_DESTINATION scope=repository kind=variable name=%s status=legacy-or-unmanaged\n' "${actual_name}"
      ((unexpected_destinations += 1))
    fi
  done <"${repository_variables_file}"

  if [[ -z "${selected_environment}" ]]; then
    while IFS=$'\t' read -r boundary requirement destination item field; do
      printf 'NON_GITHUB_DESTINATION boundary=%s name=%s source=%s/%s requirement=%s status=operator-managed\n' \
        "${boundary}" "${destination}" "${item}" "${field}" "${requirement}"
    done <"${non_github_entries_file}"
  fi

  printf 'SUMMARY required_source_issues=%d required_destination_missing=%d required_repository_variable_missing=%d optional_source_issues=%d optional_destination_missing=%d unexpected_destinations=%d protection_errors=%d\n' \
    "${missing_required_sources}" "${missing_required_destinations}" "${missing_required_repository_variables}" \
    "${missing_optional_sources}" "${missing_optional_destinations}" \
    "${unexpected_destinations}" "${protection_errors}"
}

load_names_and_policy
report_status

if [[ "${mode}" == check ]]; then
  if (( protection_errors > 0 || missing_required_sources > 0 || missing_required_destinations > 0 )); then
    exit 1
  fi
  if (( unexpected_destinations > 0 )); then
    exit 2
  fi
  exit 0
fi

(( protection_errors == 0 )) || die 'refusing to sync into an invalid repository or environment policy'
(( unexpected_destinations == 0 )) || die 'refusing to sync while forbidden, legacy, or unmanaged GitHub names remain'
(( missing_required_sources == 0 )) || die 'required Proton Pass source items are missing or ambiguous'
if [[ "${mode}" != sync-repository-variables ]]; then
  (( missing_required_repository_variables == 0 )) || die 'required public repository policy variables must be reconciled separately before sync'
fi
ulimit -c 0 || die 'could not disable process core dumps before handling credential values'

if [[ "${mode}" == sync-repository-variables ]]; then
  # Read and semantically validate every public trust anchor before the first
  # provider write. Values travel to the validator and GitHub only on stdin.
  for index in "${!repository_destination[@]}"; do
    item=${repository_item[index]}
    field=${repository_field[index]}
    destination=${repository_destination[index]}
    requirement=${repository_requirement[index]}
    value=
    if ! value=$(pass-cli item view --vault-name "${vault}" --item-title "${item}" --field "${field}" 2>/dev/null); then
      [[ "${requirement}" == optional ]] && continue
      die "required Proton repository-variable field is missing or unreadable: ${item}/${field}"
    fi
    [[ -n "${value}" ]] || die "required Proton repository-variable field is empty: ${item}/${field}"
    (( ${#value} <= max_value_bytes )) || die "Proton repository-variable field exceeds the bounded value size: ${item}/${field}"
    if ! printf '%s' "${value}" | python3 "${repository_anchor_validator}" "${destination}" >/dev/null; then
      unset value
      die "Proton repository-variable field failed semantic validation: ${item}/${field}"
    fi
    repository_source_values[index]=${value}
    unset value
    printf 'SOURCE_FIELD item=%s field=%s requirement=%s status=validated\n' \
      "${item}" "${field}" "${requirement}"
  done

  # Close the provider race without requiring the values to pre-exist.
  load_names_and_policy
  report_status
  (( protection_errors == 0 )) || die 'repository or attestation-environment protection changed during source preflight'
  (( unexpected_destinations == 0 )) || die 'a forbidden or unmanaged GitHub name appeared during source preflight'
  (( missing_required_sources == 0 )) || die 'a required Proton item disappeared during source preflight'

  for index in "${!repository_destination[@]}"; do
    destination=${repository_destination[index]}
    [[ -n "${repository_source_values[index]:-}" ]] || continue
    if ! printf '%s' "${repository_source_values[index]}" |
      GH_PROMPT_DISABLED=1 gh variable set "${destination}" --repo "${repository}" >/dev/null 2>&1; then
      die "GitHub rejected repository/variable/${destination}"
    fi
    readback=
    if ! readback=$(GH_PROMPT_DISABLED=1 gh variable get "${destination}" --repo "${repository}" --json value --jq '.value' 2>/dev/null); then
      die "GitHub repository-variable read-back failed: ${destination}"
    fi
    [[ "${readback}" == "${repository_source_values[index]}" ]] || \
      die "GitHub repository-variable read-back differed from Proton: ${destination}"
    unset readback
    printf 'SYNCED scope=repository kind=variable name=%s readback=exact\n' "${destination}"
  done

  load_names_and_policy
  report_status
  (( protection_errors == 0 && missing_required_repository_variables == 0 && unexpected_destinations == 0 )) || \
    die 'GitHub repository-variable name or policy read-back did not match the reviewed inventory'
  for index in "${!repository_destination[@]}"; do
    destination=${repository_destination[index]}
    [[ -n "${repository_source_values[index]:-}" ]] || continue
    readback=
    if ! readback=$(GH_PROMPT_DISABLED=1 gh variable get "${destination}" --repo "${repository}" --json value --jq '.value' 2>/dev/null); then
      die "GitHub final repository-variable read-back failed: ${destination}"
    fi
    [[ "${readback}" == "${repository_source_values[index]}" ]] || \
      die "GitHub final repository-variable read-back differed from Proton: ${destination}"
    unset readback 'repository_source_values[index]'
  done
  printf 'SYNC_COMPLETE repository=%s vault=%s scope=repository-variables count=%d\n' \
    "${repository}" "${vault}" "${#repository_destination[@]}"
  exit 0
fi

# Complete every selected source read before the first destination write.
for index in "${!entry_environment[@]}"; do
  item=${entry_item[index]}
  field=${entry_field[index]}
  requirement=${entry_requirement[index]}
  value=
  if ! value=$(pass-cli item view --vault-name "${vault}" --item-title "${item}" --field "${field}" 2>/dev/null); then
    if [[ "${requirement}" == optional ]]; then
      destination_file=${status_root}/github-environment-${entry_environment[index]}-${entry_kind[index]}.txt
      if [[ -f "${destination_file}" ]] && grep -Fqx -- "${entry_destination[index]}" "${destination_file}"; then
        die "optional Proton field is absent while its GitHub destination remains: ${item}/${field}"
      fi
      source_available[index]=0
      printf 'SOURCE_FIELD item=%s field=%s requirement=optional status=missing\n' "${item}" "${field}"
      continue
    fi
    die "required Proton field is missing or unreadable: ${item}/${field}"
  fi
  if [[ -z "${value}" ]]; then
    if [[ "${requirement}" == optional ]]; then
      destination_file=${status_root}/github-environment-${entry_environment[index]}-${entry_kind[index]}.txt
      if [[ -f "${destination_file}" ]] && grep -Fqx -- "${entry_destination[index]}" "${destination_file}"; then
        die "optional Proton field is empty while its GitHub destination remains: ${item}/${field}"
      fi
      source_available[index]=0
      printf 'SOURCE_FIELD item=%s field=%s requirement=optional status=empty\n' "${item}" "${field}"
      continue
    fi
    die "required Proton field is empty: ${item}/${field}"
  fi
  (( ${#value} <= max_value_bytes )) || die "Proton field exceeds GitHub's bounded value size: ${item}/${field}"
  source_values[index]=${value}
  source_available[index]=1
  unset value
done

# Close the useful provider race after all field reads and before any write.
load_names_and_policy
report_status
(( protection_errors == 0 )) || die 'repository or environment protection changed during source preflight'
(( unexpected_destinations == 0 )) || die 'a forbidden or unmanaged GitHub name appeared during source preflight'
(( missing_required_repository_variables == 0 )) || die 'a required repository policy variable disappeared during source preflight'

for index in "${!entry_environment[@]}"; do
  [[ "${source_available[index]:-0}" == 1 ]] || continue
  environment=${entry_environment[index]}
  kind=${entry_kind[index]}
  destination=${entry_destination[index]}
  if [[ "${kind}" == secret ]]; then
    if ! printf '%s' "${source_values[index]}" |
      GH_PROMPT_DISABLED=1 gh secret set "${destination}" --repo "${repository}" --env "${environment}" >/dev/null 2>&1; then
      die "GitHub rejected ${environment}/${kind}/${destination}"
    fi
  else
    if ! printf '%s' "${source_values[index]}" |
      GH_PROMPT_DISABLED=1 gh variable set "${destination}" --repo "${repository}" --env "${environment}" >/dev/null 2>&1; then
      die "GitHub rejected ${environment}/${kind}/${destination}"
    fi
  fi
  unset 'source_values[index]'
  printf 'SYNCED environment=%s kind=%s name=%s\n' "${environment}" "${kind}" "${destination}"
done

load_names_and_policy
report_status
(( protection_errors == 0 && missing_required_destinations == 0 && unexpected_destinations == 0 )) || \
  die 'GitHub destination read-back did not match the reviewed inventory'
printf 'SYNC_COMPLETE repository=%s vault=%s environment=%s\n' "${repository}" "${vault}" "${selected_environment}"
