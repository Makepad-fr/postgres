#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
set -f

helper=/usr/local/libexec/makepad/capture-keycloak-cohort-backups
cleaner=/usr/local/libexec/makepad/clean-keycloak-cohort-resources
command_text=${SSH_ORIGINAL_COMMAND:-}
read -r -a words <<<"${command_text}"
[[ ${#words[@]} -ge 3 ]] || { echo "A constrained cohort capture command is required." >&2; exit 2; }
operation=${words[0]}
helper_digest=${words[${#words[@]}-2]}
cleaner_digest=${words[${#words[@]}-1]}
[[ "${helper_digest}" =~ ^[a-f0-9]{64}$ && "${cleaner_digest}" =~ ^[a-f0-9]{64}$ ]] || {
  echo "The reviewed capture-helper and cleaner digests are required." >&2
  exit 2
}
[[ -x "${helper}" && ! -L "${helper}" && -x "${cleaner}" && ! -L "${cleaner}" ]] || { echo "The root-owned cohort capture contract is not installed." >&2; exit 1; }
[[ $(sha256sum "${helper}" | cut -d' ' -f1) == "${helper_digest}" ]] || { echo "The installed capture helper differs from the reviewed release." >&2; exit 1; }
[[ $(sha256sum "${cleaner}" | cut -d' ' -f1) == "${cleaner_digest}" ]] || { echo "The installed cohort cleaner differs from the reviewed release." >&2; exit 1; }
systemctl is-enabled --quiet makepad-keycloak-cohort-cleaner.timer
systemctl is-active --quiet makepad-keycloak-cohort-cleaner.timer
[[ $(systemctl show --property=Result --value makepad-keycloak-cohort-cleaner.service) == success ]]
[[ $(systemctl show --property=ExecMainStatus --value makepad-keycloak-cohort-cleaner.service) == 0 ]]

validate_run() {
  [[ "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid cohort run identity." >&2; exit 2; }
  cohort_dir="/tmp/postgres-keycloak-cohort-$1-$2"
}

case "${operation}" in
  probe)
    [[ ${#words[@]} -eq 3 ]]
    printf 'cohort-capture-contract-ok\n'
    ;;
  capture)
    [[ ${#words[@]} -eq 5 ]]
    validate_run "${words[1]}" "${words[2]}"
    COHORT_CAPTURE_RUN_ID=${words[1]} COHORT_CAPTURE_RUN_ATTEMPT=${words[2]} \
      "${helper}" "${cohort_dir}"
    ;;
  fetch)
    [[ ${#words[@]} -eq 6 ]]
    validate_run "${words[1]}" "${words[2]}"
    file=${words[3]}
    case "${file}" in
      keycloak_catwlk.dump|keycloak_makepad.dump|keycloak_runtrace.dump|keycloak_vestiaire.dump|keycloak_vif.dump) ;;
      *) echo "Unsupported cohort artifact." >&2; exit 2 ;;
    esac
    [[ -f "${cohort_dir}/${file}" && ! -L "${cohort_dir}/${file}" && -s "${cohort_dir}/${file}" ]] || exit 1
    exec cat "${cohort_dir}/${file}"
    ;;
  cleanup)
    [[ ${#words[@]} -eq 5 ]]
    validate_run "${words[1]}" "${words[2]}"
    if [[ -d "${cohort_dir}" && ! -L "${cohort_dir}" ]]; then
      find "${cohort_dir}" -depth -delete
    elif [[ -e "${cohort_dir}" || -L "${cohort_dir}" ]]; then
      echo "Refusing unsafe cohort cleanup target." >&2
      exit 1
    fi
    ;;
  *) echo "Unsupported constrained cohort capture operation." >&2; exit 2 ;;
esac
