#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: install-keycloak-cohort-capture-host.sh <non-root-capture-user> <authorized-public-key-file>" >&2
  exit 2
fi
[[ "$(id -u)" -eq 0 ]] || { echo "The capture host installer must run as root." >&2; exit 1; }
capture_user=$1
public_key_file=$2
[[ "${capture_user}" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "${capture_user}" != root ]] || { echo "Capture user is invalid." >&2; exit 2; }
id "${capture_user}" >/dev/null
id -nG "${capture_user}" | tr ' ' '\n' | grep -Fxq docker || { echo "Capture user must already belong to the Docker group." >&2; exit 1; }
[[ -f "${public_key_file}" && ! -L "${public_key_file}" ]] || { echo "Public key input is unsafe." >&2; exit 2; }
read -r key_type key_body _ <"${public_key_file}"
case "${key_type}" in ssh-ed25519|sk-ssh-ed25519@openssh.com) ;; *) echo "Only Ed25519 capture keys are accepted." >&2; exit 2 ;; esac
[[ "${key_body}" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] || { echo "Public key encoding is invalid." >&2; exit 2; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
"${script_dir}/install-keycloak-cohort-cleaner.sh"
install -d -o root -g root -m 0755 /usr/local/libexec/makepad /etc/makepad/keycloak-cohort-capture
install -o root -g root -m 0755 "${script_dir}/capture-keycloak-cohort-backups.sh" \
  /usr/local/libexec/makepad/capture-keycloak-cohort-backups
install -o root -g root -m 0755 "${script_dir}/keycloak-cohort-capture-dispatch.sh" \
  /usr/local/libexec/makepad/keycloak-cohort-capture-dispatch
capture_group=$(id -gn "${capture_user}")
printf 'restrict,command="/usr/local/libexec/makepad/keycloak-cohort-capture-dispatch" %s %s\n' \
  "${key_type}" "${key_body}" > /etc/makepad/keycloak-cohort-capture/authorized_keys
chown root:"${capture_group}" /etc/makepad/keycloak-cohort-capture/authorized_keys
chmod 0640 /etc/makepad/keycloak-cohort-capture/authorized_keys
cat > /etc/ssh/sshd_config.d/70-makepad-keycloak-cohort-capture.conf <<EOF
Match User ${capture_user}
    AuthenticationMethods publickey
    AuthorizedKeysFile /etc/makepad/keycloak-cohort-capture/authorized_keys
    DisableForwarding yes
    PermitTTY no
    X11Forwarding no
EOF
chmod 0644 /etc/ssh/sshd_config.d/70-makepad-keycloak-cohort-capture.conf
sshd -t
systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
printf 'capture_helper_sha256=%s\n' "$(sha256sum /usr/local/libexec/makepad/capture-keycloak-cohort-backups | cut -d' ' -f1)"
printf 'cohort_cleaner_sha256=%s\n' "$(sha256sum /usr/local/libexec/makepad/clean-keycloak-cohort-resources | cut -d' ' -f1)"
