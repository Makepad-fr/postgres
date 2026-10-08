#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 0 ]] || { echo "usage: install-keycloak-cohort-cleaner.sh" >&2; exit 2; }
[[ "$(id -u)" -eq 0 ]] || { echo "The cohort cleaner installer must run as root." >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "${script_dir}/.." && pwd -P)
for source in "${script_dir}/clean-keycloak-cohort-resources.sh" \
  "${repo_root}/host/systemd/makepad-keycloak-cohort-cleaner.service" \
  "${repo_root}/host/systemd/makepad-keycloak-cohort-cleaner.timer"; do
  [[ -f "${source}" && ! -L "${source}" ]] || { echo "Missing safe installer input: ${source}" >&2; exit 1; }
done
install -d -o root -g root -m 0755 /usr/local/libexec/makepad
install -o root -g root -m 0755 "${script_dir}/clean-keycloak-cohort-resources.sh" \
  /usr/local/libexec/makepad/clean-keycloak-cohort-resources
install -o root -g root -m 0644 "${repo_root}/host/systemd/makepad-keycloak-cohort-cleaner.service" \
  /etc/systemd/system/makepad-keycloak-cohort-cleaner.service
install -o root -g root -m 0644 "${repo_root}/host/systemd/makepad-keycloak-cohort-cleaner.timer" \
  /etc/systemd/system/makepad-keycloak-cohort-cleaner.timer
systemctl daemon-reload
systemctl enable --now makepad-keycloak-cohort-cleaner.timer >/dev/null
systemctl start makepad-keycloak-cohort-cleaner.service
systemctl is-enabled --quiet makepad-keycloak-cohort-cleaner.timer
systemctl is-active --quiet makepad-keycloak-cohort-cleaner.timer
