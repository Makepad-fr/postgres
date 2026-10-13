#!/usr/bin/env bash
set -euo pipefail

repo=/repo
mock_bin=/tmp/keycloak-cohort-dispatch-mock-bin
install -d -m 0755 /usr/local/libexec/makepad
install -d -m 0700 "${mock_bin}"
install -o root -g root -m 0755 "${repo}/scripts/capture-keycloak-cohort-backups.sh" \
  /usr/local/libexec/makepad/capture-keycloak-cohort-backups
install -o root -g root -m 0755 "${repo}/scripts/clean-keycloak-cohort-resources.sh" \
  /usr/local/libexec/makepad/clean-keycloak-cohort-resources
install -o root -g root -m 0755 "${repo}/scripts/keycloak-cohort-capture-dispatch.sh" \
  /usr/local/libexec/makepad/keycloak-cohort-capture-dispatch
cat >"${mock_bin}/systemctl" <<'MOCK'
#!/usr/bin/env sh
case "$1:$2" in
  is-enabled:--quiet|is-active:--quiet) exit 0 ;;
  show:--property=Result) printf '%s\n' success ;;
  show:--property=ExecMainStatus) printf '%s\n' 0 ;;
  *) exit 1 ;;
esac
MOCK
chmod 0755 "${mock_bin}/systemctl"
export PATH="${mock_bin}:${PATH}"

helper_digest=$(sha256sum /usr/local/libexec/makepad/capture-keycloak-cohort-backups | cut -d' ' -f1)
cleaner_digest=$(sha256sum /usr/local/libexec/makepad/clean-keycloak-cohort-resources | cut -d' ' -f1)
result=$(SSH_ORIGINAL_COMMAND="probe ${helper_digest} ${cleaner_digest}" \
  /usr/local/libexec/makepad/keycloak-cohort-capture-dispatch)
[[ "${result}" == cohort-capture-contract-ok ]]

wrong_digest=$(printf '0%.0s' {1..64})
if SSH_ORIGINAL_COMMAND="probe ${helper_digest} ${wrong_digest}" \
  /usr/local/libexec/makepad/keycloak-cohort-capture-dispatch >/dev/null 2>&1; then
  echo "Forced command accepted a substituted cleaner digest." >&2
  exit 1
fi
if SSH_ORIGINAL_COMMAND="shell ${helper_digest} ${cleaner_digest}" \
  /usr/local/libexec/makepad/keycloak-cohort-capture-dispatch >/dev/null 2>&1; then
  echo "Forced command accepted an arbitrary operation." >&2
  exit 1
fi
if SSH_ORIGINAL_COMMAND="fetch 1 1 ../../etc/passwd ${helper_digest} ${cleaner_digest}" \
  /usr/local/libexec/makepad/keycloak-cohort-capture-dispatch >/dev/null 2>&1; then
  echo "Forced command accepted an unsupported fetch path." >&2
  exit 1
fi

echo "Keycloak cohort forced-command tests passed."
