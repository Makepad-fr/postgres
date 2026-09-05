#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# Trusted-hypervisor launcher for one Postgres PR job. It obtains a GitHub JIT
# configuration, boots a fresh self-contained VM, and destroys the VM, disk,
# registration seed, network, firewall, and runner registration. Only then does
# it sign and dispatch per-run evidence with the dedicated Launcher App.

readonly organization="Makepad-fr"
readonly runner_group="Postgres PR Ephemeral"
readonly runner_label="makepad-postgres-pr-ephemeral"
readonly api_version="2022-11-28"
script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
readonly script_directory

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || die "the JIT VM launcher must run as root on the dedicated CI hypervisor"
umask 077
for trusted_helper in ci-base-image.py dispatch-ci-attestation.mjs verify-postgres-ci-jit-result.py; do
  trusted_path="${script_directory}/${trusted_helper}"
  [[ -f "${trusted_path}" && ! -L "${trusted_path}" && $(stat -c '%u' "${trusted_path}") == 0 ]] || \
    die "trusted launcher helper is missing, symlinked, or not root-owned: ${trusted_helper}"
  trusted_mode=$(stat -c '%a' "${trusted_path}")
  (( (8#${trusted_mode} & 8#022) == 0 )) || die "trusted launcher helper is writable outside root: ${trusted_helper}"
done

job_root=${POSTGRES_CI_JOB_ROOT:-/var/lib/makepad/postgres-ci/jobs}
[[ "${job_root}" =~ ^/var/lib/makepad/postgres-ci/[A-Za-z0-9._/-]+$ && "${job_root}" != *..* ]] || die "POSTGRES_CI_JOB_ROOT is unsafe"

if [[ $# -eq 2 && "$1" == --reconcile ]]; then
  launch_id=$2
  [[ "${launch_id}" =~ ^j[1-9][0-9]{0,15}-[a-f0-9]{16}$ ]] || die "reconciliation launch ID is invalid"
  for command_name in gh nft sha256sum virsh; do
    command -v "${command_name}" >/dev/null || die "${command_name} is required for reconciliation"
  done
  IFS= read -r controller_token || die "a dedicated Launcher App installation token is required on standard input"
  [[ "${controller_token}" =~ ^ghs_[A-Za-z0-9_]+$ ]] || die "the Launcher App token has an invalid format"
  resource_hash=$(printf '%s' "${launch_id}" | sha256sum | cut -c1-10)
  temporary_directory="${job_root}/postgres-ci-jit-${launch_id}"
  vm_name="postgres-ci-${launch_id}"
  runner_name="postgres-ci-jit-${launch_id}"
  network_name="mdci-${launch_id}"
  nft_table="mdci_${resource_hash}"
  reconciliation_failed=false
  if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
    virsh destroy "${vm_name}" >/dev/null 2>&1 || true
    virsh undefine "${vm_name}" --nvram >/dev/null 2>&1 || virsh undefine "${vm_name}" >/dev/null 2>&1 || reconciliation_failed=true
  fi
  virsh dominfo "${vm_name}" >/dev/null 2>&1 && reconciliation_failed=true
  if nft list table inet "${nft_table}" >/dev/null 2>&1; then nft delete table inet "${nft_table}" >/dev/null 2>&1 || reconciliation_failed=true; fi
  nft list table inet "${nft_table}" >/dev/null 2>&1 && reconciliation_failed=true
  if virsh net-info "${network_name}" >/dev/null 2>&1; then
    virsh net-destroy "${network_name}" >/dev/null 2>&1 || true
    virsh net-undefine "${network_name}" >/dev/null 2>&1 || reconciliation_failed=true
  fi
  virsh net-info "${network_name}" >/dev/null 2>&1 && reconciliation_failed=true
  runner_ids=$(GH_TOKEN="${controller_token}" gh api --paginate \
    --header "X-GitHub-Api-Version: ${api_version}" \
    "orgs/${organization}/actions/runners?per_page=100" \
    --jq ".runners[] | select(.name == \"${runner_name}\") | .id" 2>/dev/null) || reconciliation_failed=true
  while IFS= read -r runner_id; do
    [[ -z "${runner_id}" ]] && continue
    [[ "${runner_id}" =~ ^[1-9][0-9]*$ ]] && GH_TOKEN="${controller_token}" gh api --method DELETE \
      --header "X-GitHub-Api-Version: ${api_version}" "orgs/${organization}/actions/runners/${runner_id}" >/dev/null 2>&1 \
      || reconciliation_failed=true
  done <<<"${runner_ids:-}"
  remaining=$(GH_TOKEN="${controller_token}" gh api --paginate \
    --header "X-GitHub-Api-Version: ${api_version}" \
    "orgs/${organization}/actions/runners?per_page=100" \
    --jq ".runners[] | select(.name == \"${runner_name}\") | .id" 2>/dev/null) || reconciliation_failed=true
  [[ -z "${remaining:-}" ]] || reconciliation_failed=true
  if [[ -e "${temporary_directory}" || -L "${temporary_directory}" ]]; then
    [[ -d "${temporary_directory}" && ! -L "${temporary_directory}" && "$(stat -c '%u:%a' "${temporary_directory}")" == 0:700 ]] || die "reconciliation work directory is unsafe"
    find "${temporary_directory}" -depth -mindepth 1 -delete
    rmdir -- "${temporary_directory}" || reconciliation_failed=true
  fi
  unset controller_token
  [[ "${reconciliation_failed}" == false ]] || die "incomplete JIT launch could not be fully reconciled"
  printf 'Reconciled incomplete disposable launch %s.\n' "${launch_id}"
  exit 0
fi

[[ $# -eq 0 ]] || die "usage: set exact POSTGRES_CI_RUN_* metadata and stream a Launcher App installation token on stdin"
[[ "$(uname -m)" == x86_64 ]] || die "the Postgres JIT base image and workflow require an x86_64 hypervisor"
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || die "hardware-backed KVM is required for the one-job runner VM"
for command_name in cksum cloud-localds flock gh ip lsattr mktemp nft node python3 qemu-img seq sha256sum virsh virt-install; do
  command -v "${command_name}" >/dev/null || die "${command_name} is required"
done

base_image=${POSTGRES_CI_BASE_IMAGE:-}
expected_image_sha256=${POSTGRES_CI_BASE_IMAGE_SHA256:-}
public_dns=${POSTGRES_CI_PUBLIC_DNS_IPV4:-1.1.1.1}
run_id=${POSTGRES_CI_RUN_ID:-}
run_attempt=${POSTGRES_CI_RUN_ATTEMPT:-}
job_id=${POSTGRES_CI_JOB_ID:-}
run_event=${POSTGRES_CI_RUN_EVENT:-}
head_sha=${POSTGRES_CI_HEAD_SHA:-}
workflow_sha=${POSTGRES_CI_WORKFLOW_SHA:-}
attestation_nonce=${POSTGRES_CI_ATTESTATION_NONCE:-}
launch_id=${POSTGRES_CI_LAUNCH_ID:-}
attestation_private_key=${POSTGRES_CI_ATTESTATION_PRIVATE_KEY_FILE:-}
result_poll_attempts=${POSTGRES_CI_RESULT_POLL_ATTEMPTS:-24}
result_poll_seconds=${POSTGRES_CI_RESULT_POLL_SECONDS:-5}
[[ "${run_id}" =~ ^[1-9][0-9]*$ && "${run_attempt}" =~ ^[1-9][0-9]*$ && "${job_id}" =~ ^[1-9][0-9]*$ ]] || die "exact positive run, attempt, and job IDs are required"
[[ "${run_event}" == pull_request_target || "${run_event}" == push ]] || die "POSTGRES_CI_RUN_EVENT must be pull_request_target or push"
[[ "${head_sha}" =~ ^[a-f0-9]{40}$ ]] || die "POSTGRES_CI_HEAD_SHA must be the exact lowercase source SHA"
[[ "${workflow_sha}" =~ ^[a-f0-9]{40}$ ]] || die "POSTGRES_CI_WORKFLOW_SHA must be the protected workflow execution SHA"
if [[ "${run_event}" == push && "${head_sha}" != "${workflow_sha}" ]]; then
  die "protected-main push source and workflow SHAs must be identical"
fi
[[ "${attestation_nonce}" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "POSTGRES_CI_ATTESTATION_NONCE must be 32 random base64url bytes"
[[ "${launch_id}" =~ ^j[1-9][0-9]{0,15}-[a-f0-9]{16}$ && "${launch_id}" == "j${job_id}-"* ]] || die "POSTGRES_CI_LAUNCH_ID must bind the exact job to a deterministic resource set"
[[ "${result_poll_attempts}" =~ ^[1-9][0-9]*$ && "${result_poll_seconds}" =~ ^[0-9]+$ ]] || die "result polling controls must be non-negative integers"
((result_poll_attempts <= 60 && result_poll_seconds <= 30)) || die "result polling controls exceed the reviewed safety bound"
[[ "${attestation_private_key}" == /* && -f "${attestation_private_key}" && ! -L "${attestation_private_key}" ]] || die "a regular absolute Ed25519 attestation private-key file is required"
[[ "$(stat -c '%u:%a' "${attestation_private_key}")" == "0:400" ]] || die "the attestation private key must be root-owned mode 0400"
[[ "${base_image}" == /* && -f "${base_image}" && ! -L "${base_image}" ]] || die "POSTGRES_CI_BASE_IMAGE must be an absolute regular file"
[[ "${expected_image_sha256}" =~ ^[a-f0-9]{64}$ ]] || die "POSTGRES_CI_BASE_IMAGE_SHA256 must be a lowercase SHA-256 digest"
[[ "$(stat -c '%u' "${base_image}")" == 0 ]] || die "the base image must be owned by root"
base_mode=$(stat -c '%a' "${base_image}")
(( (8#${base_mode} & 8#022) == 0 )) || die "the base image must not be group- or world-writable"
python3 - "${base_image}" <<'PY'
import os
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
for component in [pathlib.Path("/")] + list(reversed(path.parents[:-1])) + [path]:
    value = os.lstat(component)
    if stat.S_ISLNK(value.st_mode) or value.st_uid != 0 or value.st_mode & 0o022:
        raise SystemExit(f"insecure base-image path component: {component}")
PY
attributes=$(lsattr -d -- "${base_image}" 2>/dev/null | awk '{print $1}')
[[ "${attributes}" == *i* ]] || die "the reviewed base image must have the filesystem immutable attribute"
python3 "${script_directory}/ci-base-image.py" "${base_image}" "${expected_image_sha256}" >/dev/null || die "the trusted base-image digest does not match"
qemu-img info --output=json "${base_image}" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
size = payload.get("virtual-size")
if payload.get("format") != "qcow2" or payload.get("backing-filename") or payload.get("data-file") or not isinstance(size, int) or not 8 * 1024**3 <= size <= 64 * 1024**3:
    raise SystemExit("trusted base image must be qcow2 with an 8-64 GiB virtual disk")
'
python3 - "${public_dns}" <<'PY'
import ipaddress
import sys

address = ipaddress.ip_address(sys.argv[1])
if address.version != 4 or not address.is_global:
    raise SystemExit("POSTGRES_CI_PUBLIC_DNS_IPV4 must be a globally routable IPv4 address")
PY

IFS= read -r controller_token || die "a dedicated Launcher App installation token is required on standard input"
[[ "${controller_token}" =~ ^ghs_[A-Za-z0-9_]+$ ]] || die "the Launcher App token has an invalid format"

install -d -m 0700 -o root -g root "${job_root}"
[[ -d "${job_root}" && ! -L "${job_root}" && "$(stat -c '%u:%a' "${job_root}")" == 0:700 ]]
temporary_directory="${job_root}/postgres-ci-jit-${launch_id}"
[[ ! -e "${temporary_directory}" && ! -L "${temporary_directory}" ]] || die "deterministic JIT resource directory already exists"
install -d -m 0700 -o root -g root "${temporary_directory}"
resource_hash=$(printf '%s' "${launch_id}" | sha256sum | cut -c1-10)
vm_name="postgres-ci-${launch_id}"
runner_name="postgres-ci-jit-${launch_id}"
network_name="mdci-${launch_id}"
bridge_name="md${resource_hash}"
nft_table="mdci_${resource_hash}"
overlay_path="${temporary_directory}/runner.qcow2"
seed_path="${temporary_directory}/seed.iso"
network_xml="${temporary_directory}/network.xml"
user_data="${temporary_directory}/user-data"
meta_data="${temporary_directory}/meta-data"
network_started=false
domain_defined=false
nft_created=false
jit_runner_id=""
attestation_eligible=false

write_resource_manifest() {
  local registered_id=${1:-} incoming="${temporary_directory}/.resources.json.incoming"
  python3 - "${incoming}" "${launch_id}" "${job_id}" "${vm_name}" "${runner_name}" "${network_name}" "${bridge_name}" "${nft_table}" "${registered_id}" <<'PY'
import json, pathlib, sys
runner_id = int(sys.argv[9]) if sys.argv[9] else None
payload = {"version":1,"launch_id":sys.argv[2],"job_id":int(sys.argv[3]),"vm":sys.argv[4],"runner":sys.argv[5],"network":sys.argv[6],"bridge":sys.argv[7],"nft_table":sys.argv[8],"runner_id":runner_id}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
PY
  chmod 0600 "${incoming}"
  mv -fT "${incoming}" "${temporary_directory}/resources.json"
  sync -f "${temporary_directory}" 2>/dev/null || sync
}
write_resource_manifest

cleanup() {
  local original_status=$?
  local cleanup_failed=false
  local retain_vm_files=false
  local job_conclusion=""
  trap - EXIT INT TERM HUP
  unset encoded_jit_config
  set +e
  if [[ "${domain_defined}" == true ]]; then
    virsh destroy "${vm_name}" >/dev/null 2>&1
    virsh undefine "${vm_name}" --nvram >/dev/null 2>&1 || virsh undefine "${vm_name}" >/dev/null 2>&1
    if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
      printf 'Failed to destroy and undefine ephemeral runner VM %s.\n' "${vm_name}" >&2
      cleanup_failed=true
      retain_vm_files=true
    fi
  fi
  if [[ "${nft_created}" == true ]]; then
    nft delete table inet "${nft_table}" >/dev/null 2>&1
    if nft list table inet "${nft_table}" >/dev/null 2>&1; then
      printf 'Failed to remove ephemeral runner firewall table %s.\n' "${nft_table}" >&2
      cleanup_failed=true
    fi
  fi
  if [[ "${network_started}" == true ]]; then
    virsh net-destroy "${network_name}" >/dev/null 2>&1
    virsh net-undefine "${network_name}" >/dev/null 2>&1
    if virsh net-info "${network_name}" >/dev/null 2>&1; then
      printf 'Failed to remove ephemeral runner network %s.\n' "${network_name}" >&2
      cleanup_failed=true
    fi
  fi
  if [[ -n "${controller_token:-}" && -n "${runner_name:-}" ]]; then
    runner_ids=$(GH_TOKEN="${controller_token}" gh api --paginate \
      --header "X-GitHub-Api-Version: ${api_version}" \
      "orgs/${organization}/actions/runners?per_page=100" \
      --jq ".runners[] | select(.name == \"${runner_name}\") | .id" 2>/dev/null)
    lookup_status=$?
    if [[ "${lookup_status}" -ne 0 ]]; then
      printf 'Failed to inspect the JIT runner registration during teardown.\n' >&2
      cleanup_failed=true
    else
      while IFS= read -r runner_id; do
        [[ -z "${runner_id}" ]] && continue
        if [[ ! "${runner_id}" =~ ^[1-9][0-9]*$ || ( -n "${jit_runner_id}" && "${runner_id}" != "${jit_runner_id}" ) ]] || \
          ! GH_TOKEN="${controller_token}" gh api --method DELETE \
          --header "X-GitHub-Api-Version: ${api_version}" \
          "orgs/${organization}/actions/runners/${runner_id}" >/dev/null 2>&1; then
          printf 'Failed to remove JIT runner registration %s.\n' "${runner_id}" >&2
          cleanup_failed=true
        fi
      done <<<"${runner_ids}"
      remaining_runner_ids=$(GH_TOKEN="${controller_token}" gh api --paginate \
        --header "X-GitHub-Api-Version: ${api_version}" \
        "orgs/${organization}/actions/runners?per_page=100" \
        --jq ".runners[] | select(.name == \"${runner_name}\") | .id" 2>/dev/null)
      remaining_status=$?
      if [[ "${remaining_status}" -ne 0 || -n "${remaining_runner_ids}" ]]; then
        printf 'JIT runner registration removal could not be verified.\n' >&2
        cleanup_failed=true
      fi
    fi
  fi
  if [[ "${retain_vm_files}" == false ]]; then
    if [[ -d "${temporary_directory}" && ! -L "${temporary_directory}" && "${temporary_directory}" == "${job_root}"/postgres-ci-jit-* ]]; then
      find "${temporary_directory}" -depth -mindepth 1 -delete
      rmdir -- "${temporary_directory}"
      if [[ -e "${temporary_directory}" || -L "${temporary_directory}" ]]; then
        cleanup_failed=true
      fi
    else
      cleanup_failed=true
    fi
  fi
  if [[ "${cleanup_failed}" == true ]]; then
    printf 'Ephemeral CI teardown is incomplete; inspect the hypervisor alert immediately.\n' >&2
    if [[ "${retain_vm_files}" == true ]]; then
      printf 'VM files are quarantined at %s until the domain is destroyed.\n' "${temporary_directory}" >&2
    fi
    original_status=1
  fi
  if [[ "${attestation_eligible}" == true && "${cleanup_failed}" == false ]]; then
    # The VM has stopped and every hypervisor resource plus GitHub registration
    # has been independently shown absent. Now bind the authoritative job result
    # to that teardown before the hypervisor-only Ed25519 key signs anything.
    run_payload_file=$(mktemp /run/postgres-ci-run-XXXXXXXX.json)
    jobs_payload_file=$(mktemp /run/postgres-ci-jobs-XXXXXXXX.json)
    chmod 0600 "${run_payload_file}" "${jobs_payload_file}"
    completed_payload=false
    for poll_attempt in $(seq 1 "${result_poll_attempts}"); do
      if GH_TOKEN="${controller_token}" gh api \
        --header "X-GitHub-Api-Version: ${api_version}" \
        "repos/${organization}/postgres/actions/runs/${run_id}" >"${run_payload_file}" 2>/dev/null && \
        GH_TOKEN="${controller_token}" gh api \
        --header "X-GitHub-Api-Version: ${api_version}" \
        "repos/${organization}/postgres/actions/runs/${run_id}/attempts/${run_attempt}/jobs?per_page=100" \
        >"${jobs_payload_file}" 2>/dev/null && \
        python3 - "${run_payload_file}" "${jobs_payload_file}" "${job_id}" <<'PY'
import json, pathlib, sys
run=json.loads(pathlib.Path(sys.argv[1]).read_text()); response=json.loads(pathlib.Path(sys.argv[2]).read_text()); jobs=response.get("jobs", [])
if not isinstance(jobs, list) or response.get("total_count") != len(jobs): raise SystemExit(1)
matches=[job for job in jobs if job.get("id") == int(sys.argv[3])]
raise SystemExit(0 if run.get("status") == "completed" and len(matches) == 1 and matches[0].get("status") == "completed" else 1)
PY
      then
        completed_payload=true
        break
      fi
      if ((poll_attempt < result_poll_attempts && result_poll_seconds > 0)); then sleep "${result_poll_seconds}"; fi
    done
    if [[ "${completed_payload}" != true ]]; then
      printf 'Authoritative workflow state did not converge before the bounded attestation deadline.\n' >&2
      cleanup_failed=true
      original_status=1
    fi
    if [[ "${cleanup_failed}" == false ]]; then
      job_conclusion=$(python3 "${script_directory}/verify-postgres-ci-jit-result.py" \
        "${run_payload_file}" "${jobs_payload_file}" "${run_id}" "${run_attempt}" \
        "${job_id}" "${run_event}" "${head_sha}" "${workflow_sha}" "${jit_runner_id}" \
        "${runner_name}" "${runner_group_id}")
    fi
    rm -f -- "${run_payload_file}" "${jobs_payload_file}" || {
      cleanup_failed=true
      original_status=1
    }
    if [[ "${job_conclusion}" != success && "${job_conclusion}" != failure ]]; then
      printf 'Unable to bind authoritative job conclusion to teardown.\n' >&2
      cleanup_failed=true
      original_status=1
    else
      attestation_file=$(mktemp /run/postgres-ci-attestation-XXXXXXXX.json)
      chmod 0600 "${attestation_file}"
      python3 - "${attestation_file}" "${run_id}" "${run_attempt}" "${job_id}" "${run_event}" \
        "${head_sha}" "${workflow_sha}" "${job_conclusion}" "${jit_runner_id}" "${runner_name}" \
        "${runner_group_id}" "${runner_group}" "${runner_label}" "${expected_image_sha256}" \
        "${attestation_nonce}" <<'PY'
import datetime
import json
import pathlib
import sys

payload = {
    "base_image_sha256": sys.argv[14],
    "issued_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "nonce": sys.argv[15],
    "ref": "refs/heads/main",
    "registration_absent": True,
    "repository": "Makepad-fr/postgres",
    "run": {
        "attempt": int(sys.argv[3]),
        "conclusion": sys.argv[8],
        "event": sys.argv[5],
        "head_sha": sys.argv[6],
        "id": int(sys.argv[2]),
        "job_id": int(sys.argv[4]),
        "job_name": "policy-and-integration",
        "workflow_sha": sys.argv[7],
    },
    "runner": {
        "group_id": int(sys.argv[11]),
        "group_name": sys.argv[12],
        "id": int(sys.argv[9]),
        "labels": ["self-hosted", "linux", "x64", sys.argv[13]],
        "name": sys.argv[10],
    },
    "schema": "makepad.postgres.ci-attestation.v1",
    "teardown": {"disk": True, "firewall": True, "network": True, "vm": True},
    "workflow": {"name": "CI", "path": ".github/workflows/ci.yml"},
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
      if ! printf '%s\n' "${controller_token}" | \
        POSTGRES_CI_ATTESTATION_JSON_FILE="${attestation_file}" \
        POSTGRES_CI_ATTESTATION_PRIVATE_KEY_FILE="${attestation_private_key}" \
        node "${script_directory}/dispatch-ci-attestation.mjs"; then
        printf 'Signed teardown evidence could not be dispatched by the Launcher App.\n' >&2
        cleanup_failed=true
        original_status=1
      fi
      rm -f -- "${attestation_file}" || {
        printf 'Could not remove transient attestation material.\n' >&2
        cleanup_failed=true
        original_status=1
      }
    fi
  fi
  unset controller_token
  if [[ "${cleanup_failed}" == true ]]; then
    printf 'The queue supervisor must raise an independent launcher failure alert.\n' >&2
  fi
  exit "${original_status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

group_payload="${temporary_directory}/runner-groups.json"
GH_TOKEN="${controller_token}" gh api --header "X-GitHub-Api-Version: ${api_version}" \
  "orgs/${organization}/actions/runner-groups?per_page=100" >"${group_payload}"
runner_group_id=$(python3 - "${group_payload}" "${runner_group}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
groups = payload.get("runner_groups", [])
if payload.get("total_count", len(groups)) > len(groups):
    raise SystemExit("more than 100 runner groups require explicit pagination")
matches = [item for item in groups if item.get("name") == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit("the exact Postgres PR Ephemeral runner group does not exist uniquely")
print(matches[0]["id"])
PY
)
[[ "${runner_group_id}" =~ ^[1-9][0-9]*$ ]] || die "runner group ID is invalid"

group_details="${temporary_directory}/runner-group.json"
group_repositories="${temporary_directory}/runner-group-repositories.json"
repository_payload="${temporary_directory}/repository.json"
GH_TOKEN="${controller_token}" gh api --header "X-GitHub-Api-Version: ${api_version}" \
  "orgs/${organization}/actions/runner-groups/${runner_group_id}" >"${group_details}"
GH_TOKEN="${controller_token}" gh api --header "X-GitHub-Api-Version: ${api_version}" \
  "orgs/${organization}/actions/runner-groups/${runner_group_id}/repositories?per_page=100" >"${group_repositories}"
GH_TOKEN="${controller_token}" gh api --header "X-GitHub-Api-Version: ${api_version}" \
  "repos/${organization}/postgres" >"${repository_payload}"
python3 - "${group_details}" "${group_repositories}" "${repository_payload}" <<'PY'
import json
import pathlib
import sys

group = json.loads(pathlib.Path(sys.argv[1]).read_text())
repository_selection = json.loads(pathlib.Path(sys.argv[2]).read_text())
repository = json.loads(pathlib.Path(sys.argv[3]).read_text())
selected = repository_selection.get("repositories", [])
expected_workflows = {
    "Makepad-fr/postgres/.github/workflows/ci.yml@refs/heads/main",
    "Makepad-fr/postgres/.github/workflows/pr-ci-result.yml@refs/heads/main",
}
if (
    group.get("name") != "Postgres PR Ephemeral"
    or group.get("visibility") != "selected"
    or group.get("allows_public_repositories") is not True
    or group.get("restricted_to_workflows") is not True
    or group.get("workflow_restrictions_read_only") is not False
    or set(group.get("selected_workflows", [])) != expected_workflows
):
    raise SystemExit("Postgres PR Ephemeral runner group is not restricted to the exact protected workflows")
if repository_selection.get("total_count", len(selected)) > len(selected):
    raise SystemExit("runner-group repository selection is truncated")
if (
    repository.get("full_name") != "Makepad-fr/postgres"
    or repository.get("private") is not False
    or not isinstance(repository.get("id"), int)
    or [item.get("id") for item in selected] != [repository["id"]]
):
    raise SystemExit("Postgres PR Ephemeral runner group is not restricted to the public PostgreSQL repository")
PY

jit_request="${temporary_directory}/jit-request.json"
jit_response="${temporary_directory}/jit-response.json"
python3 - "${runner_name}" "${runner_group_id}" "${runner_label}" >"${jit_request}" <<'PY'
import json
import sys

print(json.dumps({
    "name": sys.argv[1],
    "runner_group_id": int(sys.argv[2]),
    "work_folder": "_work",
    "labels": ["self-hosted", "Linux", "X64", sys.argv[3]],
}, separators=(",", ":")))
PY
chmod 0600 "${jit_request}"
GH_TOKEN="${controller_token}" gh api --method POST --header "X-GitHub-Api-Version: ${api_version}" \
  "orgs/${organization}/actions/runners/generate-jitconfig" \
  --input "${jit_request}" >"${jit_response}"
jit_runner_id=$(python3 - "${jit_response}" "${runner_name}" "${runner_label}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
runner = payload.get("runner", {})
runner_id = runner.get("id")
labels = {
    str(item.get("name", "")).lower()
    for item in runner.get("labels", [])
    if isinstance(item, dict)
}
if (
    not isinstance(runner_id, int)
    or runner_id <= 0
    or runner.get("name") != sys.argv[2]
    or runner.get("status") != "offline"
    or not {"self-hosted", "linux", "x64", sys.argv[3]}.issubset(labels)
):
    raise SystemExit("GitHub returned an invalid JIT runner identity")
print(runner_id)
PY
)
write_resource_manifest "${jit_runner_id}"
encoded_jit_config=$(python3 - "${jit_response}" <<'PY'
import json
import pathlib
import re
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text()).get("encoded_jit_config", "")
if not re.fullmatch(r"[A-Za-z0-9_+/\-]{40,8192}={0,2}", value):
    raise SystemExit("GitHub returned an invalid JIT configuration")
print(value)
PY
)

# A fresh libvirt network is created for every VM. Its host-side nftables hook
# blocks private, WireGuard, link-local/metadata, multicast, every hypervisor
# address, and all egress except public DNS plus TLS. Guest root cannot remove
# these hypervisor rules.
exec 8>/run/lock/postgres-ci-network.lock
flock -x 8
suffix_checksum=$(printf '%s' "${launch_id}" | cksum)
suffix_checksum=${suffix_checksum%% *}
subnet=""
for offset in $(seq 0 199); do
  network_octet=$(((suffix_checksum + offset) % 200 + 20))
  candidate="172.31.${network_octet}"
  if [[ -z "$(ip -4 route show exact "${candidate}.0/24")" ]]; then
    subnet="${candidate}"
    break
  fi
done
[[ -n "${subnet}" ]] || die "no unused ephemeral runner subnet is available"
cat >"${network_xml}" <<EOF
<network>
  <name>${network_name}</name>
  <forward mode='nat'/>
  <bridge name='${bridge_name}' stp='off' delay='0'/>
  <dns enable='no'/>
  <ip address='${subnet}.1' netmask='255.255.255.0'>
    <dhcp><range start='${subnet}.10' end='${subnet}.20'/></dhcp>
  </ip>
</network>
EOF
chmod 0600 "${network_xml}"
virsh net-define "${network_xml}" >/dev/null
network_started=true
virsh net-start "${network_name}" >/dev/null
flock -u 8

nft_created=true
nft -f - <<EOF
table inet ${nft_table} {
  set denied4 {
    type ipv4_addr
    flags interval
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4 }
  }
  chain input {
    type filter hook input priority -200; policy accept;
    iifname "${bridge_name}" udp sport 68 udp dport 67 accept
    iifname "${bridge_name}" drop
  }
  chain forward {
    type filter hook forward priority -200; policy accept;
    iifname "${bridge_name}" ct state established,related accept
    iifname "${bridge_name}" ip daddr @denied4 drop
    iifname "${bridge_name}" meta nfproto ipv6 drop
    iifname "${bridge_name}" ip daddr ${public_dns} udp dport 53 accept
    iifname "${bridge_name}" ip daddr ${public_dns} tcp dport 53 accept
    iifname "${bridge_name}" tcp dport 443 accept
    iifname "${bridge_name}" drop
  }
}
EOF

while IFS= read -r host_address; do
  [[ -z "${host_address}" ]] || nft insert rule inet "${nft_table}" forward \
    iifname "${bridge_name}" ip daddr "${host_address}" drop
done < <(ip -j -4 address show | python3 -c '
import ipaddress, json, sys
for interface in json.load(sys.stdin):
    for value in interface.get("addr_info", []):
        address = value.get("local", "")
        try:
            parsed = ipaddress.ip_address(address)
        except ValueError:
            continue
        if parsed.version == 4:
            print(parsed)
')

# Each job receives a full qcow2 copy. Backing/data chains could make later
# mutation of an ostensibly approved base affect the running guest.
qemu-img convert -q -f qcow2 -O qcow2 "${base_image}" "${overlay_path}"
chmod 0600 "${overlay_path}"
qemu-img info --output=json "${overlay_path}" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
if payload.get("format") != "qcow2" or payload.get("backing-filename") or payload.get("data-file"):
    raise SystemExit("per-job disk must be a self-contained qcow2 without backing or data files")
'
python3 "${script_directory}/ci-base-image.py" "${base_image}" "${expected_image_sha256}" >/dev/null || die "base image mutated while the self-contained job disk was created"

guest_script=$(cat <<'GUEST'
#!/usr/bin/env bash
set -euo pipefail
power_off() {
  local status=$?
  trap - EXIT
  find /run/postgres-jit -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir /run/postgres-jit 2>/dev/null || true
  systemctl poweroff --no-block
  exit "${status}"
}
trap power_off EXIT
[[ -x /opt/actions-runner/run.sh ]]
[[ -f /run/postgres-jit/config && ! -L /run/postgres-jit/config ]]
jit_config=$(</run/postgres-jit/config)
[[ -n "${jit_config}" ]]
# generate-jitconfig is the GitHub-supported one-job/--ephemeral registration;
# its sealed configuration already enforces at-most-one-job semantics, and the
# documented runner invocation accepts it only through --jitconfig.
cd /opt/actions-runner
sudo -u actions-runner ./run.sh --jitconfig "${jit_config}"
GUEST
)
JIT_CONFIG="${encoded_jit_config}" GUEST_SCRIPT="${guest_script}" PUBLIC_DNS="${public_dns}" \
  python3 - "${user_data}" <<'PY'
import base64
import os
import pathlib
import sys

def encoded(value):
    return base64.b64encode(value.encode()).decode()

content = f"""#cloud-config
manage_resolv_conf: true
resolv_conf:
  nameservers: [{os.environ['PUBLIC_DNS']}]
  options: {{rotate: true, timeout: 1}}
write_files:
  - path: /run/postgres-jit/config
    owner: root:root
    permissions: '0600'
    encoding: b64
    content: {encoded(os.environ['JIT_CONFIG'])}
  - path: /usr/local/sbin/run-postgres-jit
    owner: root:root
    permissions: '0700'
    encoding: b64
    content: {encoded(os.environ['GUEST_SCRIPT'])}
runcmd:
  - [/usr/local/sbin/run-postgres-jit]
"""
pathlib.Path(sys.argv[1]).write_text(content)
PY
unset encoded_jit_config guest_script
printf 'instance-id: %s\nlocal-hostname: %s\n' "${vm_name}" "${vm_name}" >"${meta_data}"
chmod 0600 "${user_data}" "${meta_data}"
cloud-localds "${seed_path}" "${user_data}" "${meta_data}"
chmod 0600 "${seed_path}"

domain_defined=true
virt-install \
  --name "${vm_name}" \
  --virt-type kvm \
  --memory 6144 \
  --vcpus 4 \
  --import \
  --osinfo detect=on,require=off \
  --disk "path=${overlay_path},format=qcow2,bus=virtio,cache=none" \
  --disk "path=${seed_path},device=cdrom,readonly=on" \
  --network "network=${network_name},model=virtio" \
  --graphics none \
  --noautoconsole >/dev/null

deadline=$((SECONDS + 2700))
while (( SECONDS < deadline )); do
  state=$(virsh domstate "${vm_name}" 2>/dev/null || true)
  case "${state}" in
    "shut off"|"crashed") break ;;
  esac
  sleep 5
done
state=$(virsh domstate "${vm_name}" 2>/dev/null || true)
[[ "${state}" == "shut off" ]] || die "the one-job runner did not shut down within 45 minutes"
attestation_eligible=true
printf 'One-job JIT VM %s stopped; destroying all ephemeral state.\n' "${vm_name}"
