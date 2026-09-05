#!/usr/bin/env bash
set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C
export LC_ALL=C
umask 077

readonly observer_user=brio-runtime-observer
readonly observer_home=/var/lib/brio-runtime-observer
readonly observer_command=/usr/local/libexec/makepad/brio-postgres-runtime-observe
readonly sudoers_path=/etc/sudoers.d/brio-postgres-runtime-observer

die() {
  printf '%s\n' "$1" >&2
  exit 1
}

(( EUID == 0 )) || die 'Run this installer as root on the PostgreSQL host.'
[[ $# == 2 ]] || die 'usage: install-brio-runtime-observer.sh OBSERVER_SCRIPT ED25519_PUBLIC_KEY_FILE'
for command_name in cmp docker getent id install mktemp passwd python3 ssh-keygen stat timeout useradd visudo wc; do
  command -v "${command_name}" >/dev/null || die "Missing required installer command: ${command_name}."
done
source_script=$1
public_key_file=$2
[[ -f "${source_script}" && ! -L "${source_script}" ]] || die 'Observer source must be a regular file.'
[[ -f "${public_key_file}" && ! -L "${public_key_file}" ]] || die 'Observer public key must be a regular file.'
[[ $(wc -c < "${source_script}") -le 65536 ]] || die 'Observer source is unexpectedly large.'
[[ $(wc -c < "${public_key_file}") -le 1024 ]] || die 'Observer public key file is unexpectedly large.'

read -r key_type key_body key_extra < "${public_key_file}"
[[ "${key_type}" == ssh-ed25519 && "${key_body}" =~ ^[A-Za-z0-9+/]+={0,3}$ && -z "${key_extra:-}" ]] || \
  die 'Expected exactly one OpenSSH Ed25519 public key without trailing fields.'
[[ $(wc -l < "${public_key_file}") -eq 1 ]] || die 'Observer public key file must contain exactly one line.'
ssh-keygen -l -f "${public_key_file}" >/dev/null || die 'Observer public key is not valid OpenSSH key material.'

if ! id "${observer_user}" >/dev/null 2>&1; then
  useradd --system --user-group --create-home --home-dir "${observer_home}" --shell /bin/bash "${observer_user}"
fi
account_record=$(getent passwd "${observer_user}") || die 'Observer account could not be read.'
IFS=: read -r account_name _ account_uid _ _ account_home account_shell <<< "${account_record}"
[[ "${account_name}" == "${observer_user}" && "${account_uid}" =~ ^[1-9][0-9]*$ && \
  "${account_uid}" -lt 1000 && "${account_home}" == "${observer_home}" && \
  "${account_shell}" == /bin/bash && "$(id -gn "${observer_user}")" == "${observer_user}" && \
  "$(id -nG "${observer_user}")" == "${observer_user}" ]] || die 'Observer account identity is unsafe.'
passwd --lock "${observer_user}" >/dev/null
read -r _ password_state _ <<< "$(passwd --status "${observer_user}")"
[[ "${password_state}" == L ]] || die 'Observer account password is not locked.'

install -d -o root -g root -m 0755 /usr/local/libexec /usr/local/libexec/makepad
for controlled_path in "${observer_command}" "${sudoers_path}" "${observer_home}" \
  "${observer_home}/.ssh" "${observer_home}/.ssh/authorized_keys"; do
  [[ ! -L "${controlled_path}" ]] || die "Refusing symbolic link at managed path: ${controlled_path}."
done
[[ ! -e "${observer_command}" || -f "${observer_command}" ]] || die 'Observer command path has an unsafe file type.'
[[ ! -e "${sudoers_path}" || -f "${sudoers_path}" ]] || die 'Observer sudo rule path has an unsafe file type.'
[[ ! -e "${observer_home}" || -d "${observer_home}" ]] || die 'Observer home has an unsafe file type.'
[[ ! -e "${observer_home}/.ssh" || -d "${observer_home}/.ssh" ]] || die 'Observer SSH path has an unsafe file type.'
[[ ! -e "${observer_home}/.ssh/authorized_keys" || -f "${observer_home}/.ssh/authorized_keys" ]] || \
  die 'Observer authorized-keys path has an unsafe file type.'

install -o root -g root -m 0755 -T "${source_script}" "${observer_command}"
install -d -o root -g root -m 0755 "${observer_home}"
install -d -o root -g root -m 0700 "${observer_home}/.ssh"

authorized_keys=$(mktemp)
sudoers_candidate=$(mktemp)
trap 'rm -f -- "${authorized_keys}" "${sudoers_candidate}"' EXIT
printf 'restrict,command="/usr/bin/sudo -n %s" %s %s\n' \
  "${observer_command}" "${key_type}" "${key_body}" > "${authorized_keys}"
install -o root -g root -m 0600 -T \
  "${authorized_keys}" "${observer_home}/.ssh/authorized_keys"

printf 'Defaults!%s env_keep += "SSH_ORIGINAL_COMMAND"\n' "${observer_command}" > "${sudoers_candidate}"
printf '%s ALL=(root) NOPASSWD: %s\n' "${observer_user}" "${observer_command}" >> "${sudoers_candidate}"
chmod 0440 "${sudoers_candidate}"
visudo -cf "${sudoers_candidate}" >/dev/null
install -o root -g root -m 0440 -T "${sudoers_candidate}" "${sudoers_path}"

[[ "$(stat -c '%U:%G:%a' "${observer_command}")" == root:root:755 ]] || die 'Observer command permissions are unsafe.'
[[ "$(stat -c '%U:%G:%a' "${sudoers_path}")" == root:root:440 ]] || die 'Observer sudo rule permissions are unsafe.'
[[ "$(stat -c '%U:%G:%a' "${observer_home}")" == root:root:755 ]] || die 'Observer home permissions are unsafe.'
[[ "$(stat -c '%U:%G:%a' "${observer_home}/.ssh")" == root:root:700 ]] || die 'Observer SSH directory permissions are unsafe.'
[[ "$(stat -c '%U:%G:%a' "${observer_home}/.ssh/authorized_keys")" == \
  root:root:600 ]] || die 'Observer authorized_keys permissions are unsafe.'
cmp -s "${source_script}" "${observer_command}" || die 'Installed observer differs from the reviewed source.'
cmp -s "${authorized_keys}" "${observer_home}/.ssh/authorized_keys" || die 'Installed authorized key differs from the reviewed candidate.'
cmp -s "${sudoers_candidate}" "${sudoers_path}" || die 'Installed sudo rule differs from the reviewed candidate.'
visudo -cf "${sudoers_path}" >/dev/null || die 'Installed observer sudo rule is invalid.'
