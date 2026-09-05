#!/usr/bin/env bash
set -euo pipefail

repo=/repo
mock_bin=/tmp/keycloak-cohort-cleaner-mock-bin
state=/tmp/keycloak-cohort-cleaner-mock-state
install -d -m 0700 "${mock_bin}" "${state}"

cat >"${mock_bin}/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state=/tmp/keycloak-cohort-cleaner-mock-state
kind=${1:-}
action=${2:-}
shift 2 || true
case "${kind}:${action}" in
  container:ls)
    [[ " $* " == *' -aq '* && " $* " == *' label=makepad.cleanup.contract=makepad-keycloak-cohort-restore-v1 '* ]]
    cat "${state}/containers"
    ;;
  container:inspect)
    identifier=${1:-}
    case "${identifier}" in
      c-expired) printf '/pg-kc-db-101-1-catwlk|makepad-keycloak-cohort-restore-v1|1\n' ;;
      c-future) printf '/pg-kc-app-101-1-catwlk|makepad-keycloak-cohort-restore-v1|4102444800\n' ;;
      c-malformed) printf '/unrelated-container|makepad-keycloak-cohort-restore-v1|1\n' ;;
      *) exit 1 ;;
    esac
    ;;
  network:ls)
    [[ " $* " == *' -q '* && " $* " == *' label=makepad.cleanup.contract=makepad-keycloak-cohort-restore-v1 '* ]]
    cat "${state}/networks"
    ;;
  network:inspect)
    identifier=${1:-}
    case "${identifier}" in
      n-expired) printf 'pg-kc-101-1-catwlk|makepad-keycloak-cohort-restore-v1|1\n' ;;
      n-future) printf 'pg-kc-102-1-catwlk|makepad-keycloak-cohort-restore-v1|4102444800\n' ;;
      *) exit 1 ;;
    esac
    ;;
  rm:-f)
    printf '%s\n' "${1:-}" >>"${state}/removed-containers"
    ;;
  network:rm)
    printf '%s\n' "${1:-}" >>"${state}/removed-networks"
    ;;
  *)
    echo "Unhandled mocked Docker operation: ${kind} ${action} $*" >&2
    exit 1
    ;;
esac
MOCK
chmod 0755 "${mock_bin}/docker"
export PATH="${mock_bin}:${PATH}"

printf '%s\n' c-expired c-future >"${state}/containers"
printf '%s\n' n-expired n-future >"${state}/networks"
install -d -m 0700 /tmp/postgres-keycloak-cohort-expired /tmp/postgres-keycloak-cohort-future \
  /tmp/postgres-keycloak-cohort-recovery
printf '%s\n' preserve > /tmp/postgres-keycloak-cohort-recovery/RECOVERY_REQUIRED
touch -t 202001010000 /tmp/postgres-keycloak-cohort-expired /tmp/postgres-keycloak-cohort-recovery

"${repo}/scripts/clean-keycloak-cohort-resources.sh"
[[ $(<"${state}/removed-containers") == c-expired ]]
[[ $(<"${state}/removed-networks") == n-expired ]]
[[ ! -e /tmp/postgres-keycloak-cohort-expired ]]
[[ -d /tmp/postgres-keycloak-cohort-future ]]
[[ -f /tmp/postgres-keycloak-cohort-recovery/RECOVERY_REQUIRED ]]

printf '%s\n' c-malformed >"${state}/containers"
: >"${state}/networks"
: >"${state}/removed-containers"
if "${repo}/scripts/clean-keycloak-cohort-resources.sh" >/tmp/cohort-cleaner-malformed-output 2>&1; then
  echo "Cohort cleaner accepted a malformed resource carrying its label." >&2
  exit 1
fi
grep -q 'Refusing malformed labeled cohort container' /tmp/cohort-cleaner-malformed-output
[[ ! -s "${state}/removed-containers" ]]

echo "Keycloak cohort resource cleaner tests passed."
