#!/usr/bin/env bash
set -Eeuo pipefail

readonly observer_user=brio-runtime-observer
readonly observer_home=/var/lib/brio-runtime-observer
readonly observer_command=/usr/local/libexec/makepad/brio-postgres-runtime-observe
readonly control_command=/usr/local/libexec/makepad/brio-postgres-control-receipt
readonly sudoers_path=/etc/sudoers.d/brio-postgres-runtime-observer

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

(( EUID == 0 )) || die 'Run this installer as root on the PostgreSQL host.'
[[ $# == 3 ]] || die 'usage: install-brio-runtime-observer.sh OBSERVER_SCRIPT CONTROL_HELPER ED25519_PUBLIC_KEY_FILE'
source_script=$1
control_source=$2
public_key_file=$3
[[ -f "${source_script}" && ! -L "${source_script}" ]] || die 'Observer source must be a regular file.'
[[ -f "${control_source}" && ! -L "${control_source}" ]] || die 'Control-helper source must be a regular file.'
[[ -f "${public_key_file}" && ! -L "${public_key_file}" ]] || die 'Observer public key must be a regular file.'

read -r key_type key_body key_extra < "${public_key_file}"
[[ "${key_type}" == ssh-ed25519 && "${key_body}" =~ ^[A-Za-z0-9+/]+={0,3}$ && -z "${key_extra:-}" ]] || \
  die 'Expected exactly one OpenSSH Ed25519 public key without trailing fields.'
[[ $(wc -l < "${public_key_file}") -eq 1 ]] || die 'Observer public key file must contain exactly one line.'

if ! id "${observer_user}" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "${observer_home}" --shell /bin/bash "${observer_user}"
fi
[[ "$(id -u -n "${observer_user}")" == "${observer_user}" ]] || die 'Observer account could not be verified.'
passwd --lock "${observer_user}" >/dev/null

install -d -o root -g root -m 0755 /usr/local/libexec /usr/local/libexec/makepad
install -o root -g root -m 0755 "${source_script}" "${observer_command}"
install -o root -g root -m 0755 "${control_source}" "${control_command}"
install -d -o "${observer_user}" -g "${observer_user}" -m 0700 "${observer_home}/.ssh"

authorized_keys=$(mktemp)
sudoers_candidate=$(mktemp)
trap 'rm -f -- "${authorized_keys}" "${sudoers_candidate}"' EXIT
printf 'restrict,command="/usr/bin/sudo -n %s" %s %s\n' \
  "${observer_command}" "${key_type}" "${key_body}" > "${authorized_keys}"
install -o "${observer_user}" -g "${observer_user}" -m 0600 \
  "${authorized_keys}" "${observer_home}/.ssh/authorized_keys"

printf 'Defaults!%s env_keep += "SSH_ORIGINAL_COMMAND"\n' "${observer_command}" > "${sudoers_candidate}"
printf '%s ALL=(root) NOPASSWD: %s\n' "${observer_user}" "${observer_command}" >> "${sudoers_candidate}"
chmod 0440 "${sudoers_candidate}"
visudo -cf "${sudoers_candidate}" >/dev/null
install -o root -g root -m 0440 "${sudoers_candidate}" "${sudoers_path}"

[[ "$(stat -c '%U:%G:%a' "${observer_command}")" == root:root:755 ]] || die 'Observer command permissions are unsafe.'
[[ "$(stat -c '%U:%G:%a' "${control_command}")" == root:root:755 ]] || die 'Control-helper permissions are unsafe.'
[[ "$(stat -c '%U:%G:%a' "${sudoers_path}")" == root:root:440 ]] || die 'Observer sudo rule permissions are unsafe.'
[[ "$(stat -c '%U:%G:%a' "${observer_home}/.ssh/authorized_keys")" == \
  "${observer_user}:${observer_user}:600" ]] || die 'Observer authorized_keys permissions are unsafe.'
